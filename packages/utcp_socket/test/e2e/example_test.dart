@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the example discovers and calls TCP and UDP tools', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'example/utcp_socket_example.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('calc.add: {"sum":5}'));
    expect(result.stdout, contains('shout.shout: HELLO'));
  });
}
