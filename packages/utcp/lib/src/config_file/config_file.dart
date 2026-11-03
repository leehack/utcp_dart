import 'dart:convert';

import '../json.dart';
import 'read_file.dart';

/// Reads the JSON or YAML configuration document at [path].
Future<JsonMap> readConfigFile(String path) async {
  final text = await readTextFile(path);
  final lower = path.toLowerCase();
  try {
    return asJsonMap(
      lower.endsWith('.yaml') || lower.endsWith('.yml')
          ? decodeYaml(text)
          : jsonDecode(text),
      'Config file',
    );
  } on FormatException catch (e) {
    throw FormatException("Invalid config file '$path': ${e.message}");
  }
}
