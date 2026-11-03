import 'dart:math';

import 'package:logging/logging.dart';

import 'client_config.dart';
import 'communication_protocol.dart';
import 'config_file/config_file.dart';
import 'data/call_template.dart';
import 'data/call_template_scope.dart';
import 'data/tool.dart';
import 'data/utcp_manual.dart';
import 'exceptions.dart';
import 'http/http_communication_protocol.dart';
import 'http/sse_communication_protocol.dart';
import 'http/streamable_http_communication_protocol.dart';
import 'json.dart';
import 'registry.dart';
import 'text/text_communication_protocol.dart';
import 'tool_repository.dart';
import 'variables.dart';

final _log = Logger('utcp');

/// Protocols every client gets unless one passed to [UtcpClient.create]
/// serves the same call template type.
final Map<String, CommunicationProtocol Function()> _coreProtocols = {
  'http': HttpCommunicationProtocol.new,
  'sse': SseCommunicationProtocol.new,
  'streamable_http': StreamableHttpCommunicationProtocol.new,
  'text': TextCommunicationProtocol.new,
};

/// Discovers tools from UTCP manuals and calls them through the matching
/// communication protocol.
class UtcpClient {
  UtcpClient._(
    this.config,
    this._substitutor,
    this._protocols,
    this._callTemplates,
    this.rootDir,
  );

  final UtcpClientConfig config;
  final VariableSubstitutor _substitutor;
  final Map<String, CommunicationProtocol> _protocols;
  final TypeRegistry<CallTemplate> _callTemplates;

  /// Directory that transports resolve relative paths against, like the
  /// `root_dir` of the Python and TypeScript clients; the current directory
  /// when null.
  final String? rootDir;

  /// Manual names whose registration is in flight.
  final _registering = <String>{};

  /// Creates a client and registers [UtcpClientConfig.manualCallTemplates].
  ///
  /// [protocols] add transports (for example from `utcp_mcp`) or replace a
  /// core one for the same call template type. The client parses call
  /// templates with their parsers first, then with [CallTemplate.registry];
  /// a type [CallTemplate.registry] does not know yet is added to it, but a
  /// parser already there is never replaced, so one client's protocols do
  /// not change parsing for other clients. The client closes every protocol
  /// it uses in [close].
  static Future<UtcpClient> create({
    UtcpClientConfig? config,
    List<CommunicationProtocol> protocols = const [],
    String? rootDir,
  }) => _create(
    config ?? UtcpClientConfig(),
    protocols,
    _callTemplateRegistry(protocols),
    rootDir,
  );

  static Future<UtcpClient> _create(
    UtcpClientConfig config,
    List<CommunicationProtocol> protocols,
    TypeRegistry<CallTemplate> callTemplates,
    String? rootDir,
  ) async {
    final byType = _byType(protocols);
    try {
      final substitutor = VariableSubstitutor(
        variables: await VariableSubstitutor(
          loaders: config.variableLoaders,
          environment: config.environment,
        ).substituteStrings(config.variables),
        loaders: config.variableLoaders,
        environment: config.environment,
      );
      final client = UtcpClient._(
        config,
        substitutor,
        byType,
        callTemplates,
        rootDir,
      );
      await client.registerManuals(config.manualCallTemplates);
      return client;
    } on Object {
      await _closeAll(byType.values);
      rethrow;
    }
  }

  /// Parses [config] in the JSON format shared with the other UTCP SDKs,
  /// with the call template parsers of [protocols], and creates the client.
  static Future<UtcpClient> fromJson(
    JsonMap config, {
    List<CommunicationProtocol> protocols = const [],
    List<VariableLoader> variableLoaders = const [],
    Map<String, String>? environment,
    String? rootDir,
  }) {
    final callTemplates = _callTemplateRegistry(protocols);
    return _create(
      withCallTemplateRegistry(
        callTemplates,
        () => UtcpClientConfig.fromJson(
          config,
          variableLoaders: variableLoaders,
          environment: environment,
        ),
      ),
      protocols,
      callTemplates,
      rootDir,
    );
  }

  /// Reads a JSON or YAML configuration file, as
  /// [UtcpClientConfig.fromFile] does, and creates the client as [fromJson]
  /// does. Throws an [UnsupportedError] on platforms without `dart:io`.
  static Future<UtcpClient> fromFile(
    String path, {
    List<CommunicationProtocol> protocols = const [],
    List<VariableLoader> variableLoaders = const [],
    Map<String, String>? environment,
    String? rootDir,
  }) async => fromJson(
    await readConfigFile(path),
    protocols: protocols,
    variableLoaders: variableLoaders,
    environment: environment,
    rootDir: rootDir,
  );

  static Map<String, CommunicationProtocol> _byType(
    List<CommunicationProtocol> protocols,
  ) {
    final byType = {
      for (final protocol in protocols)
        for (final type in protocol.callTemplateTypes.keys) type: protocol,
    };
    for (final MapEntry(key: type, value: create) in _coreProtocols.entries) {
      byType.putIfAbsent(type, create);
    }
    return byType;
  }

  static TypeRegistry<CallTemplate> _callTemplateRegistry(
    List<CommunicationProtocol> protocols,
  ) {
    final registry = TypeRegistry<CallTemplate>.scoped(CallTemplate.registry);
    for (final protocol in protocols) {
      for (final MapEntry(key: type, value: parse)
          in protocol.callTemplateTypes.entries) {
        registry.register(type, parse, override: true);
        CallTemplate.registry.register(type, parse);
      }
    }
    return registry;
  }

  static Future<void> _closeAll(Iterable<CommunicationProtocol> protocols) =>
      Future.wait([for (final p in protocols.toSet()) p.close()]);

  ToolRepository get _repository => config.toolRepository;

  Future<Tool?> getTool(String toolName) => _repository.getTool(toolName);

  Future<List<Tool>> getTools() => _repository.getTools();

  /// Discovers and stores the tools of one manual.
  ///
  /// The manual name (a random one when absent) is sanitized as in Python:
  /// every character other than a Unicode letter, number or `_` becomes `_`.
  /// Every tool name is prefixed with `manual_name.`. Tools whose transport
  /// the manual does not allow are dropped. Throws if a manual with the same
  /// name is already registered.
  Future<RegisterManualResult> registerManual(
    CallTemplate manualCallTemplate,
  ) async {
    final name = _sanitize(manualCallTemplate.name ?? _randomName());
    final alreadyRegistered = UtcpException(
      "Manual '$name' already registered. Use a different name or "
      'deregister the existing manual.',
    );
    // Reserved before the first await, so a concurrent registration of the
    // same name sees it.
    if (!_registering.add(name)) throw alreadyRegistered;
    try {
      if (await _repository.getManual(name) != null) throw alreadyRegistered;
      return await _discover(manualCallTemplate, name);
    } finally {
      _registering.remove(name);
    }
  }

  Future<RegisterManualResult> _discover(
    CallTemplate manualCallTemplate,
    String name,
  ) async {
    final CallTemplate processed;
    try {
      processed = await substituteCallTemplateVariables(
        _callTemplates.parse({...manualCallTemplate.toJson(), 'name': name}),
        name,
      );
    } on FormatException catch (e) {
      // A substituted value can make the template invalid, such as a
      // `${URL}` that resolves to an address the transport refuses.
      _log.warning("Error registering manual '$name': ${e.message}");
      return RegisterManualResult.failure(manualCallTemplate, [e.message]);
    }
    final protocol = _protocolFor(processed.callTemplateType);
    final result = await withCallTemplateRegistry(
      _callTemplates,
      () => protocol.registerManual(this, processed),
    );
    if (!result.success) {
      _log.warning(
        "Error registering manual '$name': ${result.errors.join(', ')}",
      );
      return result;
    }

    final allowed = processed.effectiveAllowedProtocols;
    final tools = [
      for (final tool in result.manual.tools)
        if (_isAllowed(tool, allowed, name))
          tool.name.startsWith('$name.')
              ? tool
              : tool.copyWith(name: '$name.${tool.name}'),
    ];
    final manual = UtcpManual(
      utcpVersion: result.manual.utcpVersion,
      manualVersion: result.manual.manualVersion,
      tools: tools,
    );
    await _repository.saveManual(processed, manual);
    _log.info("Registered manual '$name' with ${tools.length} tools.");
    return RegisterManualResult(manualCallTemplate: processed, manual: manual);
  }

  static bool _isAllowed(Tool tool, List<String> allowed, String manual) {
    final protocol = tool.toolCallTemplate.callTemplateType;
    if (allowed.contains(protocol)) return true;
    _log.warning(
      "Tool '${tool.name}' uses communication protocol '$protocol' which is "
      "not in allowed protocols $allowed for manual '$manual'. Tool will not "
      'be registered.',
    );
    return false;
  }

  /// Registers several manuals concurrently. Failures are returned as
  /// unsuccessful results instead of being thrown.
  Future<List<RegisterManualResult>> registerManuals(
    List<CallTemplate> manualCallTemplates,
  ) => Future.wait(
    manualCallTemplates.map((template) async {
      try {
        return await registerManual(template);
      } on Exception catch (e) {
        _log.warning("Error registering manual '${template.name}': $e");
        return RegisterManualResult.failure(template, [
          e is UtcpException ? e.message : '$e',
        ]);
      }
    }),
  );

  Future<bool> deregisterManual(String manualName) async {
    final template = await _repository.getManualCallTemplate(manualName);
    if (template == null) return false;
    await _protocols[template.callTemplateType]?.deregisterManual(
      this,
      template,
    );
    return _repository.removeManual(manualName);
  }

  /// Calls a registered tool by its full `manual_name.tool_name` and runs
  /// [UtcpClientConfig.postProcessing] on the result.
  Future<Object?> callTool(
    String toolName, [
    ToolArguments arguments = const {},
  ]) async {
    final call = await _prepareCall(toolName);
    return call.postProcess(
      await call.protocol.callTool(this, toolName, arguments, call.template),
    );
  }

  /// Calls a tool and yields its result chunks, each run through
  /// [UtcpClientConfig.postProcessing]. Transports without native streaming
  /// yield the whole result once.
  Stream<Object?> callToolStreaming(
    String toolName, [
    ToolArguments arguments = const {},
  ]) async* {
    final call = await _prepareCall(toolName);
    // `yield*` rather than `await for`, so a cancelled listener reaches the
    // transport at once.
    yield* call.protocol
        .callToolStreaming(this, toolName, arguments, call.template)
        .map(call.postProcess);
  }

  Future<_PreparedCall> _prepareCall(String toolName) async {
    final manualName = toolName.split('.').first;
    final tool =
        await _repository.getTool(toolName) ??
        (throw UtcpException("Tool '$toolName' not found."));
    final manualTemplate =
        await _repository.getManualCallTemplate(manualName) ??
        (throw UtcpException("Manual '$manualName' not found."));
    final protocol = tool.toolCallTemplate.callTemplateType;
    final allowed = manualTemplate.effectiveAllowedProtocols;
    if (!allowed.contains(protocol)) {
      throw UtcpSecurityException(
        "Tool '$toolName' uses communication protocol '$protocol' which is "
        "not allowed by manual '$manualName'. Allowed protocols: $allowed",
      );
    }
    final template = await substituteCallTemplateVariables(
      tool.toolCallTemplate,
      manualName,
    );
    _log.fine("Calling tool '$toolName' via '$protocol'.");
    return _PreparedCall(
      this,
      tool,
      manualTemplate,
      template,
      _protocolFor(protocol),
    );
  }

  Future<List<Tool>> searchTools(
    String query, {
    int limit = 10,
    List<String>? anyOfTagsRequired,
  }) => config.toolSearchStrategy.searchTools(
    _repository,
    query,
    limit: limit,
    anyOfTagsRequired: anyOfTagsRequired,
  );

  /// Variable keys a manual call template needs before it can be registered.
  List<String> getRequiredVariablesForManual(CallTemplate manualCallTemplate) =>
      _substitutor.findRequiredVariables(
        manualCallTemplate.toJson(),
        namespace: switch (manualCallTemplate.name) {
          null => null,
          final name => _sanitize(name),
        },
      );

  Future<List<String>> getRequiredVariablesForRegisteredTool(
    String toolName,
  ) async {
    final tool =
        await _repository.getTool(toolName) ??
        (throw UtcpException("Tool '$toolName' not found."));
    return _substitutor.findRequiredVariables(
      tool.toolCallTemplate.toJson(),
      namespace: toolName.split('.').first,
    );
  }

  Future<CallTemplate> substituteCallTemplateVariables(
    CallTemplate template, [
    String? namespace,
  ]) async => _callTemplates.parse(
    await _substitutor.substituteMap(template.toJson(), namespace: namespace),
  );

  CommunicationProtocol _protocolFor(String type) =>
      _protocols[type] ??
      (throw UtcpException(
        "No communication protocol registered for type '$type'.",
      ));

  /// Closes every protocol this client uses.
  Future<void> close() => _closeAll(_protocols.values);

  static final _nonWord = RegExp(r'[^\p{L}\p{N}_]', unicode: true);

  static String _sanitize(String name) => name.replaceAll(_nonWord, '_');

  static String _randomName() {
    final random = Random.secure();
    final hex = List.generate(16, (_) => random.nextInt(16).toRadixString(16));
    return 'manual_${hex.join()}';
  }
}

final class _PreparedCall {
  _PreparedCall(
    this.client,
    this.tool,
    this.manualTemplate,
    this.template,
    this.protocol,
  );

  final UtcpClient client;
  final Tool tool;
  final CallTemplate manualTemplate;
  final CallTemplate template;
  final CommunicationProtocol protocol;

  Object? postProcess(Object? result) {
    for (final processor in client.config.postProcessing) {
      result = processor.postProcess(client, tool, manualTemplate, result);
    }
    return result;
  }
}
