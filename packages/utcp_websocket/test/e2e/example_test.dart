@Tags(['e2e'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the example discovers and calls a WebSocket tool', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'example/utcp_websocket_example.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Found greeter.greet'));
    expect(
      result.stdout,
      contains('{greeting: Hello, Seoul!, authorized: true}'),
    );
  });
}
