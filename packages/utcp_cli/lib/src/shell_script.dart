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
  const ShellScript(this.source, this.environment);

  final String source;

  /// Tool argument values (and the capture file) referenced by [source].
  final Map<String, String> environment;
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
      case Shell.bash when command.trim().isEmpty:
        lines.add('$output=');
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
  return ShellScript(lines.join('\n'), environment);
}

final _placeholder = RegExp('UTCP_ARG_([a-zA-Z0-9_]+?)_UTCP_END');

/// Replaces every `UTCP_ARG_<name>_UTCP_END` in [command] with a reference
/// to a variable holding the argument, chosen for the quoting context it
/// sits in, and records the value in [environment].
///
/// The shell expands the reference after it has parsed the script, so the
/// value is always one word and never shell syntax. The quote tracking and
/// emitted forms match the Python and TypeScript SDKs (GHSA-33p6-5jxp-p3x4):
///
/// - bash: `"$V"` bare, `${V}` inside `"..."`, `'"$V"'` inside `'...'`.
/// - PowerShell: `${env:V}`; a placeholder inside `'...'` is rejected
///   because PowerShell does not expand there.
///
/// Throws a [UtcpException] when an argument is missing.
String substitutePlaceholders(
  String command,
  ToolArguments arguments, {
  required Shell shell,
  required String nonce,
  required Map<String, String> environment,
}) {
  final escape = shell == Shell.bash ? r'\' : '`';
  final out = StringBuffer();
  var quote = _Quote.none;
  var i = 0;
  while (i < command.length) {
    if (_placeholder.matchAsPrefix(command, i) case final match?) {
      final name = match.group(1)!;
      if (!arguments.containsKey(name)) {
        throw UtcpException(
          "Missing argument '$name' for placeholder UTCP_ARG_${name}_UTCP_END.",
        );
      }
      if (shell == Shell.powershell && quote == _Quote.single) {
        throw UtcpException(
          'Placeholder UTCP_ARG_${name}_UTCP_END is inside a PowerShell '
          'single-quoted string, where variables do not expand. Use a '
          'double-quoted string instead.',
        );
      }
      final variable = '__UTCP_ARG_${nonce}_$name';
      environment[variable] = switch (arguments[name]) {
        final String value => value,
        final value => jsonEncode(value),
      };
      out.write(switch ((shell, quote)) {
        (Shell.powershell, _) => '\${env:$variable}',
        (Shell.bash, _Quote.none) => '"\$$variable"',
        (Shell.bash, _Quote.double) => '\${$variable}',
        (Shell.bash, _Quote.single) => '\'"\$$variable"\'',
      });
      i = match.end;
      continue;
    }
    final char = command[i];
    final next = i + 1 < command.length ? command[i + 1] : null;
    final escapes = switch (quote) {
      _Quote.none => char == escape && next != null,
      _Quote.double =>
        char == escape &&
            next != null &&
            (shell == Shell.powershell || '"\\\$`\n'.contains(next)),
      // PowerShell writes a literal ' inside '...' as ''.
      _Quote.single => shell == Shell.powershell && char == "'" && next == "'",
    };
    if (escapes) {
      out
        ..write(char)
        ..write(next);
      i += 2;
      continue;
    }
    quote = switch ((quote, char)) {
      (_Quote.none, "'") => _Quote.single,
      (_Quote.none, '"') => _Quote.double,
      (_Quote.single, "'") || (_Quote.double, '"') => _Quote.none,
      _ => quote,
    };
    out.write(char);
    i++;
  }
  return out.toString();
}

enum _Quote { none, single, double }
