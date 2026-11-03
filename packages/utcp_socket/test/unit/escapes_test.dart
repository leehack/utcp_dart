import 'package:test/test.dart';
import 'package:utcp_socket/src/escapes.dart';

void main() {
  test('interprets the escapes of Python unicode_escape', () {
    expect(interpretEscapes(r'\n'), '\n');
    expect(interpretEscapes(r'\r\n'), '\r\n');
    expect(interpretEscapes(r'\t\v\f\b\a'), '\t\v\f\b\x07');
    expect(interpretEscapes(r'\\'), r'\');
    expect(
      interpretEscapes(
        r"\'"
        r'\"',
      ),
      '\'"',
    );
    expect(interpretEscapes(r'\x00'), '\x00');
    expect(interpretEscapes(r'\x7F'), '\x7f');
    expect(interpretEscapes(r'\0'), '\x00');
    expect(interpretEscapes(r'\101\1012'), 'AA2');
    expect(interpretEscapes(r'\u00e9'), 'é');
    expect(interpretEscapes(r'\U0001F600'), '😀');
    expect(interpretEscapes('a\\\nb'), 'ab');
  });

  test('keeps plain text and unknown escapes as written', () {
    expect(interpretEscapes('END'), 'END');
    expect(interpretEscapes('é|'), 'é|');
    expect(interpretEscapes(r'\q'), r'\q');
  });

  test('rejects truncated escapes', () {
    for (final input in [
      r'\',
      r'end\',
      r'\x0',
      r'\xZZ',
      r'\u12',
      r'\U00110000',
    ]) {
      expect(
        () => interpretEscapes(input),
        throwsFormatException,
        reason: input,
      );
    }
    expect(() => interpretEscapes(r'\N{BULLET}'), throwsFormatException);
  });
}
