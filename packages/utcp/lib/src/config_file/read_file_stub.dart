Future<String> readTextFile(String path) => Future.error(
  UnsupportedError('Reading a config file needs dart:io (not on the web).'),
);
