import '../client.dart';
import '../data/call_template.dart';
import '../data/tool.dart';
import '../json.dart';
import '../registry.dart';
import 'filter_dict_post_processor.dart';
import 'limit_strings_post_processor.dart';

/// Transforms tool results. The client runs the processors in
/// `UtcpClientConfig.postProcessing` in order on every `callTool` result and
/// on every `callToolStreaming` chunk.
abstract class ToolPostProcessor {
  const ToolPostProcessor();

  /// Parsers selected by `tool_post_processor_type`. Plugins add their own
  /// with [TypeRegistry.register].
  static final registry =
      TypeRegistry<ToolPostProcessor>('tool_post_processor_type', {
        FilterDictPostProcessor.type: FilterDictPostProcessor.fromJson,
        LimitStringsPostProcessor.type: LimitStringsPostProcessor.fromJson,
      });

  static ToolPostProcessor fromJson(JsonMap json) => registry.parse(json);

  String get toolPostProcessorType;

  /// Returns the processed [result] of [tool], which belongs to the manual
  /// registered with [manualCallTemplate].
  Object? postProcess(
    UtcpClient caller,
    Tool tool,
    CallTemplate manualCallTemplate,
    Object? result,
  );

  /// Serializes the processor-specific fields. [toJson] adds the type.
  JsonMap fieldsToJson();

  JsonMap toJson() => {
    'tool_post_processor_type': toolPostProcessorType,
    ...fieldsToJson(),
  };
}

/// A [ToolPostProcessor] that can be limited to some tools or manuals.
///
/// A result is processed only when its tool is not in [excludeTools], is in
/// [onlyIncludeTools] when that is set, and likewise for the manual name.
/// Tool names are the full `manual_name.tool_name`. An empty list counts as
/// unset.
abstract class ScopedToolPostProcessor extends ToolPostProcessor {
  const ScopedToolPostProcessor({
    this.excludeTools,
    this.onlyIncludeTools,
    this.excludeManuals,
    this.onlyIncludeManuals,
  });

  final List<String>? excludeTools;
  final List<String>? onlyIncludeTools;
  final List<String>? excludeManuals;
  final List<String>? onlyIncludeManuals;

  /// Processes a result this processor applies to.
  Object? process(Object? result);

  @override
  Object? postProcess(
    UtcpClient caller,
    Tool tool,
    CallTemplate manualCallTemplate,
    Object? result,
  ) =>
      _inScope(tool.name, excludeTools, onlyIncludeTools) &&
          _inScope(manualCallTemplate.name, excludeManuals, onlyIncludeManuals)
      ? process(result)
      : result;

  static bool _inScope(
    String? name,
    List<String>? exclude,
    List<String>? onlyInclude,
  ) =>
      !(exclude?.contains(name) ?? false) &&
      (onlyInclude == null ||
          onlyInclude.isEmpty ||
          onlyInclude.contains(name));

  /// The scope fields, for [fieldsToJson].
  JsonMap scopeToJson() => {
    'exclude_tools': ?excludeTools,
    'only_include_tools': ?onlyIncludeTools,
    'exclude_manuals': ?excludeManuals,
    'only_include_manuals': ?onlyIncludeManuals,
  };
}
