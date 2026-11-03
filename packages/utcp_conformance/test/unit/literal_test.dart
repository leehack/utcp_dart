import 'package:test/test.dart';
import 'package:utcp_conformance/utcp_conformance.dart';

List<Literal> objects(String text, [Syntax syntax = Syntax.js]) =>
    LiteralSource(
      text,
      syntax,
    ).objects((value) => value.containsKey('call_template_type')).toList();

void main() {
  group('JSON and JavaScript', () {
    test('reads JSON with comments, trailing commas and elisions', () {
      final found = objects('''
{
  "call_template_type": "http", // Required
  /* the URL */ "url": "https://x.example",
  "headers": {"a": "b",},
  "tags": [...],
  ...
}''');
      expect(found.single.value, {
        'call_template_type': 'http',
        'url': 'https://x.example',
        'headers': {'a': 'b'},
        'tags': <Object?>[],
      });
      expect(found.single.line, 1);
    });

    test('reads TypeScript keys, casts, numbers and undefined', () {
      final found = objects('''
const t = {
  name: 'a',
  call_template_type: "cli",
  timeout: -1.5e3,
  port: 0x10,
  env_vars: undefined,
  url: `https://x.example`,
} as CliCallTemplate;''');
      expect(found.single.value, {
        'name': 'a',
        'call_template_type': 'cli',
        'timeout': -1500,
        'port': 16,
        'url': 'https://x.example',
      });
    });

    test('keeps code that makes a string as <source>', () {
      final found = objects(r'''
x({ call_template_type: 'http', url: `http://localhost:${port}/a`,
    path: 'a' + b, s: String(n) });''');
      expect(found.single.value, {
        'call_template_type': 'http',
        'url': r'<`http://localhost:${port}/a`>',
        'path': "<'a' + b>",
        's': '<String(n)>',
      });
    });

    test('skips a literal holding code of unknown type', () {
      expect(
        objects("{ call_template_type: 'http', url: serverUrl }"),
        isEmpty,
      );
      expect(objects("{ call_template_type: 'http', url }"), isEmpty);
      expect(objects("{ call_template_type: 'http', ...rest }"), isEmpty);
      expect(objects("{ call_template_type: 'http', [k]: 1 }"), isEmpty);
    });

    test('finds the outermost match and literals inside unreadable ones', () {
      final found = objects('''
it('x', async () => {
  const a = { config: other, inner: { call_template_type: 'mcp' } };
  const b = { call_template_type: 'http', auth: { call_template_type: 'x' } };
});''');
      expect(found.map((l) => l.value['call_template_type']), ['mcp', 'http']);
      expect(found.map((l) => l.line), [2, 3]);
    });

    test('skips unterminated strings and unbalanced braces', () {
      expect(objects("{ call_template_type: 'http"), isEmpty);
      expect(objects("{ call_template_type: 'http', "), isEmpty);
    });
  });

  group('Python', () {
    test('reads literals, implicit concatenation and triple quotes', () {
      final found = objects('''
config = {
    # a comment
    "call_template_type": "text",
    'content': "a" 'b',
    "doc": """x
y""",
    "flag": True, "none": None, "off": False,
    "url": f"http://localhost:{port}",
    "raw": r"\\d",
}''', Syntax.python);
      expect(found.single.value, {
        'call_template_type': 'text',
        'content': 'ab',
        'doc': 'x\ny',
        'flag': true,
        'none': null,
        'off': false,
        'url': '<f"http://localhost:{port}">',
        'raw': r'\d',
      });
    });

    test('treats {...} as an elided object', () {
      final found = objects(
        '{"call_template_type": "mcp", "config": {...}}',
        Syntax.python,
      );
      expect(found.single.value['config'], <String, Object?>{});
    });
  });
}
