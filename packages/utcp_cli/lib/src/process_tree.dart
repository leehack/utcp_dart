import 'dart:io';

/// Kills [process] and every process it started, then waits for [process]
/// to exit.
///
/// Killing only the shell would orphan the commands it is running (a
/// `sleep` inside the script keeps going). On Unix each generation is
/// stopped with SIGSTOP before its children are listed, so nothing can fork
/// past the sweep; then all are killed. Orphans are reaped by init.
Future<void> killProcessTree(Process process) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
  } else {
    final victims = <int>{};
    var generation = {process.pid};
    while (generation.isNotEmpty) {
      for (final pid in generation) {
        Process.killPid(pid, ProcessSignal.sigstop);
      }
      victims.addAll(generation);
      generation = {
        for (final (pid, parent) in await _processTable())
          if (victims.contains(parent) && !victims.contains(pid)) pid,
      };
    }
    for (final pid in victims) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }
  process.kill(ProcessSignal.sigkill);
  await process.exitCode;
}

/// `(pid, parent pid)` of every process: from `/proc` on Linux, where `ps`
/// may be missing in slim containers, and from `ps` elsewhere.
Future<List<(int, int)>> _processTable() async {
  if (Platform.isLinux) {
    final table = <(int, int)>[];
    await for (final entry in Directory('/proc').list()) {
      final pid = int.tryParse(entry.path.split('/').last);
      if (pid == null) continue;
      try {
        final stat = await File('/proc/$pid/stat').readAsString();
        // The command name in parentheses may contain spaces; fields after
        // it are `state ppid ...`.
        final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
        table.add((pid, int.parse(fields[1])));
      } on FileSystemException {
        // The process exited while the table was read.
      }
    }
    return table;
  }
  try {
    final result = await Process.run('ps', ['-A', '-o', 'pid=', '-o', 'ppid=']);
    return [
      for (final line in '${result.stdout}'.split('\n'))
        if (line.trim().split(RegExp(r'\s+')) case [final pid, final parent])
          (int.parse(pid), int.parse(parent)),
    ];
  } on ProcessException {
    return const [];
  }
}
