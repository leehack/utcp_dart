import 'package:utcp/utcp.dart';

/// One command of a [CliCallTemplate].
class CommandStep {
  const CommandStep(this.command, {this.appendToFinalOutput});

  factory CommandStep.fromJson(JsonMap json) => CommandStep(
    json.string('command'),
    appendToFinalOutput: json.optBool('append_to_final_output'),
  );

  /// Shell command text. `UTCP_ARG_<name>_UTCP_END` placeholders take the
  /// tool argument `<name>`; `$CMD_<i>_OUTPUT` holds the output of command
  /// `i`.
  final String command;

  /// Whether this command's output is part of the result. When null, only
  /// the last command's output is.
  final bool? appendToFinalOutput;

  JsonMap toJson() => {
    'command': command,
    'append_to_final_output': ?appendToFinalOutput,
  };
}

/// Runs [commands] in order in one shell process: `/bin/bash` on macOS and
/// Linux, `powershell.exe` on Windows.
///
/// Tool arguments never become script text: each placeholder is replaced by
/// a reference to a per-call environment variable that carries the value, so
/// an argument cannot inject shell syntax.
class CliCallTemplate extends CallTemplate {
  CliCallTemplate({
    super.name,
    required this.commands,
    this.envVars,
    this.inheritEnvVars,
    this.workingDir,
    super.allowedCommunicationProtocols,
  }) {
    if (commands.isEmpty) {
      throw ArgumentError.value(commands, 'commands', 'Must not be empty');
    }
  }

  factory CliCallTemplate.fromJson(JsonMap json) {
    if (json['auth'] != null) {
      throw const FormatException('cli call templates do not support auth.');
    }
    final commands = [
      for (final step in json.objectList('commands'))
        CommandStep.fromJson(step),
    ];
    if (commands.isEmpty) {
      throw const FormatException("Field 'commands' must not be empty.");
    }
    return CliCallTemplate(
      name: json.optString('name'),
      commands: commands,
      envVars: json.optStringMap('env_vars'),
      inheritEnvVars: json.optStringList('inherit_env_vars'),
      workingDir: json.optString('working_dir'),
      allowedCommunicationProtocols: json.allowedCommunicationProtocols,
    );
  }

  static const type = 'cli';

  final List<CommandStep> commands;

  /// Variables set for the commands, on top of the inherited ones.
  final Map<String, String>? envVars;

  /// Host variables passed to the commands. When null, a default allowlist
  /// (`PATH`, `HOME`, `LANG`, ... on Unix; `PATH`, `SYSTEMROOT`, ... on
  /// Windows) is inherited; an empty list inherits nothing.
  final List<String>? inheritEnvVars;

  /// Directory the commands start in; the current directory when null.
  final String? workingDir;

  @override
  String get callTemplateType => type;

  @override
  JsonMap fieldsToJson() => {
    'commands': [for (final step in commands) step.toJson()],
    'env_vars': ?envVars,
    'inherit_env_vars': ?inheritEnvVars,
    'working_dir': ?workingDir,
  };
}
