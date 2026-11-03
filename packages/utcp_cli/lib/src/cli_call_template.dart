import 'package:utcp/utcp.dart';

/// One command of a [CliCallTemplate].
class CommandStep {
  /// A step running [command]; see [appendToFinalOutput] for its output.
  const CommandStep(this.command, {this.appendToFinalOutput});

  /// Reads a step from its JSON form (`command`, `append_to_final_output`).
  ///
  /// Throws a [FormatException] when a field has the wrong type or the
  /// command is blank.
  factory CommandStep.fromJson(JsonMap json) {
    final command = json.string('command');
    if (command.trim().isEmpty) {
      throw const FormatException("Field 'command' must not be blank.");
    }
    return CommandStep(
      command,
      appendToFinalOutput: json.optBool('append_to_final_output'),
    );
  }

  /// Shell command text. `UTCP_ARG_<name>_UTCP_END` placeholders take the
  /// tool argument `<name>`; `$CMD_<i>_OUTPUT` holds the output of command
  /// `i`.
  final String command;

  /// Whether this command's output is part of the result. When null, only
  /// the last command's output is.
  final bool? appendToFinalOutput;

  /// The JSON form read by [CommandStep.fromJson].
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
/// an argument cannot inject shell syntax. Bash still evaluates a value used
/// as a number as code, so a placeholder in an arithmetic context is
/// rejected; see the package README for the contexts to avoid.
class CliCallTemplate extends CallTemplate {
  /// A template running [commands] in order.
  ///
  /// Throws an [ArgumentError] when [commands] is empty or a command is
  /// blank.
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
    if (commands.any((step) => step.command.trim().isEmpty)) {
      throw ArgumentError.value(
        commands,
        'commands',
        'Must not contain a blank command',
      );
    }
  }

  /// Reads a template from its JSON form.
  ///
  /// Throws a [FormatException] when a field is malformed, `commands` is
  /// empty or a command is blank, or `auth` is set.
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

  /// The `call_template_type` of CLI templates.
  static const type = 'cli';

  /// Commands run in order in one shell; never empty.
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
