import 'package:test/test.dart';
import 'package:utcp/utcp.dart';

void main() {
  test('namespaced lookup doubles underscores in the manual name', () async {
    const s = VariableSubstitutor(
      variables: {'my__api_TOKEN': 't0k'},
      environment: {},
    );
    expect(
      await s.substitute(r'Bearer ${TOKEN}', namespace: 'my_api'),
      'Bearer t0k',
    );
    expect(
      s.findRequiredVariables({
        'a': r'$TOKEN',
        'b': [r'${X}'],
      }, namespace: 'my_api'),
      ['my__api_TOKEN', 'my__api_X'],
    );
  });

  test(r'strings containing $ref are left untouched', () async {
    const s = VariableSubstitutor(environment: {});
    expect(await s.substitute(r'#/$ref/${NOPE}'), r'#/$ref/${NOPE}');
  });

  test('precedence is config, then loaders, then environment', () async {
    final s = VariableSubstitutor(
      variables: const {'A': 'config'},
      loaders: [
        _MapLoader(const {'A': 'loader', 'B': 'loader'}),
      ],
      environment: const {'A': 'env', 'B': 'env', 'C': 'env'},
    );
    expect(await s.substitute([r'$A', r'$B', r'$C']), [
      'config',
      'loader',
      'env',
    ]);
  });

  test('substituteMap keeps structure and non-string values', () async {
    const s = VariableSubstitutor(variables: {'H': 'host'}, environment: {});
    expect(
      await s.substituteMap({
        'url': r'https://$H/x',
        'n': 1,
        'nested': {
          'list': [r'${H}', true],
        },
      }),
      {
        'url': 'https://host/x',
        'n': 1,
        'nested': {
          'list': ['host', true],
        },
      },
    );
  });

  test('missing variables throw with the namespaced key', () async {
    const s = VariableSubstitutor(environment: {});
    await expectLater(
      s.substitute(r'${MISSING}', namespace: 'm'),
      throwsA(
        isA<UtcpVariableNotFoundException>().having(
          (e) => e.variableName,
          'variableName',
          'm_MISSING',
        ),
      ),
    );
  });

  test('load_variables_from is parsed with the loader registry', () async {
    VariableLoader.registry.register(
      'inline',
      (json) => _MapLoader(json.optStringMap('values') ?? const {}),
    );
    final config = UtcpClientConfig.fromJson(
      {
        'load_variables_from': [
          {
            'variable_loader_type': 'inline',
            'values': {'A': 'from-json'},
          },
        ],
      },
      variableLoaders: [
        _MapLoader(const {'A': 'passed', 'B': 'passed'}),
      ],
    );
    final s = VariableSubstitutor(
      loaders: config.variableLoaders,
      environment: const {},
    );
    expect(await s.substitute([r'$A', r'$B']), ['from-json', 'passed']);
    expect(
      () => UtcpClientConfig.fromJson({
        'load_variables_from': [
          {'variable_loader_type': 'vault'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('an unregistered dotenv loader names how to register it', () {
    expect(
      () => UtcpClientConfig.fromJson({
        'load_variables_from': [
          {'variable_loader_type': 'dotenv', 'env_file_path': '.env'},
        ],
      }),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains("Unknown variable_loader_type 'dotenv'"),
            contains('DotEnvVariableLoader.register()'),
          ),
        ),
      ),
    );
  });

  test('invalid namespaces are rejected', () {
    const s = VariableSubstitutor(environment: {});
    expect(
      () => s.findRequiredVariables('x', namespace: 'a-b'),
      throwsArgumentError,
    );
  });
}

class _MapLoader extends VariableLoader {
  _MapLoader(this.values);

  final Map<String, String> values;

  @override
  String? get(String key) => values[key];
}
