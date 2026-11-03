import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_socket/utcp_socket.dart';

void main() {
  group('TcpCallTemplate', () {
    test('defaults match the Python reference', () {
      final t = TcpCallTemplate.fromJson({
        'call_template_type': 'tcp',
        'host': 'localhost',
        'port': 9000,
      });
      expect(t.requestDataFormat, RequestDataFormat.json);
      expect(t.requestDataTemplate, isNull);
      expect(t.responseByteFormat, 'utf-8');
      expect(t.framingStrategy, TcpFramingStrategy.stream);
      expect(t.lengthPrefixBytes, 4);
      expect(t.lengthPrefixEndian, LengthPrefixEndian.big);
      expect(t.messageDelimiter, '\x00');
      expect(t.interpretEscapeSequences, isTrue);
      expect(t.fixedMessageLength, isNull);
      expect(t.maxResponseSize, 65536);
      expect(t.timeout, const Duration(seconds: 30));
      expect(t.auth, isNull);
    });

    test('round-trips through toJson and the registry', () {
      final json = {
        'name': 'calc',
        'call_template_type': 'tcp',
        'host': '10.0.0.5',
        'port': 7000,
        'request_data_format': 'text',
        'request_data_template': 'ADD UTCP_ARG_a_UTCP_ARG',
        'response_byte_format': null,
        'framing_strategy': 'length_prefix',
        'length_prefix_bytes': 2,
        'length_prefix_endian': 'little',
        'message_delimiter': r'\r\n',
        'interpret_escape_sequences': false,
        'fixed_message_length': 12,
        'max_response_size': 1024,
        'timeout': 1500,
        'allowed_communication_protocols': ['tcp', 'udp'],
      };
      final t = TcpCallTemplate.fromJson(json);
      expect(t.toJson(), json);
      final registry = TcpCommunicationProtocol().callTemplateTypes;
      expect(registry[TcpCallTemplate.type]!(t.toJson()).toJson(), json);
    });

    test('Python encoding names parse for tcp and udp', () {
      for (final format in ['latin-1', 'utf-16', 'cp1252', 'UTF_8']) {
        for (final parse in [
          TcpCallTemplate.fromJson,
          UdpCallTemplate.fromJson,
        ]) {
          final t = parse({
            'host': 'h',
            'port': 1,
            'response_byte_format': format,
          });
          expect(t.responseByteFormat, format);
          expect(t.toJson(), containsPair('response_byte_format', format));
        }
      }
    });

    test('an explicit null response_byte_format selects raw bytes', () {
      final t = TcpCallTemplate.fromJson({
        'call_template_type': 'tcp',
        'host': 'h',
        'port': 1,
        'response_byte_format': null,
      });
      expect(t.responseByteFormat, isNull);
      expect(t.toJson(), containsPair('response_byte_format', null));
    });

    test('delimiter escapes are interpreted unless disabled', () {
      TcpCallTemplate tcp(String delimiter, {bool interpret = true}) =>
          TcpCallTemplate(
            host: 'h',
            port: 1,
            messageDelimiter: delimiter,
            interpretEscapeSequences: interpret,
          );
      expect(tcp(r'\r\n').delimiterBytes, [13, 10]);
      expect(tcp(r'\x00').delimiterBytes, [0]);
      expect(tcp(r'\N{RECORD SEPARATOR}').delimiterBytes, [0x1e]);
      expect(tcp(r'\r\n', interpret: false).delimiterBytes, [92, 114, 92, 110]);
      expect(tcp('').delimiterBytes, [0], reason: 'empty means NUL');
      expect(tcp('\n').delimiterBytes, [10]);
    });

    for (final (field, value, message) in [
      ('port', 0, 'port'),
      ('port', 70000, 'port'),
      ('port', '80', 'port'),
      ('framing_strategy', 'lines', 'framing_strategy'),
      ('length_prefix_bytes', 3, 'length_prefix_bytes'),
      ('length_prefix_endian', 'middle', 'length_prefix_endian'),
      ('request_data_format', 'xml', 'request_data_format'),
      ('timeout', -1, 'timeout'),
      ('max_response_size', 0, 'max_response_size'),
      ('response_byte_format', 'klingon', "response_byte_format 'klingon'"),
      ('message_delimiter', r'\x0', 'escape'),
      ('message_delimiter', r'\N{SNOWMAN}', 'SNOWMAN'),
      ('auth', {'auth_type': 'basic'}, 'auth'),
    ]) {
      test('rejects $field = $value', () {
        expect(
          () => TcpCallTemplate.fromJson({
            'call_template_type': 'tcp',
            'host': 'h',
            'port': 1,
            field: value,
          }),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
      });
    }

    test('fixed_length framing requires fixed_message_length', () {
      expect(
        () => TcpCallTemplate.fromJson({
          'call_template_type': 'tcp',
          'host': 'h',
          'port': 1,
          'framing_strategy': 'fixed_length',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires host and port', () {
      expect(
        () => TcpCallTemplate.fromJson({'port': 1}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => TcpCallTemplate.fromJson({'host': 'h'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('UdpCallTemplate', () {
    test('defaults and round-trip', () {
      final t = UdpCallTemplate.fromJson({
        'call_template_type': 'udp',
        'host': 'localhost',
        'port': 9000,
      });
      expect(t.numberOfResponseDatagrams, 1);
      expect(t.responseByteFormat, 'utf-8');
      expect(t.timeout, const Duration(seconds: 30));

      final json = {
        'name': 'sensor',
        'call_template_type': 'udp',
        'host': '::1',
        'port': 5353,
        'request_data_format': 'text',
        'request_data_template': 'READ UTCP_ARG_id_UTCP_ARG',
        'response_byte_format': 'ascii',
        'timeout': 250,
        'number_of_response_datagrams': 0,
      };
      expect(UdpCallTemplate.fromJson(json).toJson(), json);
    });

    test('rejects negative datagram counts and auth', () {
      for (final extra in [
        {'number_of_response_datagrams': -1},
        {
          'auth': {'auth_type': 'api_key', 'api_key': 'k'},
        },
      ]) {
        expect(
          () => UdpCallTemplate.fromJson({'host': 'h', 'port': 1, ...extra}),
          throwsA(isA<FormatException>()),
          reason: '$extra',
        );
      }
    });
  });

  test('both protocols list their template type', () async {
    expect(TcpCommunicationProtocol().callTemplateTypes.keys, ['tcp']);
    expect(UdpCommunicationProtocol().callTemplateTypes.keys, ['udp']);
    final client = await UtcpClient.create();
    addTearDown(client.close);
    await expectLater(
      UdpCommunicationProtocol().callTool(
        client,
        't',
        const {},
        const HttpCallTemplate(url: 'https://x'),
      ),
      throwsArgumentError,
    );
  });

  group('endpoints', () {
    test('name the address for the remote-loopback rule', () {
      expect(const TcpCallTemplate(host: 'db.local', port: 6379).endpoints, [
        'tcp://db.local:6379',
      ]);
      expect(const UdpCallTemplate(host: '::1', port: 53).endpoints, [
        'udp://[::1]:53',
      ]);
    });

    for (final (type, protocol) in [
      ('tcp', TcpCommunicationProtocol()),
      ('udp', UdpCommunicationProtocol()),
    ]) {
      test('keep loopback $type tools out of a remote HTTP manual', () async {
        for (final host in ['127.0.0.1', 'localhost', '::1', '0x7f000001']) {
          final client = await UtcpClient.create(
            protocols: [
              HttpCommunicationProtocol(
                transport: HttpTransport(
                  client: MockClient(
                    (_) async => http.Response(
                      jsonEncode({
                        'utcp_version': '1.0.1',
                        'manual_version': '1.0.0',
                        'tools': [
                          {
                            'name': 'redis',
                            'tool_call_template': {
                              'call_template_type': type,
                              'host': host,
                              'port': 6379,
                            },
                          },
                        ],
                      }),
                      200,
                      headers: {'content-type': 'application/json'},
                    ),
                  ),
                ),
              ),
              protocol,
            ],
          );
          addTearDown(client.close);
          final result = await client.registerManual(
            CallTemplate.fromJson({
              'name': 'evil',
              'call_template_type': 'http',
              'url': 'https://evil.example/utcp',
              'http_method': 'GET',
              'allowed_communication_protocols': ['http', type],
            }),
          );
          expect(result.success, isFalse, reason: host);
          expect(result.errors.single, contains('loopback'));
          expect(await client.searchTools(''), isEmpty);
        }
      });
    }
  });
}
