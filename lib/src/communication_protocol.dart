import 'client.dart';
import 'data/call_template.dart';
import 'data/utcp_manual.dart';

/// A transport that can discover manuals and call tools for one or more
/// `call_template_type` values.
abstract class CommunicationProtocol {
  /// Fetches the manual described by [manualCallTemplate]. Discovery failures
  /// are reported in the result rather than thrown.
  Future<RegisterManualResult> registerManual(UtcpClient caller, CallTemplate manualCallTemplate);

  Future<void> deregisterManual(UtcpClient caller, CallTemplate manualCallTemplate);

  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    Map<String, dynamic> toolArgs,
    CallTemplate toolCallTemplate,
  );

  Stream<Object?> callToolStreaming(
    UtcpClient caller,
    String toolName,
    Map<String, dynamic> toolArgs,
    CallTemplate toolCallTemplate,
  );

  Future<void> close() async {}
}
