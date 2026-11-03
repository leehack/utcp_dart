import 'dart:convert';

/// Prints its arguments as a JSON array, so tests can see exactly which
/// words the shell passed.
void main(List<String> args) => print(jsonEncode(args));
