import 'package:test/test.dart';
import 'package:utcp_websocket/src/describe.dart';

void main() {
  test('describeUrl drops user info, query and fragment', () {
    expect(
      describeUrl(Uri.parse('wss://user:pw@tools.example.com:8443/ws?t=s#f')),
      'wss://tools.example.com:8443/ws',
    );
    expect(describeUrl(Uri.parse('ws://[::1]/ws')), 'ws://[::1]/ws');
  });

  test('describeUrlString survives URLs that do not parse', () {
    expect(describeUrlString(' wss://h/ws?token=s '), 'wss://h/ws');
    expect(describeUrlString('ws://[::1'), isNot(contains('::1')));
  });
}
