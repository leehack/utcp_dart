import 'client.dart';
import 'data/call_template.dart';
import 'data/tool.dart';
import 'data/utcp_manual.dart';
import 'registry.dart';

/// A transport that discovers manuals and calls tools for the call template
/// types in [callTemplateTypes].
abstract class CommunicationProtocol {
  /// The call template types this protocol serves, with their parsers.
  /// A `UtcpClient` created with this protocol parses those types with them.
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes;

  /// Fetches the manual described by [manualCallTemplate]. Discovery
  /// failures are reported in the result rather than thrown.
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  );

  Future<void> deregisterManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {}

  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  );

  /// Yields result chunks. Protocols without native streaming yield the
  /// whole [callTool] result once.
  Stream<Object?> callToolStreaming(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) async* {
    yield await callTool(caller, toolName, arguments, toolCallTemplate);
  }

  Future<void> close() async {}
}

/// Returns [template] as a [T], or throws an [ArgumentError] when a protocol
/// is handed a call template of another type.
T requireCallTemplate<T extends CallTemplate>(CallTemplate template) =>
    template is T
    ? template
    : throw ArgumentError.value(
        template.callTemplateType,
        'call_template_type',
        'Expected a $T',
      );
