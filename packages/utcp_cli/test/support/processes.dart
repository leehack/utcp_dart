import 'dart:io';

/// Whether [pid] is a live (not zombie) process.
Future<bool> isAlive(int pid) async {
  if (Platform.isLinux) {
    // Slim images have no `ps`.
    final stat = File('/proc/$pid/stat');
    if (!stat.existsSync()) return false;
    try {
      final text = stat.readAsStringSync();
      return text.substring(text.lastIndexOf(')') + 2)[0] != 'Z';
    } on FileSystemException {
      return false;
    }
  }
  final result = await Process.run('ps', ['-o', 'stat=', '-p', '$pid']);
  final state = '${result.stdout}'.trim();
  return result.exitCode == 0 && state.isNotEmpty && !state.startsWith('Z');
}

/// Waits up to [within] for [pid] to be gone.
Future<bool> diesWithin(
  int pid, {
  Duration within = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (!await isAlive(pid)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

/// Waits for [file] to hold a pid written by a test command.
Future<int> readPid(
  File file, {
  Duration within = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(within);
  while (DateTime.now().isBefore(deadline)) {
    if (file.existsSync()) {
      final pid = int.tryParse(file.readAsStringSync().trim());
      if (pid != null) return pid;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('No pid in ${file.path}');
}
