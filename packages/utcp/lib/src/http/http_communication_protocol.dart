import 'package:logging/logging.dart';

import '../client.dart';
import '../communication_protocol.dart';
import '../data/call_template.dart';
import '../data/tool.dart';
import '../data/utcp_manual.dart';
import '../exceptions.dart';
import '../json.dart';
import '../registry.dart';
import 'http_call_template.dart';
import 'http_transport.dart';
import 'openapi_converter.dart';
import 'security.dart';

final _log = Logger('utcp.http');

/// The `http` transport: one request per tool call.
class HttpCommunicationProtocol extends CommunicationProtocol {
  /// When [transport] is given, the caller keeps ownership of it.
  HttpCommunicationProtocol({
    HttpTransport? transport,
    this.discoveryTimeout = const Duration(seconds: 10),
    this.timeout = const Duration(seconds: 30),
  }) : _transport = transport ?? HttpTransport(),
       _ownsTransport = transport == null;

  final HttpTransport _transport;
  final bool _ownsTransport;

  /// Limit for manual discovery, including reading the response body.
  final Duration discoveryTimeout;

  /// Limit for tool calls and token requests, including reading the
  /// response body.
  final Duration timeout;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    HttpCallTemplate.type: HttpCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<HttpCallTemplate>(manualCallTemplate);
    try {
      ensureSecureUrl(template.url, 'manual discovery');
      final request = HttpRequestSpec(
        template.httpMethod,
        Uri.parse(template.url),
        template.headers,
      );
      await _transport.authorize(request, template.auth, timeout: timeout);
      final response = await _transport.send(
        request,
        context: 'manual discovery',
        timeout: discoveryTimeout,
      );
      response.ensureSuccess(
        "discovering tools from '${template.name}'",
        maxDetailChars: 200,
      );
      final document = asJsonMap(response.decodeManual(), 'Discovery response');
      return RegisterManualResult(
        manualCallTemplate: template,
        manual: _manualFrom(document, response.url, template),
      );
    } on Exception catch (e) {
      _log.warning("Discovery from '${template.name}' failed: $e");
      return RegisterManualResult.failure(template, [
        e is UtcpException ? e.message : '$e',
      ]);
    }
  }

  /// [source] is the URL after redirects: it decides whether the document
  /// is local or remote, and relative OpenAPI URLs resolve against it.
  UtcpManual _manualFrom(
    JsonMap document,
    Uri source,
    HttpCallTemplate template,
  ) {
    final UtcpManual manual;
    if (UtcpManual.isManual(document)) {
      manual = UtcpManual.fromJson(document);
    } else if (OpenApiConverter.isOpenApi(document)) {
      // A spec served from another origin than the configured URL (after a
      // redirect) could name its own servers; the manual's credentials were
      // meant for the configured origin, so they are not given to its tools.
      final sameOrigin = _sameOrigin(source, Uri.parse(template.url));
      if (!sameOrigin &&
          (template.authTools != null || template.headers.isNotEmpty)) {
        _log.warning(
          "OpenAPI spec for '${template.name}' was served from another "
          'origin; its tools get no auth_tools or headers.',
        );
      }
      manual = OpenApiConverter(
        document,
        specUrl: source,
        callTemplateName: template.name,
        authTools: sameOrigin ? template.authTools : null,
        headers: sameOrigin ? template.headers : const {},
      ).convert();
    } else {
      throw const FormatException(
        'Response is neither a UTCP manual nor an OpenAPI specification.',
      );
    }
    rejectRemoteLoopbackToolUrls(source, manual, 'manual discovery');
    return manual;
  }

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async {
    final template = requireCallTemplate<HttpCallTemplate>(toolCallTemplate);
    final request = buildToolRequest(template, arguments);
    await _transport.authorize(request, template.auth, timeout: timeout);
    final response = await _transport.send(
      request,
      context: 'tool invocation',
      timeout: timeout,
    );
    response.ensureSuccess("calling tool '$toolName'");
    return response.decode();
  }

  @override
  Future<void> close() async {
    if (_ownsTransport) _transport.close();
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;
}
