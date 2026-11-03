import 'config_file/config_file.dart';
import 'data/call_template.dart';
import 'json.dart';
import 'post_processing/tool_post_processor.dart';
import 'tool_repository.dart';
import 'tool_search.dart';
import 'variables.dart';

class UtcpClientConfig {
  UtcpClientConfig({
    this.variables = const {},
    this.variableLoaders = const [],
    ToolRepository? toolRepository,
    this.toolSearchStrategy = const TagSearchStrategy(),
    this.manualCallTemplates = const [],
    this.postProcessing = const [],
    this.environment,
  }) : toolRepository = toolRepository ?? InMemoryToolRepository();

  /// Parses the JSON configuration format shared with the other UTCP SDKs.
  ///
  /// Call template types must be registered first; `UtcpClient.fromJson`
  /// does that for the protocols it is given. Loaders from
  /// `load_variables_from` are parsed with [VariableLoader.registry] and
  /// consulted before [variableLoaders]; `tool_repository`,
  /// `tool_search_strategy` and `post_processing` are parsed with
  /// [ToolRepository.registry], [ToolSearchStrategy.registry] and
  /// [ToolPostProcessor.registry].
  factory UtcpClientConfig.fromJson(
    JsonMap json, {
    List<VariableLoader> variableLoaders = const [],
    Map<String, String>? environment,
  }) {
    final repository = json.optObject('tool_repository');
    final search = json.optObject('tool_search_strategy');
    return UtcpClientConfig(
      variables: json.optStringMap('variables') ?? const {},
      variableLoaders: [
        for (final loader
            in json.optObjectList('load_variables_from') ?? const <JsonMap>[])
          VariableLoader.registry.parse(loader),
        ...variableLoaders,
      ],
      toolRepository: repository == null
          ? null
          : ToolRepository.fromJson(repository),
      toolSearchStrategy: search == null
          ? const TagSearchStrategy()
          : ToolSearchStrategy.fromJson(search),
      manualCallTemplates: [
        for (final template
            in json.optObjectList('manual_call_templates') ?? const <JsonMap>[])
          CallTemplate.fromJson(template),
      ],
      postProcessing: [
        for (final processor
            in json.optObjectList('post_processing') ?? const <JsonMap>[])
          ToolPostProcessor.fromJson(processor),
      ],
      environment: environment,
    );
  }

  /// Reads a configuration file and parses it with [UtcpClientConfig.fromJson].
  ///
  /// Files ending in `.yaml` or `.yml` are read as YAML, everything else as
  /// JSON. Throws an [UnsupportedError] on platforms without `dart:io`.
  static Future<UtcpClientConfig> fromFile(
    String path, {
    List<VariableLoader> variableLoaders = const [],
    Map<String, String>? environment,
  }) async => UtcpClientConfig.fromJson(
    await readConfigFile(path),
    variableLoaders: variableLoaders,
    environment: environment,
  );

  /// Highest-precedence variable values. Values may themselves reference
  /// variables from loaders or the environment.
  final Map<String, String> variables;
  final List<VariableLoader> variableLoaders;
  final ToolRepository toolRepository;
  final ToolSearchStrategy toolSearchStrategy;

  /// Manuals registered when the client is created.
  final List<CallTemplate> manualCallTemplates;

  /// Applied in order to every tool result and streamed chunk.
  final List<ToolPostProcessor> postProcessing;

  /// Overrides the process environment for variable lookup.
  final Map<String, String>? environment;

  /// The JSON form read by [UtcpClientConfig.fromJson].
  ///
  /// Variable loaders whose [VariableLoader.toJson] is null are left out;
  /// [environment] is not part of the format.
  JsonMap toJson() => {
    'variables': {...variables},
    'load_variables_from': [
      for (final loader in variableLoaders) ?loader.toJson(),
    ],
    'tool_repository': toolRepository.toJson(),
    'tool_search_strategy': toolSearchStrategy.toJson(),
    'manual_call_templates': [
      for (final template in manualCallTemplates) template.toJson(),
    ],
    'post_processing': [
      for (final processor in postProcessing) processor.toJson(),
    ],
  };
}
