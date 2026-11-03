import 'dart:convert';

import 'package:utcp/utcp.dart';
import 'package:utcp_cli/utcp_cli.dart';
import 'package:utcp_file/utcp_file.dart';
import 'package:utcp_mcp/utcp_mcp.dart';
import 'package:utcp_socket/utcp_socket.dart';
import 'package:utcp_websocket/utcp_websocket.dart';

import 'extract.dart';
import 'fixture.dart';

/// One protocol of every transport package, with its call template types
/// registered in [CallTemplate.registry], so every type in the corpus
/// parses. Close them when done.
List<CommunicationProtocol> registerAllProtocols() {
  final protocols = <CommunicationProtocol>[
    HttpCommunicationProtocol(),
    SseCommunicationProtocol(),
    StreamableHttpCommunicationProtocol(),
    TextCommunicationProtocol(),
    McpCommunicationProtocol(),
    CliCommunicationProtocol(),
    FileCommunicationProtocol(),
    TcpCommunicationProtocol(),
    UdpCommunicationProtocol(),
    WebSocketCommunicationProtocol(),
  ];
  for (final protocol in protocols) {
    for (final MapEntry(key: type, value: parse)
        in protocol.callTemplateTypes.entries) {
      CallTemplate.registry.register(type, parse);
    }
  }
  return protocols;
}

/// Parses [document] as a [kind] and serializes it back.
///
/// Throws what the parser throws.
JsonMap roundTrip(DocumentKind kind, JsonMap document) {
  final JsonMap? json = switch (kind) {
    DocumentKind.clientConfig => UtcpClientConfig.fromJson(document).toJson(),
    DocumentKind.manual => UtcpManual.fromJson(document).toJson(),
    DocumentKind.tool => Tool.fromJson(document).toJson(),
    DocumentKind.callTemplate => CallTemplate.fromJson(document).toJson(),
    DocumentKind.auth => Auth.fromJson(document).toJson(),
    DocumentKind.variableLoader =>
      VariableLoader.registry.parse(document).toJson(),
    DocumentKind.postProcessor => ToolPostProcessor.fromJson(document).toJson(),
    DocumentKind.toolRepository => ToolRepository.fromJson(document).toJson(),
    DocumentKind.toolSearchStrategy => ToolSearchStrategy.fromJson(
      document,
    ).toJson(),
  };
  // Through text, so nested model objects become plain JSON values.
  return asJsonMap(jsonDecode(jsonEncode(json ?? const {})), 'output');
}

/// What Dart did with one document.
class Outcome {
  Outcome._({
    this.error,
    this.crash,
    this.output,
    this.unstable = false,
    this.lost = const [],
  });

  /// Parses, re-serializes and re-parses [document] as a [kind].
  factory Outcome.of(DocumentKind kind, JsonMap document) {
    final JsonMap first;
    try {
      first = roundTrip(kind, document);
    } on FormatException catch (error) {
      return Outcome._(error: error.message);
    } on Exception catch (error) {
      return Outcome._(error: '$error', crash: '${error.runtimeType}');
    } on Error catch (error) {
      return Outcome._(error: '$error', crash: '${error.runtimeType}');
    }
    var unstable = false;
    try {
      unstable = canonicalJson(first) != canonicalJson(roundTrip(kind, first));
    } on FormatException {
      unstable = true;
    }
    return Outcome._(
      output: first,
      unstable: unstable,
      lost: lostPaths(document, first),
    );
  }

  /// The error message when Dart rejected the document.
  final String? error;

  /// The type of what the parser threw when it was not a
  /// `FormatException`, which the parsers must throw for a bad document.
  final String? crash;

  /// The first serialization, when Dart accepted the document.
  final JsonMap? output;

  /// Whether serializing the parsed output again gave a different result.
  final bool unstable;

  /// The paths of the document missing or changed in [output].
  final List<String> lost;

  /// Whether Dart parsed the document.
  bool get accepted => error == null;

  /// One line for reports.
  String get summary => accepted
      ? 'accepts${lost.isEmpty ? '' : ', drops ${lost.join(', ')}'}'
            '${unstable ? ', unstable round trip' : ''}'
      : 'rejects${crash == null ? '' : ' with $crash'}: $error';
}

/// Every way [outcome] misses what [fixture] expects; empty when it meets
/// it.
List<String> problems(Fixture fixture, Outcome outcome) {
  if (outcome.crash != null) {
    return ['the parser threw ${outcome.crash}, not a FormatException'];
  }
  switch (fixture.expect) {
    case Expectation.unreviewed:
      return ['not reviewed (Dart ${outcome.summary})'];
    case Expectation.reject:
      return [
        if (outcome.accepted) 'expected a rejection, but Dart accepts it',
      ];
    case Expectation.accept:
      if (!outcome.accepted) return ['expected acceptance: ${outcome.error}'];
      return [
        if (outcome.unstable) 'round trip is not stable',
        for (final path in outcome.lost)
          if (!fixture.mayDrop.any((pattern) => covers(pattern, path)))
            'drops $path, which may_drop does not allow',
        for (final pattern in fixture.mayDrop)
          if (!outcome.lost.any((path) => covers(pattern, path)))
            'may_drop lists $pattern, but it is kept',
      ];
  }
}

/// Whether may_drop [pattern] covers [path]: each segment equal or `*`,
/// and [path] at or below [pattern].
bool covers(String pattern, String path) {
  final want = pattern.split('.');
  final have = path.split('.');
  if (have.length < want.length) return false;
  for (var i = 0; i < want.length; i++) {
    if (want[i] != '*' && want[i] != have[i]) return false;
  }
  return true;
}

/// The shallowest paths of [input] missing from or changed in [output].
///
/// Array indices are written as `*`. An explicit `null` counts as absent,
/// as every SDK reads it.
List<String> lostPaths(Object? input, Object? output, [String path = '']) {
  String child(String key) => path.isEmpty ? key : '$path.$key';
  final lost = <String>{};
  switch (input) {
    case final Map<String, Object?> map:
      if (output is! Map<String, Object?>) return [path];
      for (final MapEntry(:key, :value) in map.entries) {
        if (value == null) continue;
        if (!output.containsKey(key)) {
          lost.add(child(key));
        } else {
          lost.addAll(lostPaths(value, output[key], child(key)));
        }
      }
    case final List<Object?> list:
      if (output is! List<Object?> || output.length != list.length) {
        return [path];
      }
      for (var i = 0; i < list.length; i++) {
        lost.addAll(lostPaths(list[i], output[i], child('*')));
      }
    default:
      if (input != output) return [path];
  }
  return lost.toList();
}
