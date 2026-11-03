// Harvests the UTCP documents of the spec and the reference SDKs and
// compares them with the corpus in fixtures/.
//
//   dart run tool/harvest.dart [--head] [--checkouts <dir>] [--write]
//       [--report <file>]
//
// Without --head it reads the commits in refs.lock; with it, each
// repository's default branch. --checkouts reads existing clones in
// <dir>/<repo> instead of cloning. --write updates fixtures/ and refs.lock.
// Exits 0 when the corpus matches, 1 when it differs (and --write is not
// given), 2 on a usage error or failure.
import 'dart:io';

import 'package:utcp_conformance/utcp_conformance.dart';

Future<void> main(List<String> args) async {
  final options = _parse(args);
  final root = File.fromUri(Platform.script).parent.parent;
  final lockFile = File('${root.path}/refs.lock');
  final fixturesDir = Directory('${root.path}/fixtures');
  final lock = RefsLock.read(lockFile);
  final temp = await Directory.systemTemp.createTemp('utcp_harvest_');
  final protocols = registerAllProtocols();
  try {
    final commits = <String, String>{};
    final harvested = <Fixture>[];
    for (final MapEntry(key: name, value: ref) in lock.repos.entries) {
      final Directory dir;
      if (options.checkouts case final checkouts?) {
        dir = Directory('$checkouts/$name');
      } else {
        dir = Directory('${temp.path}/$name');
        stderr.writeln('Cloning ${ref.url}');
        await cloneRepo(ref, dir);
      }
      final commit = await resolveCommit(
        dir,
        options.head ? 'HEAD' : ref.commit,
      );
      commits[name] = commit;
      harvested.addAll(await harvestRepo(name, dir, commit));
    }

    final committed = Corpus.read(fixturesDir);
    final diff = CorpusDiff(committed, harvested);
    stderr.writeln(
      'Harvested ${harvested.length} documents; corpus has '
      '${committed.fixtures.length}. ${diff.added.length} new, '
      '${diff.removed.length} gone, ${diff.moved.length} moved.',
    );
    if (diff.isEmpty) return;
    final report = diff.report(lock, commits);
    if (options.report case final path?) {
      File(path).writeAsStringSync(report);
    } else {
      stdout.write(report);
    }
    if (options.write) {
      committed.updatedTo(harvested).write(fixturesDir);
      lock.withCommits(commits).write(lockFile);
      stderr.writeln('Updated fixtures/ and refs.lock.');
    } else {
      exitCode = 1;
    }
  } on HarvestException catch (error) {
    stderr.writeln(error);
    exitCode = 2;
  } finally {
    for (final protocol in protocols) {
      await protocol.close();
    }
    await temp.delete(recursive: true);
  }
}

({bool head, bool write, String? checkouts, String? report}) _parse(
  List<String> args,
) {
  var head = false;
  var write = false;
  String? checkouts;
  String? report;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--head':
        head = true;
      case '--write':
        write = true;
      case '--checkouts' when i + 1 < args.length:
        checkouts = args[++i];
      case '--report' when i + 1 < args.length:
        report = args[++i];
      default:
        stderr.writeln(
          'Usage: dart run tool/harvest.dart [--head] [--checkouts <dir>] '
          '[--write] [--report <file>]',
        );
        exit(2);
    }
  }
  return (head: head, write: write, checkouts: checkouts, report: report);
}
