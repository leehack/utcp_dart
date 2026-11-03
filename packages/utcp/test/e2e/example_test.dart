@Tags(['e2e'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the README example discovers and calls a tool end to end', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'example/utcp_example.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Found weather.get_weather'));
    expect(
      result.stdout,
      contains('{city: Seoul, temperature_c: 21, authorized: true}'),
    );
  });
}
