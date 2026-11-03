import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/utcp_socket.dart';

/// Answers every request with [respond], without a network.
final class _ScriptedProtocol
    extends SocketCommunicationProtocol<TcpCallTemplate> {
  _ScriptedProtocol(this.respond);

  final List<int> Function(String request) respond;
  final requests = <String>[];

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes =>
      TcpCommunicationProtocol().callTemplateTypes;

  @override
  Future<Uint8List> exchange(TcpCallTemplate template, String request) async {
    requests.add(request);
    return Uint8List.fromList(respond(request));
  }
}

List<int> _json(Object? value) => utf8.encode(jsonEncode(value));

void main() {
  late UtcpClient client;

  setUpAll(() async {
    client = await UtcpClient.create(
      protocols: [TcpCommunicationProtocol(), UdpCommunicationProtocol()],
    );
  });
  tearDownAll(() => client.close());

  const manualTemplate = TcpCallTemplate(
    name: 'calc',
    host: 'localhost',
    port: 9000,
  );
  const remoteTemplate = TcpCallTemplate(
    name: 'calc',
    host: 'tools.example.com',
    port: 9000,
  );

  Future<RegisterManualResult> discover(
    Object? response, {
    TcpCallTemplate template = manualTemplate,
  }) {
    final protocol = _ScriptedProtocol(
      (_) => response is List<int> ? response : _json(response),
    );
    return protocol.registerManual(client, template);
  }

  group('discovery', () {
    test('sends the discovery request and parses the tools', () async {
      final protocol = _ScriptedProtocol(
        (_) => _json({
          'utcp_version': '1.0.1',
          'manual_version': '2.0.0',
          'tools': [
            {
              'name': 'add',
              'tool_call_template': {
                'call_template_type': 'tcp',
                'host': 'localhost',
                'port': 9001,
              },
            },
          ],
        }),
      );
      final result = await protocol.registerManual(client, manualTemplate);
      expect(protocol.requests, ['{"type": "utcp"}']);
      expect(result.success, isTrue, reason: '${result.errors}');
      expect(result.manual.manualVersion, '2.0.0');
      final tool = result.manual.tools.single;
      expect(tool.name, 'add');
      expect((tool.toolCallTemplate as TcpCallTemplate).port, 9001);
    });

    test('tools without a valid template use the manual template', () async {
      final result = await discover({
        'tools': [
          {'name': 'implicit'},
          {
            'name': 'unknown_type',
            'tool_call_template': {'call_template_type': 'carrier_pigeon'},
          },
          {
            'name': 'legacy',
            'tool_provider': {'host': 'localhost', 'port': 9002},
          },
          {
            'name': 'bad_legacy',
            'tool_provider': {
              'call_template_type': 'udp',
              'host': 'x',
              'port': 1,
            },
          },
        ],
      });
      expect(result.success, isTrue, reason: '${result.errors}');
      final byName = {for (final t in result.manual.tools) t.name: t};
      expect(byName.keys, ['implicit', 'unknown_type', 'legacy', 'bad_legacy']);
      expect(
        byName['implicit']!.toolCallTemplate.toJson(),
        manualTemplate.toJson(),
      );
      expect(
        byName['unknown_type']!.toolCallTemplate.toJson(),
        manualTemplate.toJson(),
      );
      expect(
        (byName['legacy']!.toolCallTemplate as TcpCallTemplate).port,
        9002,
      );
      expect(
        byName['bad_legacy']!.toolCallTemplate.toJson(),
        manualTemplate.toJson(),
      );
      expect(byName['legacy']!.toJson().containsKey('tool_provider'), isFalse);
    });

    test('invalid tool definitions are skipped', () async {
      final result = await discover({
        'tools': [
          'not an object',
          {'description': 'no name'},
          {'name': 'ok'},
        ],
      });
      expect(result.success, isTrue);
      expect(result.manual.tools.map((t) => t.name), ['ok']);
    });

    test('a JSON response without tools is an empty manual', () async {
      for (final response in [
        {'hello': 'world'},
        ['a', 'b'],
        'text',
      ]) {
        final result = await discover(response);
        expect(result.success, isTrue, reason: '$response');
        expect(result.manual.tools, isEmpty);
      }
    });

    test('non-JSON, undecodable or failed exchanges are failures', () async {
      expect((await discover(utf8.encode('not json'))).success, isFalse);
      expect((await discover([0xff, 0xfe])).success, isFalse);
      final failing = _ScriptedProtocol(
        (_) => throw const UtcpException('connection refused'),
      );
      final result = await failing.registerManual(client, manualTemplate);
      expect(result.errors, ['connection refused']);
    });

    test('raw-bytes templates still discover JSON manuals', () async {
      final result = await discover(
        {
          'tools': [
            {'name': 'raw'},
          ],
        },
        template: const TcpCallTemplate(
          name: 'calc',
          host: 'localhost',
          port: 9000,
          responseByteFormat: null,
        ),
      );
      expect(result.manual.tools.single.name, 'raw');
    });

    group('a manual from a remote host', () {
      JsonMap toolAt(JsonMap callTemplate) => {
        'tools': [
          {'name': 't', 'tool_call_template': callTemplate},
        ],
      };

      for (final (label, callTemplate) in [
        (
          'tcp',
          {'call_template_type': 'tcp', 'host': '127.0.0.1', 'port': 6379},
        ),
        ('udp', {'call_template_type': 'udp', 'host': 'localhost', 'port': 53}),
        (
          'http',
          {'call_template_type': 'http', 'url': 'http://localhost:8080/x'},
        ),
      ]) {
        test('may not point $label tools at loopback', () async {
          final result = await discover(
            toolAt(callTemplate),
            template: remoteTemplate,
          );
          expect(result.success, isFalse);
          expect(result.errors.single, contains('loopback'));
        });
      }

      test('may point tools at other remote hosts', () async {
        final result = await discover(
          toolAt({'call_template_type': 'tcp', 'host': '10.0.0.1', 'port': 1}),
          template: remoteTemplate,
        );
        expect(result.success, isTrue);
      });

      test('loopback manuals may point tools at loopback', () async {
        final result = await discover(
          toolAt({'call_template_type': 'tcp', 'host': '127.0.0.1', 'port': 1}),
        );
        expect(result.success, isTrue);
      });
    });
  });

  group('callTool', () {
    test('formats the arguments and decodes the response', () async {
      final protocol = _ScriptedProtocol(
        (request) => utf8.encode('got $request'),
      );
      final result = await protocol.callTool(client, 'calc.add', {
        'a': 1,
      }, manualTemplate);
      expect(result, 'got {"a":1}');
    });

    test('returns raw bytes without a response_byte_format', () async {
      final protocol = _ScriptedProtocol((_) => [1, 2, 3]);
      final result = await protocol.callTool(
        client,
        'calc.add',
        const {},
        const TcpCallTemplate(host: 'h', port: 1, responseByteFormat: null),
      );
      expect(
        result,
        isA<Uint8List>().having((b) => b.toList(), 'bytes', [1, 2, 3]),
      );
    });

    test('rejects templates of another type', () async {
      await expectLater(
        _ScriptedProtocol((_) => []).callTool(
          client,
          't',
          const {},
          const UdpCallTemplate(host: 'h', port: 1),
        ),
        throwsArgumentError,
      );
    });
  });
}
