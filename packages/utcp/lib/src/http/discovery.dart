import 'package:logging/logging.dart';

import '../data/utcp_manual.dart';
import '../exceptions.dart';
import '../json.dart';
import 'http_call_template.dart';
import 'http_transport.dart';
import 'security.dart';

/// Fetches the UTCP manual at [template]'s URL with its static headers and
/// auth, as the streaming HTTP transports do. Failures are returned, not
/// thrown.
Future<RegisterManualResult> discoverManual(
  HttpTransport transport,
  HttpRequestTemplate template, {
  required HttpMethod method,
  required Duration timeout,
  required Logger log,
}) async {
  try {
    ensureSecureUrl(template.url, 'manual discovery');
    final request = HttpRequestSpec(
      method,
      Uri.parse(template.url),
      template.headers,
    );
    await transport.authorize(request, template.auth, timeout: timeout);
    final response = await transport.send(
      request,
      context: 'manual discovery',
      timeout: timeout,
    );
    response.ensureSuccess(
      "discovering tools from '${template.name}'",
      maxDetailChars: 200,
    );
    final manual = UtcpManual.fromJson(
      asJsonMap(response.decodeManual(), 'Discovery response'),
    );
    rejectRemoteLoopbackToolUrls(response.url, manual, 'manual discovery');
    return RegisterManualResult(manualCallTemplate: template, manual: manual);
  } on Exception catch (e) {
    log.warning("Discovery from '${template.name}' failed: $e");
    return RegisterManualResult.failure(template, [
      e is UtcpException ? e.message : '$e',
    ]);
  }
}
