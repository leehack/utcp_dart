import 'package:utcp/utcp.dart';

/// One command of a [CliCallTemplate].
class CommandStep {
  /// A step running [command]; see [appendToFinalOutput] for its output.
  const CommandStep(this.command, {this.appendToFinalOutput});

  /// Reads a step from its JSON form (`command`, `append_to_final_output`).
  ///
  /// Throws a [FormatException] when a field has the wrong type. A blank
  /// command parses, as in the reference SDKs, and fails when it runs.
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
  /// An empty [commands] list, a blank command or an empty [workingDir] is
  /// accepted here, as in the reference SDKs, and fails discovery or the
  /// call.
  CliCallTemplate({
    super.name,
    required this.commands,
    this.envVars,
    this.inheritEnvVars,
    this.workingDir,
    super.allowedCommunicationProtocols,
  });

  /// Reads a template from its JSON form.
  ///
  /// Throws a [FormatException] when a field is malformed or `auth` is set.
  factory CliCallTemplate.fromJson(JsonMap json) {
    if (json['auth'] != null) {
      throw const FormatException('cli call templates do not support auth.');
    }
    final commands = [
      for (final step in json.objectList('commands'))
        CommandStep.fromJson(step),
    ];
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

  /// Commands run in order in one shell. Running an empty list or a blank
  /// command fails.
  final List<CommandStep> commands;

  /// Variables set for the commands, on top of the inherited ones.
  final Map<String, String>? envVars;

  /// Host variables passed to the commands. When null, a default allowlist
  /// (`PATH`, `HOME`, `LANG`, ... on Unix; `PATH`, `SYSTEMROOT`, ... on
  /// Windows) is inherited; an empty list inherits nothing.
  final List<String>? inheritEnvVars;

  /// Directory the commands start in; the current directory when null.
  /// Running with an empty directory fails.
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
