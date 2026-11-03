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
  /// early (`exit`, `exec`, `set -e`) is told apart from one with no output.
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
/// variable assignments carry over to later commands; its output goes to
/// [captureFile] and is read back into `CMD_<i>_OUTPUT`. PowerShell
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
    switch (shell) {
      case Shell.bash:
        lines.addAll([
          '{ $command',
          '} >"\$$capture" 2>&1',
          r'__utcp_status=$?',
          '$output=\$(<"\$$capture")',
          r'(exit $__utcp_status)',
        ]);
      case Shell.powershell:
        lines.add('\$$output = $command 2>&1 | Out-String');
    }
  }
  for (final (i, step) in commands.indexed) {
    if (step.appendToFinalOutput ?? i == commands.length - 1) {
      lines.add(switch (shell) {
        Shell.bash => "printf '%s\\n' \"\${CMD_${i}_OUTPUT}\"",
        Shell.powershell => 'Write-Output \$CMD_${i}_OUTPUT',
      });
    }
  }
  if (shell == Shell.powershell) {
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
/// an array subscript, a `[[ ]]` with an arithmetic comparison, a `let`
/// command and a `declare -i`-style declaration.
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
    final variable = '__UTCP_ARG_${nonce}_$name';
    environment[variable] = value;
    return variable;
  }

  return switch (shell) {
    Shell.bash => _BashSubstitution(command, bind).run(),
    Shell.powershell => _substitutePowerShell(command, bind),
  };
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
final _wordBreak = RegExp(r'[\s;&|()<>]');
final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final _arithmeticTest = RegExp(r'(^|\s)-(eq|ne|lt|le|gt|ge)(?=\s|$)');
final _integerOption = RegExp(r'^-[A-Za-z]*i');
final _assignment = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=');
const _keywords = {'if', 'then', 'else', 'elif', 'do', 'while', 'until', '!'};
const _declarations = {'declare', 'typeset', 'local', 'readonly', 'export'};

/// A one-pass reader of bash command text that tracks quoting, nested
/// command substitutions and the contexts where bash evaluates a value as
/// an arithmetic expression.
///
/// Each `_code`, `_single` and `_double` call reads one region and copies it
/// to the output, with placeholders replaced. `forbidden` names the
/// enclosing context, if any, where a placeholder is rejected: it is passed
/// down, so a value printed by `$(...)` inside `$(( ))` is rejected too.
final class _BashSubstitution {
  _BashSubstitution(this.source, this.bind);

  final String source;
  final String Function(String name) bind;
  final _out = StringBuffer();

  /// Names of the placeholders read so far, in order.
  final _bound = <String>[];
  var _i = 0;

  String run() {
    _code(null, null);
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
    if (forbidden != null) _reject(name, forbidden);
    _bound.add(name);
    _out.write(reference(bind(name)));
    _i = match.end;
    return true;
  }

  Never _reject(String name, String context) => throw UtcpException(
    'Placeholder UTCP_ARG_${name}_UTCP_END is inside $context, where bash '
    'would run code embedded in the value. Compare numbers with `[ ]` or '
    '`test`, or pass the value to a program such as `expr`.',
  );

  bool get _atWordStart => _i == 0 || _wordBreak.hasMatch(source[_i - 1]);

  /// Whether the word before the cursor is a variable name, so a `[` here
  /// opens an array subscript.
  bool get _afterName {
    var start = _i;
    while (start > 0 && !_wordBreak.hasMatch(source[start - 1])) {
      start--;
    }
    return start < _i && _name.hasMatch(source.substring(start, _i));
  }

  /// Reads shell code up to [end] (outside any nested parentheses), or to
  /// the end of the text when [end] is null.
  void _code(String? end, String? forbidden) {
    var depth = 0;
    var commandStart = _i;
    var boundAtCommandStart = _bound.length;
    void endCommand() {
      _checkCommand(source.substring(commandStart, _i), boundAtCommandStart);
      commandStart = _i;
      boundAtCommandStart = _bound.length;
    }

    while (_i < source.length) {
      if (end != null && depth == 0 && _at(end)) {
        endCommand();
        _copy(end.length);
        return;
      }
      if (_placeholder(forbidden, (v) => '"\$$v"')) continue;
      switch (source[_i]) {
        case r'\':
          _copy(2);
        case "'":
          _single(forbidden, ansi: false);
        case '"':
          _double(forbidden);
        case '`':
          _copy(1);
          _code('`', forbidden);
        case r'$':
          _dollar(forbidden, quoted: false);
        case '#' when _atWordStart:
          final newline = source.indexOf('\n', _i);
          _copy((newline < 0 ? source.length : newline) - _i);
        case '(' when _at('(('):
          _copy(2);
          _code('))', forbidden ?? _arithmetic);
        case '[' when _at('[[') && _atWordStart:
          _copy(2);
          final start = _i;
          final bound = _bound.length;
          _code(']]', forbidden);
          if (_bound.length > bound &&
              _arithmeticTest.hasMatch(source.substring(start, _i))) {
            _reject(_bound[bound], 'a `[[ ]]` arithmetic comparison');
          }
        case '[' when _afterName:
          _copy(1);
          _code(']', forbidden ?? 'an array subscript');
        case '(' || ')' || ';' || '&' || '|' || '\n':
          endCommand();
          if (source[_i] == '(') depth++;
          if (source[_i] == ')' && depth > 0) depth--;
          _copy(1);
          commandStart = _i;
        default:
          _copy(1);
      }
    }
    endCommand();
  }

  /// Rejects placeholders read since [boundAtStart] when [command] is a
  /// simple command that evaluates its arguments as arithmetic.
  void _checkCommand(String command, int boundAtStart) {
    if (_bound.length == boundAtStart) return;
    final words = command
        .trim()
        .split(RegExp(r'\s+'))
        .skipWhile((w) => _keywords.contains(w) || _assignment.hasMatch(w))
        .toList();
    if (words.isEmpty) return;
    if (words.first == 'let') _reject(_bound[boundAtStart], 'a `let` command');
    if (_declarations.contains(words.first) &&
        words.skip(1).any(_integerOption.hasMatch)) {
      _reject(_bound[boundAtStart], 'an integer (`-i`) declaration');
    }
  }

  void _dollar(String? forbidden, {required bool quoted}) {
    if (_at(r'$((')) {
      _copy(3);
      _code('))', forbidden ?? _arithmetic);
    } else if (_at(r'$(')) {
      _copy(2);
      _code(')', forbidden);
    } else if (_at(r'${')) {
      _copy(2);
      _code('}', forbidden ?? 'a parameter expansion `\${...}`');
    } else if (_at(r'$[')) {
      _copy(2);
      _code(']', forbidden ?? _arithmetic);
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

  void _double(String? forbidden) {
    _copy(1);
    while (_i < source.length && source[_i] != '"') {
      if (_placeholder(forbidden, (v) => '\${$v}')) continue;
      final next = _i + 1 < source.length ? source[_i + 1] : '';
      switch (source[_i]) {
        case r'\' when next.isNotEmpty && '"\\\$`\n'.contains(next):
          _copy(2);
        case '`':
          _copy(1);
          _code('`', forbidden);
        case r'$':
          _dollar(forbidden, quoted: true);
        default:
          _copy(1);
      }
    }
    _copy(1);
  }
}
