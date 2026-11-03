import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

import '../tool/src/interop.dart';

JsonMap input(List<JsonMap> documents) => {
  'sdk': 'python',
  'documents': documents,
};

void main() {
  setUpAll(registerAllTransports);

  test('re-serializes call templates of every transport package', () {
    final templates = <JsonMap>[
      {
        'call_template_type': 'cli',
        'commands': [
          {'command': 'echo hi'},
        ],
      },
      {'call_template_type': 'file', 'file_path': 'tools.json'},
      {
        'call_template_type': 'mcp',
        'config': {
          'mcpServers': {
            'fs': {'command': 'node'},
          },
        },
      },
      {'call_template_type': 'tcp', 'host': 'example.com', 'port': 1},
      {'call_template_type': 'udp', 'host': 'example.com', 'port': 1},
      {'call_template_type': 'websocket', 'url': 'wss://example.com'},
    ];
    final output = roundTripDocuments(
      input([
        for (final (i, json) in templates.indexed)
          {'id': '$i', 'kind': 'call_template', 'json': json},
      ]),
    );

    expect(output['source'], 'python');
    final documents = output.objectList('documents');
    expect(documents.where((d) => d.containsKey('error')), isEmpty);
    expect(
      [for (final d in documents) d.object('json')['call_template_type']],
      [for (final t in templates) t['call_template_type']],
    );
  });

  test('re-serializes manuals and configs with a dotenv loader', () {
    final output = roundTripDocuments(
      input([
        {
          'id': 'manual',
          'kind': 'manual',
          'json': {'utcp_version': '1.1.0', 'tools': <Object?>[]},
        },
        {
          'id': 'config',
          'kind': 'config',
          'json': {
            'load_variables_from': [
              {'variable_loader_type': 'dotenv', 'env_file_path': '.env'},
            ],
          },
        },
      ]),
    );

    final [manual, config] = output.objectList('documents');
    expect(manual.object('json')['utcp_version'], '1.1.0');
    expect(config.object('json')['load_variables_from'], [
      {'variable_loader_type': 'dotenv', 'env_file_path': '.env'},
    ]);
  });

  test('reports a rejected document and keeps going', () {
    final output = roundTripDocuments(
      input([
        {
          'id': 'bad',
          'kind': 'call_template',
          'json': {'call_template_type': 'graphql', 'url': 'https://x'},
        },
        {
          'id': 'good',
          'kind': 'call_template',
          'json': {'call_template_type': 'http', 'url': 'https://x'},
        },
      ]),
    );

    final [bad, good] = output.objectList('documents');
    expect(bad, isNot(contains('json')));
    expect(bad['error'], contains("Unknown call_template_type 'graphql'"));
    expect(good, contains('json'));
  });

  test('rejects an unknown document kind', () {
    expect(
      () => roundTripDocuments(
        input([
          {'id': 'x', 'kind': 'tool', 'json': <String, Object?>{}},
        ]),
      ),
      throwsFormatException,
    );
  });
}
