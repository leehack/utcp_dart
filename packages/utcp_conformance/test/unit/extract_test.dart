import 'package:test/test.dart';
import 'package:utcp_conformance/utcp_conformance.dart';

void main() {
  group('classify', () {
    test('recognises every document kind', () {
      final cases = <Map<String, Object?>, DocumentKind>{
        {'manual_call_templates': <Object?>[]}: DocumentKind.clientConfig,
        {'post_processing': <Object?>[]}: DocumentKind.clientConfig,
        {'utcp_version': '1.0.1', 'tools': <Object?>[]}: DocumentKind.manual,
        {
          'tools': [
            {'tool_provider': <String, Object?>{}},
          ],
        }: DocumentKind.manual,
        {'name': 't', 'tool_call_template': <String, Object?>{}}:
            DocumentKind.tool,
        {'call_template_type': 'http'}: DocumentKind.callTemplate,
        {'provider_type': 'http'}: DocumentKind.callTemplate,
        {'auth_type': 'basic'}: DocumentKind.auth,
        {'variable_loader_type': 'dotenv'}: DocumentKind.variableLoader,
        {'tool_post_processor_type': 'filter_dict'}: DocumentKind.postProcessor,
        {'tool_repository_type': 'in_memory'}: DocumentKind.toolRepository,
        {'tool_search_strategy_type': 'x'}: DocumentKind.toolSearchStrategy,
      };
      for (final MapEntry(key: json, value: kind) in cases.entries) {
        expect(classify(json), kind, reason: '$json');
      }
    });

    test('ignores other objects', () {
      expect(classify({'tools': <Object?>[]}), isNull);
      expect(classify({'tool_call_template': <String, Object?>{}}), isNull);
      expect(classify({'call_template_type': 1}), isNull);
      expect(classify({'type': 'object'}), isNull);
    });

    test('round-trips kind names', () {
      for (final kind in DocumentKind.values) {
        expect(DocumentKind.parse(kind.wire), kind);
      }
      expect(() => DocumentKind.parse('x'), throwsFormatException);
    });
  });

  group('extractDocuments', () {
    test('reads JSON, Python, TypeScript and YAML blocks in Markdown', () {
      const markdown = '''
# Title

```json
{"call_template_type": "http", "url": "https://a.example"}
```

```bash
echo '{"call_template_type": "cli"}'
```

```python
client = UtcpClient.create(config={"manual_call_templates": []})
```

~~~ts
const auth = { auth_type: 'basic', username: 'u', password: 'p' };
~~~

```yaml
manual_call_templates:
  - call_template_type: text
    content: hi
```
''';
      final found = extractDocuments('docs/a.md', markdown);
      expect(found.map((e) => (e.kind, e.line)), [
        (DocumentKind.callTemplate, 4),
        (DocumentKind.clientConfig, 12),
        (DocumentKind.auth, 16),
        (DocumentKind.clientConfig, 20),
      ]);
    });

    test('reads whole JSON files and code by extension', () {
      expect(
        extractDocuments('m.json', '{"utcp_version": "1", "tools": []}'),
        hasLength(1),
      );
      expect(
        extractDocuments('t.py', 'x = {"auth_type": "basic"}'),
        hasLength(1),
      );
      expect(
        extractDocuments('t.ts', "x = { auth_type: 'basic' }"),
        hasLength(1),
      );
      expect(extractDocuments('t.txt', '{"auth_type": "basic"}'), isEmpty);
    });

    test('skips YAML that does not parse', () {
      expect(extractDocuments('a.md', '```yaml\na: [\n```\n'), isEmpty);
    });
  });
}
