import 'dart:math';

import 'package:logging/logging.dart';

import 'communication_protocol.dart';
import 'data/call_template.dart';
import 'data/tool.dart';
import 'data/utcp_manual.dart';
import 'exceptions.dart';
import 'http/http_communication_protocol.dart';
import 'json.dart';
import 'tool_repository.dart';
import 'tool_search.dart';
import 'variables.dart';

final _log = Logger('utcp');

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
  /// Supports `variables`, `manual_call_templates`, an `in_memory`
  /// `tool_repository`, and a `tag_and_description_word_match`
  /// `tool_search_strategy`.
  factory UtcpClientConfig.fromJson(
    JsonMap json, {
    List<VariableLoader> variableLoaders = const [],
  }) {
    final repository = optionalMap(json, 'tool_repository');
    final repositoryType = repository?['tool_repository_type'] ?? 'in_memory';
    if (repositoryType != 'in_memory') {
      throw FormatException('Unsupported tool_repository_type: $repositoryType');
    }
    final search = optionalMap(json, 'tool_search_strategy');
    final searchType = search?['tool_search_strategy_type'] ?? 'tag_and_description_word_match';
    if (searchType != 'tag_and_description_word_match') {
      throw FormatException('Unsupported tool_search_strategy_type: $searchType');
    }
    if (optionalField<List>(json, 'post_processing')?.isNotEmpty ?? false) {
      throw const FormatException('post_processing is not supported yet.');
    }
    return UtcpClientConfig(
      variables: optionalStringMap(json, 'variables') ?? const {},
      variableLoaders: variableLoaders,
      toolSearchStrategy: TagSearchStrategy(
        descriptionWeight: (search?['description_weight'] as num?)?.toDouble() ?? 1,
        tagWeight: (search?['tag_weight'] as num?)?.toDouble() ?? 3,
      ),
      manualCallTemplates: [
        for (final (i, t)
            in (optionalField<List>(json, 'manual_call_templates') ?? const []).indexed)
          CallTemplate.fromJson(asJsonMap(t, 'manual_call_templates[$i]')),
      ],
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

/// Discovers tools from UTCP manuals and calls them through the matching
/// communication protocol.
class UtcpClient {
  UtcpClient._(this.config, this._substitutor, this._protocols, this._ownedProtocols);

  final UtcpClientConfig config;
  final VariableSubstitutor _substitutor;
  final Map<String, CommunicationProtocol> _protocols;
  final List<CommunicationProtocol> _ownedProtocols;

  /// Creates a client and registers [UtcpClientConfig.manualCallTemplates].
  ///
  /// An HTTP protocol is created (and closed by [close]) unless [protocols]
  /// supplies one for `http`. Protocols passed in [protocols] stay owned by
  /// the caller.
  static Future<UtcpClient> create({
    UtcpClientConfig? config,
    Map<String, CommunicationProtocol> protocols = const {},
  }) async {
    config ??= UtcpClientConfig();
    final owned = <CommunicationProtocol>[
      if (!protocols.containsKey('http')) HttpCommunicationProtocol(),
    ];
    final allProtocols = <String, CommunicationProtocol>{
      for (final protocol in owned) 'http': protocol,
      ...protocols,
    };
    try {
      final resolvedVariables =
          await VariableSubstitutor(
                loaders: config.variableLoaders,
                environment: config.environment,
              ).substitute(config.variables)
              as Map<String, dynamic>;
      final client = UtcpClient._(
        config,
        VariableSubstitutor(
          variables: resolvedVariables.map((k, v) => MapEntry(k, v as String)),
          loaders: config.variableLoaders,
          environment: config.environment,
        ),
        allProtocols,
        owned,
      );
      await client.registerManuals(config.manualCallTemplates);
      return client;
    } catch (_) {
      await Future.wait(owned.map((p) => p.close()));
      rethrow;
    }
  }

  ToolRepository get _repository => config.toolRepository;

  Future<Tool?> getTool(String toolName) => _repository.getTool(toolName);

  Future<List<Tool>> getTools() => _repository.getTools();

  /// Discovers and stores the tools of one manual.
  ///
  /// The manual name is sanitized to `[A-Za-z0-9_]` (a random name is used
  /// when absent) and every tool name is prefixed with `manual_name.`. Tools
  /// using a transport outside the manual's allowed protocols are dropped.
  /// Throws if a manual with the same name is already registered.
  Future<RegisterManualResult> registerManual(CallTemplate manualCallTemplate) async {
    final json = manualCallTemplate.toJson();
    final name = ((json['name'] as String?) ?? _randomName()).replaceAll(RegExp(r'\W'), '_');
    json['name'] = name;

    if (await _repository.getManual(name) != null) {
      throw UtcpException(
        "Manual '$name' already registered. Use a different name or deregister the existing manual.",
      );
    }

    final processed = await substituteCallTemplateVariables(CallTemplate.fromJson(json), name);
    final protocol = _protocolFor(processed.callTemplateType);
    final result = await protocol.registerManual(this, processed);

    if (!result.success) {
      _log.warning("Error registering manual '$name': ${result.errors.join(', ')}");
      return result;
    }

    final allowed = processed.effectiveAllowedProtocols;
    final tools = <Tool>[];
    for (final tool in result.manual.tools) {
      final toolProtocol = tool.toolCallTemplate.callTemplateType;
      if (!allowed.contains(toolProtocol)) {
        _log.warning(
          "Tool '${tool.name}' uses protocol '$toolProtocol', which manual '$name' does not "
          'allow ($allowed). It will not be registered.',
        );
        continue;
      }
      tools.add(tool.name.startsWith('$name.') ? tool : tool.copyWith(name: '$name.${tool.name}'));
    }
    final manual = UtcpManual(
      utcpVersion: result.manual.utcpVersion,
      manualVersion: result.manual.manualVersion,
      tools: tools,
    );
    await _repository.saveManual(processed, manual);
    _log.info("Registered manual '$name' with ${tools.length} tools.");
    return RegisterManualResult(
      manualCallTemplate: processed,
      manual: manual,
      success: true,
      errors: result.errors,
    );
  }

  /// Registers several manuals concurrently. Failures are returned as
  /// unsuccessful results instead of being thrown.
  Future<List<RegisterManualResult>> registerManuals(List<CallTemplate> manualCallTemplates) =>
      Future.wait(
        manualCallTemplates.map((template) async {
          try {
            return await registerManual(template);
          } catch (e) {
            _log.warning("Error registering manual '${template.name}': $e");
            return RegisterManualResult(
              manualCallTemplate: template,
              manual: const UtcpManual(tools: []),
              success: false,
              errors: ['$e'],
            );
          }
        }),
      );

  Future<bool> deregisterManual(String manualName) async {
    final template = await _repository.getManualCallTemplate(manualName);
    if (template == null) return false;
    await _protocols[template.callTemplateType]?.deregisterManual(this, template);
    return _repository.removeManual(manualName);
  }

  /// Calls a registered tool by its full `manual_name.tool_name`.
  Future<Object?> callTool(String toolName, [Map<String, dynamic> toolArgs = const {}]) async {
    final (template, protocol) = await _prepareCall(toolName);
    _log.fine("Calling tool '$toolName' via '${template.callTemplateType}'.");
    return protocol.callTool(this, toolName, toolArgs, template);
  }

  /// Calls a tool and yields its result chunks. Transports without native
  /// streaming yield the full result once.
  Stream<Object?> callToolStreaming(
    String toolName, [
    Map<String, dynamic> toolArgs = const {},
  ]) async* {
    final (template, protocol) = await _prepareCall(toolName);
    yield* protocol.callToolStreaming(this, toolName, toolArgs, template);
  }

  Future<(CallTemplate, CommunicationProtocol)> _prepareCall(String toolName) async {
    final manualName = toolName.split('.').first;
    final tool = await _repository.getTool(toolName);
    if (tool == null) throw UtcpException("Tool '$toolName' not found.");
    final manualTemplate = await _repository.getManualCallTemplate(manualName);
    if (manualTemplate == null) {
      throw UtcpException("Manual call template for '$manualName' not found.");
    }
    final toolProtocol = tool.toolCallTemplate.callTemplateType;
    final allowed = manualTemplate.effectiveAllowedProtocols;
    if (!allowed.contains(toolProtocol)) {
      throw UtcpSecurityException(
        "Tool '$toolName' uses protocol '$toolProtocol', which manual '$manualName' "
        'does not allow ($allowed).',
      );
    }
    final template = await substituteCallTemplateVariables(tool.toolCallTemplate, manualName);
    return (template, _protocolFor(template.callTemplateType));
  }

  Future<List<Tool>> searchTools(String query, {int limit = 10, List<String>? anyOfTagsRequired}) =>
      config.toolSearchStrategy.searchTools(
        _repository,
        query,
        limit: limit,
        anyOfTagsRequired: anyOfTagsRequired,
      );

  /// Variable keys a manual call template needs before it can be registered.
  List<String> getRequiredVariablesForManual(CallTemplate manualCallTemplate) =>
      _substitutor.findRequiredVariables(
        manualCallTemplate.toJson(),
        namespace: manualCallTemplate.name?.replaceAll(RegExp(r'\W'), '_'),
      );

  Future<List<String>> getRequiredVariablesForRegisteredTool(String toolName) async {
    final tool = await _repository.getTool(toolName);
    if (tool == null) throw UtcpException("Tool '$toolName' not found.");
    return _substitutor.findRequiredVariables(
      tool.toolCallTemplate.toJson(),
      namespace: toolName.split('.').first,
    );
  }

  Future<CallTemplate> substituteCallTemplateVariables(
    CallTemplate template, [
    String? namespace,
  ]) async {
    final substituted = await _substitutor.substitute(template.toJson(), namespace: namespace);
    return CallTemplate.fromJson(substituted as JsonMap);
  }

  CommunicationProtocol _protocolFor(String type) =>
      _protocols[type] ??
      (throw UtcpException("No communication protocol registered for type '$type'."));

  /// Closes the protocols this client created.
  Future<void> close() async {
    await Future.wait(_ownedProtocols.map((p) => p.close()));
  }

  static String _randomName() {
    final random = Random.secure();
    return 'manual_${List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join()}';
  }
}
