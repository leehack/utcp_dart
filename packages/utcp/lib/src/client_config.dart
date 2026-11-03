import 'data/call_template.dart';
import 'json.dart';
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
    this.environment,
  }) : toolRepository = toolRepository ?? InMemoryToolRepository();

  /// Parses the JSON configuration format shared with the other UTCP SDKs.
  ///
  /// Call template types must be registered first; `UtcpClient.fromJson`
  /// does that for the protocols it is given. Loaders from
  /// `load_variables_from` are parsed with [VariableLoader.registry] and
  /// consulted before [variableLoaders].
  factory UtcpClientConfig.fromJson(
    JsonMap json, {
    List<VariableLoader> variableLoaders = const [],
    Map<String, String>? environment,
  }) {
    final repository = json.optObject('tool_repository');
    final repositoryType =
        repository?.optString('tool_repository_type') ?? 'in_memory';
    if (repositoryType != 'in_memory') {
      throw FormatException(
        "Unsupported tool_repository_type '$repositoryType'.",
      );
    }
    if (json.optList('post_processing')?.isNotEmpty ?? false) {
      throw const FormatException('post_processing is not supported yet.');
    }
    final search = json.optObject('tool_search_strategy');
    return UtcpClientConfig(
      variables: json.optStringMap('variables') ?? const {},
      variableLoaders: [
        for (final loader
            in json.optObjectList('load_variables_from') ?? const <JsonMap>[])
          VariableLoader.registry.parse(loader),
        ...variableLoaders,
      ],
      toolSearchStrategy: search == null
          ? const TagSearchStrategy()
          : TagSearchStrategy.fromJson(search),
      manualCallTemplates: [
        for (final template
            in json.optObjectList('manual_call_templates') ?? const <JsonMap>[])
          CallTemplate.fromJson(template),
      ],
      environment: environment,
    );
  }

  /// Highest-precedence variable values. Values may themselves reference
  /// variables from loaders or the environment.
  final Map<String, String> variables;
  final List<VariableLoader> variableLoaders;
  final ToolRepository toolRepository;
  final ToolSearchStrategy toolSearchStrategy;

  /// Manuals registered when the client is created.
  final List<CallTemplate> manualCallTemplates;

  /// Overrides the process environment for variable lookup.
  final Map<String, String>? environment;
}
