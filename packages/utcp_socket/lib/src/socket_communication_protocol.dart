import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:utcp/utcp.dart';

import 'message.dart';
import 'socket_call_template.dart';

final _log = Logger('utcp.socket');

/// Discovery and tool calls shared by the `tcp` and `udp` transports, which
/// differ only in how one request and its response travel ([exchange]).
///
/// Discovery sends `{"type": "utcp"}` and expects a JSON object with a
/// `tools` array. A tool without a valid `tool_call_template` (or legacy
/// `tool_provider`) is called through the manual's own template; an invalid
/// tool is skipped. A manual discovered from a non-loopback host may not
/// point tools at loopback.
abstract class SocketCommunicationProtocol<T extends SocketCallTemplate>
    extends CommunicationProtocol {
  /// Sends [request] to [template]'s endpoint and returns the raw response.
  /// Throws a [UtcpException] on network failures and timeouts.
  Future<Uint8List> exchange(T template, String request);

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<T>(manualCallTemplate);
    try {
      final bytes = await exchange(template, discoveryMessage);
      final decoded = decodeResponse(bytes, template.responseByteFormat);
      final document = jsonDecode(
        decoded is String ? decoded : utf8.decode(bytes),
      );
      final manual = _manualFrom(document, template);
      _rejectRemoteLoopbackTools(template, manual);
      _log.info(
        "Discovered ${manual.tools.length} tools from '${template.name}'.",
      );
      return RegisterManualResult(manualCallTemplate: template, manual: manual);
    } on Exception catch (e) {
      _log.warning("Discovery from '${template.name}' failed: $e");
      return RegisterManualResult.failure(template, [
        e is UtcpException ? e.message : '$e',
      ]);
    }
  }

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async {
    final template = requireCallTemplate<T>(toolCallTemplate);
    final bytes = await exchange(template, formatRequest(arguments, template));
    return decodeResponse(bytes, template.responseByteFormat);
  }

  UtcpManual _manualFrom(Object? document, T template) {
    if (document is! Map<Object?, Object?> || document['tools'] == null) {
      _log.info("No tools found in the response from '${template.name}'.");
      return const UtcpManual(tools: []);
    }
    final json = asJsonMap(document, 'Discovery response');
    final tools = <Tool>[];
    for (final (i, item) in json.list('tools').indexed) {
      try {
        tools.add(_toolFrom(asJsonMap(item, "Field 'tools[$i]'"), template));
      } on FormatException catch (e) {
        _log.warning("Skipping invalid tool in '${template.name}': $e");
      }
    }
    return UtcpManual(
      utcpVersion: json.optString('utcp_version') ?? utcpProtocolVersion,
      manualVersion: json.optString('manual_version') ?? '1.0.0',
      tools: tools,
    );
  }

  Tool _toolFrom(JsonMap tool, T manual) => Tool.fromJson({
    for (final MapEntry(:key, :value) in tool.entries)
      if (key != 'tool_provider') key: value,
    'tool_call_template': _toolTemplate(tool, manual).toJson(),
  });

  CallTemplate _toolTemplate(JsonMap tool, T manual) {
    final explicit = tool['tool_call_template'];
    final legacy = tool['tool_provider'];
    try {
      if (explicit != null) {
        return CallTemplate.fromJson(
          asJsonMap(explicit, "Field 'tool_call_template'"),
        );
      }
      if (legacy != null) {
        final parsed = CallTemplate.fromJson({
          'call_template_type': manual.callTemplateType,
          ...asJsonMap(legacy, "Field 'tool_provider'"),
        });
        if (parsed is T) return parsed;
        throw FormatException(
          "tool_provider is a '${parsed.callTemplateType}' template.",
        );
      }
    } on FormatException catch (e) {
      _log.warning(
        "Tool '${tool['name']}' in '${manual.name}' has an invalid call "
        "template; using the manual's own: $e",
      );
    }
    return manual;
  }

  static void _rejectRemoteLoopbackTools(
    SocketCallTemplate source,
    UtcpManual manual,
  ) {
    if (isLoopbackHost(source.host)) return;
    rejectRemoteLoopbackToolUrls(
      Uri(scheme: source.callTemplateType, host: source.host),
      manual,
      'manual discovery',
    );
    for (final tool in manual.tools) {
      final template = tool.toolCallTemplate;
      if (template is SocketCallTemplate && isLoopbackHost(template.host)) {
        throw UtcpSecurityException(
          'Security error during manual discovery: a manual fetched from '
          '"${source.host}" declares a loopback host ("${template.host}") for '
          'tool "${tool.name}".',
        );
      }
    }
  }
}
