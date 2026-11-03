import 'package:test/test.dart';
import 'package:utcp_socket/src/python_str.dart';

void main() {
  // Expected values are Python 3's str() of the same values.
  test('scalars', () {
    expect(pythonStr('raw text'), 'raw text');
    expect(pythonStr(null), 'None');
    expect(pythonStr(true), 'True');
    expect(pythonStr(false), 'False');
    expect(pythonStr(0), '0');
    expect(pythonStr(-7), '-7');
  });

  test('floats use the shortest repr and switch to exponents like Python', () {
    for (final (value, expected) in [
      (1.0, '1.0'),
      (-0.0, '-0.0'),
      (0.5, '0.5'),
      (1.5e-7, '1.5e-07'),
      (0.0001, '0.0001'),
      (2.5e-5, '2.5e-05'),
      (1e15, '1000000000000000.0'),
      (1e16, '1e+16'),
      (1e100, '1e+100'),
      (123.456, '123.456'),
      (double.infinity, 'inf'),
      (double.negativeInfinity, '-inf'),
      (double.nan, 'nan'),
    ]) {
      expect(pythonStr(value), expected, reason: '$value');
    }
  });

  test('lists and maps use repr for their items', () {
    expect(pythonStr(<Object?>[]), '[]');
    expect(pythonStr(<String, Object?>{}), '{}');
    expect(
      pythonStr([
        'a',
        1,
        null,
        true,
        [2.0],
      ]),
      "['a', 1, None, True, [2.0]]",
    );
    expect(
      pythonStr({
        'k': null,
        'n': {'x': 'y'},
      }),
      "{'k': None, 'n': {'x': 'y'}}",
    );
  });

  test('strings in containers are quoted and escaped like repr', () {
    expect(pythonStr(["it's"]), '["it\'s"]');
    expect(pythonStr(['say "hi" it\'s']), r"""['say "hi" it\'s']""");
    expect(
      pythonStr(['tab\tnl\ncr\r\\ \x00\x7f\x85\xa0\xad é 😀 \u2028\ufeff']),
      r"['tab\tnl\ncr\r\\ \x00\x7f\x85\xa0\xad é 😀 \u2028\ufeff']",
    );
  });
}
