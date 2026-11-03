import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:utcp/utcp.dart';

import 'cli_call_template.dart';

/// The shell a [CliCallTemplate] runs in.
enum Shell {
  bash('/bin/bash'),
  powershell('powershell.exe');

  const Shell(this.executable);

  /// PowerShell on Windows, bash everywhere else, as in the reference SDKs.
  static Shell get host => Platform.isWindows ? powershell : bash;

  final String executable;

  List<String> arguments(String script) => switch (this) {
    bash => ['-c', script],
    powershell => ['-NoProfile', '-Command', script],
  };

  /// Host variables inherited when `inherit_env_vars` is null; the same
  /// allowlists as the reference SDKs.
  List<String> get defaultInheritedVariables => switch (this) {
    bash => const [
      'PATH',
      'HOME',
      'LANG',
      'LC_ALL',
      'LC_CTYPE',
      'USER',
      'LOGNAME',
      'SHELL',
      'TZ',
      'TERM',
    ],
    powershell => const [
      'PATH',
      'PATHEXT',
      'SYSTEMROOT',
      'SYSTEMDRIVE',
      'WINDIR',
      'COMSPEC',
      'TEMP',
      'TMP',
      'USERPROFILE',
      'USERNAME',
      'USERDOMAIN',
      'COMPUTERNAME',
      'HOMEDRIVE',
      'HOMEPATH',
      'APPDATA',
      'LOCALAPPDATA',
      'PROGRAMDATA',
      'ALLUSERSPROFILE',
      'PUBLIC',
      'PROGRAMFILES',
      'PROGRAMFILES(X86)',
      'PROGRAMW6432',
      'OS',
      'PROCESSOR_ARCHITECTURE',
      'PROCESSOR_IDENTIFIER',
      'PROCESSOR_LEVEL',
      'PROCESSOR_REVISION',
      'NUMBER_OF_PROCESSORS',
      'PSMODULEPATH',
      'LOGONSERVER',
      'SESSIONNAME',
      'USERDNSDOMAIN',
    ],
  };
}

/// A generated script and the variables it needs to run.
final class ShellScript {
  const ShellScript(this.source, this.environment, {this.endMarker});

  final String source;

  /// Tool argument values (and the capture file) referenced by [source].
  final Map<String, String> environment;

  /// The last line a bash script prints, so a script that a command ended
  /// early (`exit`, `exec`, `set -e`) is told apart from one that finished.
  final String? endMarker;
}

/// A fresh random hex string that namespaces one call's argument variables,
/// so a template cannot reference them by a name it could know in advance.
String randomNonce() {
  final random = Random.secure();
  return List.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// The environment of the shell process: the inherited host variables, then
/// the template's `env_vars`, then [script]'s own variables.
Map<String, String> subprocessEnvironment(
  CliCallTemplate template,
  ShellScript script,
  Map<String, String> host,
  Shell shell,
) => {
  for (final key in template.inheritEnvVars ?? shell.defaultInheritedVariables)
    key: ?host[key],
  ...?template.envVars,
  ...script.environment,
};

/// Builds one script that runs [commands] in order and prints the outputs
/// selected by `append_to_final_output`.
///
/// For bash, every command runs in the script's own shell so `cd` and
/// variable assignments carry over to later commands, as the spec requires;
/// its output goes to [captureFile] and is read back into `CMD_<i>_OUTPUT`.
/// A selected output is printed as soon as its command finishes, so the
/// outputs before a command that ends the script are not lost. PowerShell
/// assignments already run in the script's scope.
ShellScript buildShellScript(
  List<CommandStep> commands,
  ToolArguments arguments, {
  required Shell shell,
  required String nonce,
  String? captureFile,
}) {
  final environment = <String, String>{};
  final lines = <String>[];
  final capture = '__UTCP_OUT_$nonce';
  switch (shell) {
    case Shell.bash:
      environment[capture] =
          captureFile ?? (throw ArgumentError.notNull('captureFile'));
    case Shell.powershell:
      lines.add(r'$ErrorActionPreference = "Stop"');
  }
  for (final (i, step) in commands.indexed) {
    final command = substitutePlaceholders(
      step.command,
      arguments,
      shell: shell,
      nonce: nonce,
      environment: environment,
    );
    final output = 'CMD_${i}_OUTPUT';
    final selected = step.appendToFinalOutput ?? i == commands.length - 1;
    switch (shell) {
      case Shell.bash:
        lines.addAll([
          // `>|` because a command may have turned on `set -C`.
          '{ $command',
          '} >|"\$$capture" 2>&1',
          r'__utcp_status=$?',
          '$output=\$(<"\$$capture")',
          // Emptied once read, so a script that stops before the next
          // command never returns this output again.
          ': >|"\$$capture"',
          if (selected) "printf '%s\\n' \"\${$output}\"",
          // Restores `$?` for the next command; `&& :` keeps `set -e` from
          // ending the script on a failure bash had exempted from it.
          r'(exit $__utcp_status) && :',
        ]);
      case Shell.powershell:
        lines.add('\$$output = $command 2>&1 | Out-String');
    }
  }
  if (shell == Shell.powershell) {
    for (final (i, step) in commands.indexed) {
      if (step.appendToFinalOutput ?? i == commands.length - 1) {
        lines.add('Write-Output \$CMD_${i}_OUTPUT');
      }
    }
    return ShellScript(lines.join('\n'), environment);
  }
  final endMarker = '__UTCP_END_$nonce';
  lines.add("printf '%s\\n' $endMarker");
  return ShellScript(lines.join('\n'), environment, endMarker: endMarker);
}

final _placeholderPattern = RegExp('UTCP_ARG_([a-zA-Z0-9_]+?)_UTCP_END');

/// Replaces every `UTCP_ARG_<name>_UTCP_END` in [command] with a reference
/// to a variable holding the argument, chosen for the quoting context it
/// sits in, and records the value in [environment].
///
/// The shell expands the reference after it has parsed the script, so the
/// value is never shell syntax. The emitted forms match the Python and
/// TypeScript SDKs (GHSA-33p6-5jxp-p3x4):
///
/// - bash: `"$V"` in code, `${V}` inside `"..."`, `'"$V"'` inside `'...'`.
///   Code inside `$(...)` and backticks gets the code form even within
///   double quotes, so the value stays one word there too.
/// - PowerShell: `${env:V}`; a placeholder inside `'...'` is rejected
///   because PowerShell does not expand there.
///
/// Bash evaluates the value of a variable used as a number as an arithmetic
/// expression, and an array subscript in it runs command substitutions. So
/// a bash placeholder is rejected inside `$(( ))`, `(( ))`, `$[ ]`, `${...}`,
/// an array subscript, a `[[ ]]` with an arithmetic comparison or `-v`, a
/// `test -v`, a `let` command, a `declare -i`-style declaration and an
/// assignment to a variable declared integer.
///
/// Throws a [UtcpException] when an argument is missing, holds a NUL
/// character, or sits where it cannot be passed safely.
String substitutePlaceholders(
  String command,
  ToolArguments arguments, {
  required Shell shell,
  required String nonce,
  required Map<String, String> environment,
}) {
  String bind(String name) {
    if (!arguments.containsKey(name)) {
      throw UtcpException(
        "Missing argument '$name' for placeholder UTCP_ARG_${name}_UTCP_END.",
      );
    }
    final value = switch (arguments[name]) {
      final String value => value,
      final value => jsonEncode(value),
    };
    if (value.contains('\u0000')) {
      throw UtcpException(
        "Argument '$name' contains a NUL character, which cannot be passed "
        'to a command.',
      );
    }
    // Defense in depth, independent of the placeholder scanner.
    if (_expandsInSubscript(value)) {
      throw UtcpException(
        "Argument '$name' contains a substitution (`\$...` or backticks) "
        'inside `[...]`. Bash runs it as an array subscript when the value is '
        'evaluated as a number, so this value is refused.',
      );
    }
    final variable = '__UTCP_ARG_${nonce}_$name';
    environment[variable] = value;
    return variable;
  }

  return switch (shell) {
    Shell.bash => _BashSubstitution(
      command,
      bind,
      (variable) => environment[variable]!,
    ).run(),
    Shell.powershell => _substitutePowerShell(command, bind),
  };
}

final _expansionStart = RegExp(r'[A-Za-z_({[]');

/// Whether [value] holds a substitution inside an array subscript, the one
/// shape from which bash runs code when it evaluates a value as a number:
/// `a[$(cmd)]`, or `a[$X]` where `X` holds such a value.
///
/// Bash 5.2 honours quotes and `\` when it looks for a subscript's `]` and
/// bash 3.2 does not, so after one of them inside `[...]` no `]` is trusted
/// to close it.
bool _expandsInSubscript(String value) {
  var depth = 0;
  var unsure = false;
  for (var i = 0; i < value.length; i++) {
    final char = value[i];
    final expands =
        char == '`' ||
        (char == r'$' &&
            i + 1 < value.length &&
            _expansionStart.hasMatch(value[i + 1]));
    if (expands && (depth > 0 || unsure)) return true;
    if (char == '[') {
      depth++;
    } else if (depth > 0) {
      if (char == ']' && !unsure) depth--;
      if ('\\\'"\$'.contains(char)) unsure = true;
    }
  }
  return false;
}

String _substitutePowerShell(String command, String Function(String) bind) {
  final out = StringBuffer();
  var singleQuoted = false;
  var doubleQuoted = false;
  var i = 0;
  while (i < command.length) {
    if (_placeholderPattern.matchAsPrefix(command, i) case final match?) {
      final name = match.group(1)!;
      if (singleQuoted) {
        throw UtcpException(
          'Placeholder UTCP_ARG_${name}_UTCP_END is inside a PowerShell '
          'single-quoted string, where variables do not expand. Use a '
          'double-quoted string instead.',
        );
      }
      out.write('\${env:${bind(name)}}');
      i = match.end;
      continue;
    }
    final char = command[i];
    final next = i + 1 < command.length ? command[i + 1] : null;
    // A backtick escapes outside single quotes; '' is a literal ' inside.
    final escapes = singleQuoted
        ? char == "'" && next == "'"
        : char == '`' && next != null;
    if (escapes) {
      out
        ..write(char)
        ..write(next);
      i += 2;
      continue;
    }
    if (char == "'" && !doubleQuoted) singleQuoted = !singleQuoted;
    if (char == '"' && !singleQuoted) doubleQuoted = !doubleQuoted;
    out.write(char);
    i++;
  }
  return out.toString();
}

const _arithmetic = 'an arithmetic expression';
const _caseInCommandSub = 'a `case` statement inside a command substitution';
const _heredocInCommandSub = 'or after a heredoc inside a command substitution';
final _wordBreak = RegExp(r'[\s;&|()<>`]');
final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _arithmeticTest = RegExp(r'(^|\s)-(eq|ne|lt|le|gt|ge|v)(?=\s|$)');
final _integerOption = RegExp(r'^-[A-Za-z]*i');
final _assignment = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?\+?=');
final _quoting = RegExp(r'''\$(?=['"])|['"\\]''');

/// Characters in a heredoc body that bash 3.2, or a backtick substitution in
/// any version, reads as code while looking for the substitution's end.
final _codeInCommandSubHeredoc = RegExp('[\'"()`]');
final _blanks = RegExp(r'\s+');
const _keywords = {'if', 'then', 'else', 'elif', 'do', 'while', 'until', '!'};
const _declarations = {'declare', 'typeset', 'local', 'readonly', 'export'};

/// Words that run the command that follows them, after their options, so the
/// real command word comes later when deciding whether a value is evaluated
/// as arithmetic.
const _wrappers = {'builtin', 'command', 'time', 'exec', 'nohup', 'env'};

enum _CasePhase { head, pattern, body }

/// The parser state inside a `case` statement: which part is being read and
/// the extglob/`(pattern)` paren nesting within a pattern.
final class _CaseState {
  _CasePhase phase = _CasePhase.head;
  int parens = 0;
}

/// A heredoc whose body is still to be read once the current line ends. The
/// body expands parameters and substitutions unless the delimiter was quoted
/// ([expand]); `<<-` strips leading tabs from the terminator line
/// ([stripTabs]).
final class _Heredoc {
  _Heredoc(this.delimiter, {required this.expand, required this.stripTabs});

  final String delimiter;
  final bool expand;
  final bool stripTabs;
}

/// A one-pass reader of bash command text that tracks quoting, nested
/// command substitutions and the contexts where bash evaluates a value as
/// an arithmetic expression.
///
/// Each `_code`, `_single` and `_double` call reads one region and copies it
/// to the output, with placeholders replaced. `forbidden` names the
/// enclosing context, if any, where a placeholder is rejected: it is passed
/// down, so a value printed by `$(...)` inside `$(( ))` is rejected too.
final class _BashSubstitution {
  _BashSubstitution(this.source, this.bind, this.valueOf);

  final String source;
  final String Function(String name) bind;

  /// The value a variable returned by [bind] holds.
  final String Function(String variable) valueOf;
  final _out = StringBuffer();

  /// Names and values of the placeholders read so far, in order.
  final _bound = <String>[];
  final _values = <String>[];

  /// Heredocs seen on the current line whose bodies start at the next line.
  final _pendingHeredocs = <_Heredoc>[];

  /// Set once the scanner can no longer be sure how bash reads the rest of
  /// the text; every later placeholder is rejected in this context.
  String? _unsure;

  /// Variables declared integer (`declare -i`), and the first placeholder
  /// in an assignment to each variable, checked against each other once the
  /// whole text is read because a function may run before its definition.
  final _integerNames = <String>{};
  final _assigned = <String, String>{};

  /// The cursor position just after the last `\` escape in code, where the
  /// escaped character cannot end a word.
  var _escapeEnd = -1;
  var _i = 0;

  String run() {
    _code(null, null);
    for (final MapEntry(key: variable, value: name) in _assigned.entries) {
      if (_integerNames.contains(variable)) {
        _reject(name, 'an assignment to an integer variable');
      }
    }
    return _out.toString();
  }

  bool _at(String text) => source.startsWith(text, _i);

  void _copy(int count) {
    final end = min(_i + count, source.length);
    _out.write(source.substring(_i, end));
    _i = end;
  }

  /// Replaces a placeholder at the cursor using [reference], or returns
  /// false when there is none.
  bool _placeholder(String? forbidden, String Function(String) reference) {
    final match = _placeholderPattern.matchAsPrefix(source, _i);
    if (match == null) return false;
    final name = match.group(1)!;
    if (forbidden ?? _unsure case final context?) _reject(name, context);
    final variable = bind(name);
    _bound.add(name);
    _values.add(valueOf(variable));
    _out.write(reference(variable));
    _i = match.end;
    return true;
  }

  Never _reject(String name, String context) {
    final detail =
        context == _caseInCommandSub || context == _heredocInCommandSub
        ? 'the scanner cannot tell how bash parses the text, and bash could '
              'split or glob the value. Move the `case` or heredoc out of the '
              'command substitution.'
        : 'bash would run code embedded in the value. Compare numbers with '
              '`[ ]` or `test`, or pass the value to a program such as `expr`.';
    throw UtcpException(
      'Placeholder UTCP_ARG_${name}_UTCP_END is inside $context, where $detail',
    );
  }

  bool get _atWordStart =>
      _i == 0 || (_i != _escapeEnd && _wordBreak.hasMatch(source[_i - 1]));

  bool _wordBreakAt(int index) =>
      index >= source.length || _wordBreak.hasMatch(source[index]);

  /// Whether [word] sits at the cursor as its own word, so bash reads it as
  /// a reserved word (`in`, `esac`, …).
  bool _reservedWordAt(String word) =>
      _atWordStart && _at(word) && _wordBreakAt(_i + word.length);

  /// Whether everything from [commandStart] to the cursor is blanks and
  /// reserved words, so a word at the cursor begins a simple command.
  bool _atCommandStart(int commandStart) {
    for (final word in source.substring(commandStart, _i).split(_blanks)) {
      if (word.isNotEmpty && !_keywords.contains(word) && word != '{') {
        return false;
      }
    }
    return true;
  }

  /// Whether the word before the cursor is a variable name, so a `[` here
  /// opens an array subscript.
  bool get _afterName {
    var start = _i;
    while (start > 0 && !_wordBreak.hasMatch(source[start - 1])) {
      start--;
    }
    return start < _i && _name.hasMatch(source.substring(start, _i));
  }

  /// Whether the word before the cursor is `name=` or `name+=`, so a `(`
  /// here opens a compound array assignment.
  bool get _afterAssignment {
    var start = _i;
    while (start > 0 && !_wordBreak.hasMatch(source[start - 1])) {
      start--;
    }
    final word = source.substring(start, _i);
    return _assignment.matchAsPrefix(word)?.end == word.length;
  }

  /// Reads shell code up to [end] (outside any nested parentheses), or to
  /// the end of the text when [end] is null. Tracks `case` statements, `{ }`
  /// groups and pending heredocs so quoting and command boundaries stay in
  /// sync with bash.
  ///
  /// [inCommandSub] is set inside `$(...)` and backticks, where bash 3.2
  /// cannot parse a `case` statement; a placeholder in such a `case` is
  /// rejected because its quoting cannot be guaranteed there. [heredocs] is
  /// false where `<<` is a shift operator (arithmetic) or literal (`${...}`).
  /// [compound] is set inside `name=(...)`, where `[...]=` is a subscript.
  void _code(
    String? end,
    String? forbidden, {
    bool inCommandSub = false,
    bool heredocs = true,
    bool compound = false,
  }) {
    final pendingAtStart = _pendingHeredocs.length;
    final caseStack = <_CaseState>[];
    var depth = 0;
    var commandStart = _i;
    var boundAtCommandStart = _bound.length;
    void endCommand() {
      _checkCommand(source.substring(commandStart, _i), boundAtCommandStart);
      commandStart = _i;
      boundAtCommandStart = _bound.length;
    }

    void startCommand() {
      commandStart = _i;
      boundAtCommandStart = _bound.length;
    }

    while (_i < source.length) {
      if (caseStack.isNotEmpty) {
        final state = caseStack.last;
        if (state.phase != _CasePhase.head && _reservedWordAt('esac')) {
          endCommand();
          _copy(4);
          caseStack.removeLast();
          startCommand();
          continue;
        }
        switch (state.phase) {
          case _CasePhase.head:
            if (_reservedWordAt('in')) {
              _copy(2);
              state.phase = _CasePhase.pattern;
              startCommand();
              continue;
            }
          case _CasePhase.pattern:
            // A `)` closes the pattern list unless it balances an extglob
            // `?(...)`-style group or the optional leading `(`.
            if (source[_i] == '(') {
              if (_i > 0 && '?*+@!'.contains(source[_i - 1])) state.parens++;
              _copy(1);
              continue;
            }
            if (source[_i] == ')') {
              if (state.parens > 0) {
                state.parens--;
                _copy(1);
                continue;
              }
              _copy(1);
              state.phase = _CasePhase.body;
              startCommand();
              continue;
            }
          case _CasePhase.body:
            if (_at(';;&') || _at(';;') || _at(';&')) {
              endCommand();
              _copy(_at(';;&') ? 3 : 2);
              state.phase = _CasePhase.pattern;
              startCommand();
              continue;
            }
        }
      }
      if (end != null && depth == 0 && caseStack.isEmpty && _at(end)) {
        endCommand();
        _copy(end.length);
        // Bash 3.2 and 5.x disagree on where such a heredoc's body is.
        if (_pendingHeredocs.length > pendingAtStart) {
          _unsure ??= _heredocInCommandSub;
        }
        return;
      }
      if (_placeholder(forbidden, (v) => '"\$$v"')) continue;
      switch (source[_i]) {
        case r'\':
          _copy(2);
          _escapeEnd = _i;
        case "'":
          _single(forbidden, ansi: false);
        case '"':
          _double(forbidden, inCommandSub: inCommandSub);
        case '`':
          _copy(1);
          _code('`', forbidden, inCommandSub: true);
        case r'$':
          _dollar(forbidden, quoted: false, inCommandSub: inCommandSub);
        case '#' when _atWordStart:
          final newline = source.indexOf('\n', _i);
          _copy((newline < 0 ? source.length : newline) - _i);
        case '<' when _at('<<<') || (!heredocs && _at('<<')):
          _copy(_at('<<<') ? 3 : 2);
        case '<' when _at('<<'):
          final stripTabs = _at('<<-');
          _copy(stripTabs ? 3 : 2);
          while (_i < source.length &&
              (source[_i] == ' ' || source[_i] == '\t')) {
            _copy(1);
          }
          final heredoc = _readHeredocDelimiter(stripTabs: stripTabs);
          if (heredoc != null) _pendingHeredocs.add(heredoc);
        case '(' when _at('(('):
          _copy(2);
          _code(
            '))',
            forbidden ?? _arithmetic,
            inCommandSub: inCommandSub,
            heredocs: false,
          );
        case '[' when (compound && _atWordStart) || _afterName:
          _copy(1);
          _code(
            ']',
            forbidden ?? 'an array subscript',
            inCommandSub: inCommandSub,
            heredocs: false,
          );
        case '[' when _at('[[') && _atWordStart:
          _copy(2);
          final start = _i;
          final bound = _bound.length;
          _code(']]', forbidden, inCommandSub: inCommandSub);
          if (_bound.length > bound &&
              _arithmeticTest.hasMatch(source.substring(start, _i))) {
            _reject(_bound[bound], 'a `[[ ]]` arithmetic comparison or `-v`');
          }
        case '(' when _afterAssignment:
          _copy(1);
          _code(')', forbidden, inCommandSub: inCommandSub, compound: true);
        case 'c' when _reservedWordAt('case') && _atCommandStart(commandStart):
          caseStack.add(_CaseState());
          if (inCommandSub) forbidden ??= _caseInCommandSub;
          _copy(4);
        case '{' when _atWordStart && _wordBreakAt(_i + 1):
          endCommand();
          _copy(1);
          startCommand();
        case '}' when _atWordStart:
          endCommand();
          _copy(1);
          startCommand();
        case '\n':
          endCommand();
          _copy(1);
          if (_pendingHeredocs.isNotEmpty) {
            final pending = List.of(_pendingHeredocs);
            _pendingHeredocs.clear();
            for (final heredoc in pending) {
              _heredoc(heredoc, forbidden, inCommandSub: inCommandSub);
            }
          }
          startCommand();
        case '(' || ')' || ';' || '&' || '|':
          endCommand();
          if (source[_i] == '(') depth++;
          if (source[_i] == ')' && depth > 0) depth--;
          _copy(1);
          startCommand();
        default:
          _copy(1);
      }
    }
    endCommand();
  }

  /// Rejects placeholders read since [boundAtStart] when [command] is a
  /// simple command that evaluates its arguments as arithmetic or as a
  /// variable name. Leading reserved words, variable assignments, wrapper
  /// words (`command`, `env`, …) with their options, and quoting on the
  /// command name (`'let'`, `\let`) are skipped first. Also records integer
  /// declarations and assignments for the check in [run].
  void _checkCommand(String command, int boundAtStart) {
    final words = command.trim().split(_blanks).where((w) => w.isNotEmpty);
    final assigned = <String>[];
    var afterWrapper = false;
    String? first;
    final arguments = <String>[];
    for (final word in words) {
      if (first != null) {
        arguments.add(word);
        continue;
      }
      final unquoted = word.replaceAll(_quoting, '');
      if (_assignment.matchAsPrefix(word) case final match?) {
        assigned.add(match.group(1)!);
      } else if (_wrappers.contains(unquoted)) {
        afterWrapper = true;
      } else if (!_keywords.contains(unquoted) &&
          !(afterWrapper && unquoted.startsWith('-'))) {
        first = unquoted;
      }
    }
    if (_declarations.contains(first)) {
      final names = [
        for (final word in arguments)
          if (_assignment.matchAsPrefix(word) case final match?)
            match.group(1)!
          else if (_name.hasMatch(word))
            word,
      ];
      if (arguments.any(_integerOption.hasMatch)) _integerNames.addAll(names);
      assigned.addAll(names);
    }
    if (_bound.length == boundAtStart) return;
    final placeholder = _bound[boundAtStart];
    for (final name in assigned) {
      _assigned.putIfAbsent(name, () => placeholder);
    }
    if (first == 'let') _reject(placeholder, 'a `let` command');
    if ((first == 'test' || first == '[') && arguments.contains('-v')) {
      _reject(placeholder, 'a `test -v` check');
    }
    if (_declarations.contains(first) &&
        arguments.any(_integerOption.hasMatch)) {
      _reject(placeholder, 'an integer (`-i`) declaration');
    }
    // Two values in one word can build a subscript that neither holds alone
    // (`y[` and `$(cmd)]`).
    if (_bound.length - boundAtStart > 1 &&
        _expandsInSubscript(_values.sublist(boundAtStart).join())) {
      throw UtcpException(
        'Arguments ${_bound.sublist(boundAtStart).toSet().map((n) => "'$n'").join(', ')} '
        'together contain a substitution (`\$...` or backticks) inside '
        '`[...]`. Bash runs it as an array subscript when the value is '
        'evaluated as a number, so these values are refused.',
      );
    }
  }

  /// Reads a heredoc delimiter word at the cursor, copying it as is.
  /// Any quoting makes the body literal (no expansion). Returns null when no
  /// delimiter follows the operator.
  _Heredoc? _readHeredocDelimiter({required bool stripTabs}) {
    final delimiter = StringBuffer();
    var expand = true;
    word:
    while (_i < source.length) {
      final char = source[_i];
      switch (char) {
        case ' ' || '\t' || '\n' || ';' || '&' || '|' || '<' || '>' || '(':
        case ')':
          break word;
        case "'" || '"':
          expand = false;
          _copy(1);
          while (_i < source.length && source[_i] != char) {
            delimiter.write(source[_i]);
            _copy(1);
          }
          _copy(1);
        case r'\':
          expand = false;
          _copy(1);
          if (_i < source.length) {
            delimiter.write(source[_i]);
            _copy(1);
          }
        default:
          delimiter.write(char);
          _copy(1);
      }
    }
    if (delimiter.isEmpty) return null;
    return _Heredoc(delimiter.toString(), expand: expand, stripTabs: stripTabs);
  }

  /// Reads a heredoc body up to and including its terminator line. An
  /// expanding body is read like a double-quoted string; a quoted-delimiter
  /// body is literal, so a placeholder in it cannot be expanded and is
  /// rejected.
  void _heredoc(
    _Heredoc heredoc,
    String? forbidden, {
    required bool inCommandSub,
  }) {
    while (_i < source.length) {
      if (_atHeredocEnd(heredoc)) {
        final newline = source.indexOf('\n', _i);
        _copy((newline < 0 ? source.length : newline + 1) - _i);
        return;
      }
      if (inCommandSub && _unclearHeredocLine(heredoc)) {
        _unsure ??= _heredocInCommandSub;
      }
      while (_i < source.length && source[_i] != '\n') {
        if (!heredoc.expand) {
          if (_placeholderPattern.matchAsPrefix(source, _i) case final match?) {
            final name = match.group(1)!;
            throw UtcpException(
              'Placeholder UTCP_ARG_${name}_UTCP_END is inside a quoted '
              "heredoc body (<<'${heredoc.delimiter}'), where bash does not "
              'expand the '
              'value, so it cannot be passed safely. Use an unquoted heredoc '
              'delimiter.',
            );
          }
          _copy(1);
          continue;
        }
        if (_placeholder(forbidden, (v) => '\${$v}')) continue;
        switch (source[_i]) {
          case r'$':
            _dollar(forbidden, quoted: true, inCommandSub: inCommandSub);
          case '`':
            _copy(1);
            _code('`', forbidden, inCommandSub: true);
          case r'\':
            final next = _i + 1 < source.length ? source[_i + 1] : '';
            _copy(next.isNotEmpty && '\$`\\\n'.contains(next) ? 2 : 1);
          default:
            _copy(1);
        }
      }
      if (_i < source.length) _copy(1);
    }
  }

  bool _atHeredocEnd(_Heredoc heredoc) =>
      _heredocLine(heredoc) == heredoc.delimiter;

  /// Whether bash versions may disagree on whether the body line at the
  /// cursor, inside a command substitution, ends the heredoc or the
  /// substitution: bash 5.2 ends the heredoc at `EOF)`, `EOF )` or `EOF #)`,
  /// and bash 3.2 ends the substitution at a `)` in the body.
  bool _unclearHeredocLine(_Heredoc heredoc) {
    final line = _heredocLine(heredoc);
    return line.startsWith(heredoc.delimiter) ||
        _codeInCommandSubHeredoc.hasMatch(line);
  }

  /// The line at the cursor, without the tabs `<<-` strips.
  String _heredocLine(_Heredoc heredoc) {
    var start = _i;
    if (heredoc.stripTabs) {
      while (start < source.length && source[start] == '\t') {
        start++;
      }
    }
    final newline = source.indexOf('\n', start);
    return source.substring(start, newline < 0 ? source.length : newline);
  }

  void _dollar(
    String? forbidden, {
    required bool quoted,
    required bool inCommandSub,
  }) {
    if (_at(r'$((')) {
      _copy(3);
      _code(
        '))',
        forbidden ?? _arithmetic,
        inCommandSub: inCommandSub,
        heredocs: false,
      );
    } else if (_at(r'$(')) {
      _copy(2);
      _code(')', forbidden, inCommandSub: true);
    } else if (_at(r'${')) {
      _copy(2);
      _code(
        '}',
        forbidden ?? 'a parameter expansion `\${...}`',
        inCommandSub: inCommandSub,
        heredocs: false,
      );
    } else if (_at(r'$[')) {
      _copy(2);
      _code(
        ']',
        forbidden ?? _arithmetic,
        inCommandSub: inCommandSub,
        heredocs: false,
      );
    } else if (!quoted && _at(r"$'")) {
      _copy(1);
      _single(forbidden, ansi: true);
    } else {
      _copy(1);
    }
  }

  /// Reads `'...'`, or `$'...'` when [ansi], whose backslash escapes are
  /// honoured.
  void _single(String? forbidden, {required bool ansi}) {
    _copy(1);
    final resume = ansi ? r"$'" : "'";
    while (_i < source.length && source[_i] != "'") {
      if (_placeholder(forbidden, (v) => '\'"\$$v"$resume')) continue;
      _copy(ansi && source[_i] == r'\' ? 2 : 1);
    }
    _copy(1);
  }

  void _double(String? forbidden, {required bool inCommandSub}) {
    _copy(1);
    while (_i < source.length && source[_i] != '"') {
      if (_placeholder(forbidden, (v) => '\${$v}')) continue;
      final next = _i + 1 < source.length ? source[_i + 1] : '';
      switch (source[_i]) {
        case r'\' when next.isNotEmpty && '"\\\$`\n'.contains(next):
          _copy(2);
        case '`':
          _copy(1);
          _code('`', forbidden, inCommandSub: true);
        case r'$':
          _dollar(forbidden, quoted: true, inCommandSub: inCommandSub);
        default:
          _copy(1);
      }
    }
    _copy(1);
  }
}
