import 'data/call_template.dart';
import 'data/tool.dart';
import 'data/utcp_manual.dart';
import 'json.dart';
import 'registry.dart';

/// Storage for registered manuals and their tools.
abstract interface class ToolRepository {
  /// Parsers selected by `tool_repository_type`. Plugins add their own
  /// with [TypeRegistry.register].
  static final registry = TypeRegistry<ToolRepository>('tool_repository_type', {
    InMemoryToolRepository.type: (_) => InMemoryToolRepository(),
  });

  /// Parses [json] with [registry]; `tool_repository_type` defaults to
  /// `in_memory`.
  static ToolRepository fromJson(JsonMap json) => registry.parse({
    registry.discriminator: InMemoryToolRepository.type,
    ...json,
  });

  Future<void> saveManual(CallTemplate manualCallTemplate, UtcpManual manual);

  /// Returns `false` when no manual named [manualName] was stored.
  Future<bool> removeManual(String manualName);

  /// Removes one tool, from its manual too. Returns `false` when no tool
  /// named [toolName] was stored.
  Future<bool> removeTool(String toolName);

  Future<Tool?> getTool(String toolName);
  Future<List<Tool>> getTools();
  Future<List<Tool>?> getToolsByManual(String manualName);
  Future<UtcpManual?> getManual(String manualName);
  Future<List<UtcpManual>> getManuals();
  Future<CallTemplate?> getManualCallTemplate(String manualName);
  Future<List<CallTemplate>> getManualCallTemplates();

  /// The JSON form, with `tool_repository_type`, that [registry] parses
  /// back into an equivalent, empty repository.
  JsonMap toJson();
}

class InMemoryToolRepository implements ToolRepository {
  /// The `tool_repository_type` of this repository.
  static const type = 'in_memory';

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
  Future<bool> removeTool(String toolName) async {
    if (_tools.remove(toolName) == null) return false;
    for (final MapEntry(key: name, value: manual)
        in _manuals.entries.toList()) {
      if (manual.tools.any((tool) => tool.name == toolName)) {
        _manuals[name] = UtcpManual(
          utcpVersion: manual.utcpVersion,
          manualVersion: manual.manualVersion,
          tools: [
            for (final tool in manual.tools)
              if (tool.name != toolName) tool,
          ],
        );
      }
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

  @override
  JsonMap toJson() => {'tool_repository_type': type};
}
