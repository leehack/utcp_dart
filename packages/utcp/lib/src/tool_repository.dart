import 'data/call_template.dart';
import 'data/tool.dart';
import 'data/utcp_manual.dart';

/// Storage for registered manuals and their tools.
abstract interface class ToolRepository {
  Future<void> saveManual(CallTemplate manualCallTemplate, UtcpManual manual);

  /// Returns `false` when no manual named [manualName] was stored.
  Future<bool> removeManual(String manualName);

  Future<Tool?> getTool(String toolName);
  Future<List<Tool>> getTools();
  Future<List<Tool>?> getToolsByManual(String manualName);
  Future<UtcpManual?> getManual(String manualName);
  Future<List<UtcpManual>> getManuals();
  Future<CallTemplate?> getManualCallTemplate(String manualName);
  Future<List<CallTemplate>> getManualCallTemplates();
}

class InMemoryToolRepository implements ToolRepository {
  final _manuals = <String, UtcpManual>{};
  final _callTemplates = <String, CallTemplate>{};
  final _tools = <String, Tool>{};

  @override
  Future<void> saveManual(
    CallTemplate manualCallTemplate,
    UtcpManual manual,
  ) async {
    final name = manualCallTemplate.name;
    if (name == null) {
      throw ArgumentError('The manual call template must have a name.');
    }
    await removeManual(name);
    _manuals[name] = manual;
    _callTemplates[name] = manualCallTemplate;
    for (final tool in manual.tools) {
      _tools[tool.name] = tool;
    }
  }

  @override
  Future<bool> removeManual(String manualName) async {
    final manual = _manuals.remove(manualName);
    _callTemplates.remove(manualName);
    if (manual == null) return false;
    for (final tool in manual.tools) {
      _tools.remove(tool.name);
    }
    return true;
  }

  @override
  Future<Tool?> getTool(String toolName) async => _tools[toolName];

  @override
  Future<List<Tool>> getTools() async => List.unmodifiable(_tools.values);

  @override
  Future<List<Tool>?> getToolsByManual(String manualName) async =>
      _manuals[manualName]?.tools;

  @override
  Future<UtcpManual?> getManual(String manualName) async =>
      _manuals[manualName];

  @override
  Future<List<UtcpManual>> getManuals() async =>
      List.unmodifiable(_manuals.values);

  @override
  Future<CallTemplate?> getManualCallTemplate(String manualName) async =>
      _callTemplates[manualName];

  @override
  Future<List<CallTemplate>> getManualCallTemplates() async =>
      List.unmodifiable(_callTemplates.values);
}
