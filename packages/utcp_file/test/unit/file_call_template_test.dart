import 'package:test/test.dart';
import 'package:utcp/utcp.dart';
import 'package:utcp_file/utcp_file.dart';

void main() {
  final json = <String, Object?>{
    'name': 'local',
    'call_template_type': 'file',
    'allowed_communication_protocols': ['file', 'http'],
    'file_path': 'manuals/tools.yaml',
    'auth_tools': {
      'auth_type': 'api_key',
      'api_key': 'test-key',
      'var_name': 'Authorization',
      'location': 'header',
    },
  };

  test('a template round-trips through JSON', () {
    final template = FileCallTemplate.fromJson(json);
    expect(template.filePath, 'manuals/tools.yaml');
    expect(template.auth, isNull);
    expect((template.authTools! as ApiKeyAuth).apiKey, 'test-key');
    expect(FileCallTemplate.fromJson(template.toJson()).toJson(), json);
  });

  test('the protocol registers the file type', () {
    final parse = FileCommunicationProtocol().callTemplateTypes['file']!;
    expect(parse(json), isA<FileCallTemplate>());
  });

  test('malformed templates are rejected', () {
    expect(
      () => FileCallTemplate.fromJson({'call_template_type': 'file'}),
      throwsFormatException,
    );
    expect(
      () => FileCallTemplate.fromJson({...json, 'file_path': 1}),
      throwsFormatException,
    );
    expect(
      () => FileCallTemplate.fromJson({
        ...json,
        'auth': {'auth_type': 'basic', 'username': 'u', 'password': 'p'},
      }),
      throwsFormatException,
    );
  });

  test('relative paths resolve against the root directory', () {
    // `..` is left to the OS, which resolves it after following symlinks.
    const template = FileCallTemplate(filePath: 'a/../manual.json');
    expect(
      FileCommunicationProtocol(rootDir: '/srv/tools').resolve(template),
      '/srv/tools/a/../manual.json',
    );
    expect(
      FileCommunicationProtocol(
        rootDir: '/srv/tools',
      ).resolve(const FileCallTemplate(filePath: '/etc/manual.json')),
      '/etc/manual.json',
    );
  }, testOn: 'posix');
}
