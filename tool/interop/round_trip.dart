// Reads an SDK driver's `serialize` output on stdin, parses each document
// with every Dart transport registered, and writes the re-serialized
// documents to stdout.
//
//   dart run tool/interop/round_trip.dart < python.json > python.dart.json
import 'dart:convert';
import 'dart:io';

import 'package:utcp/utcp.dart';

import '../src/interop.dart';

Future<void> main() async {
  await registerAllTransports();
  final input = asJsonMap(
    jsonDecode(await stdin.transform(utf8.decoder).join()),
    'round trip input',
  );
  final output = roundTripDocuments(input);
  final documents = output.objectList('documents');
  final rejected = documents.where((d) => d.containsKey('error')).length;
  stderr.writeln(
    'dart: re-serialized ${documents.length - rejected} of '
    '${documents.length} documents from ${input.string('sdk')}',
  );
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
}
