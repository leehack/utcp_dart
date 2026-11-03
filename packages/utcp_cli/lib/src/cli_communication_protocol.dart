import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:utcp/utcp.dart';

import 'cli_call_template.dart';
import 'output.dart';
import 'process_tree.dart';
import 'shell_script.dart';

/// Discovers and calls tools that run as local commands (`cli` call
/// templates).
///
/// Discovery runs the manual template's commands and parses their output as
/// a UTCP manual. A tool call runs the tool template's commands with the
/// arguments and returns the output, decoded as JSON when it is JSON.
///
/// A script that outlives its timeout or writes more than [maxOutputBytes],
/// a cancelled [callToolStreaming] subscription, and [close] kill the shell
/// and every process it started. A bash script that a command ends early
/// (`exit`, `exec`, `set -e`) fails the call.
class CliCommunicationProtocol extends CommunicationProtocol {
  /// Creates a protocol with the given limits for each script run.
  CliCommunicationProtocol({
    this.discoveryTimeout = const Duration(seconds: 60),
    this.callTimeout = const Duration(seconds: 120),
    this.maxOutputBytes = 10 * 1024 * 1024,
  });

  /// Limit for discovery commands; the reference SDKs use 60 seconds.
  final Duration discoveryTimeout;

  /// Limit for tool calls; the reference SDKs use 120 seconds.
  final Duration callTimeout;

  /// Limit on the bytes a script may write to stdout and stderr together;
  /// a script that writes more is killed and the call fails. The reference
  /// SDKs have no limit.
  final int maxOutputBytes;

  final _runs = <_Run>{};
  bool _closed = false;

  @override
  Map<String, JsonFactory<CallTemplate>> get callTemplateTypes => const {
    CliCallTemplate.type: CliCallTemplate.fromJson,
  };

  @override
  Future<RegisterManualResult> registerManual(
    UtcpClient caller,
    CallTemplate manualCallTemplate,
  ) async {
    final template = requireCallTemplate<CliCallTemplate>(manualCallTemplate);
    final name = template.name;
    try {
      final output = await _execute(
        _Run(),
        template,
        const {},
        discoveryTimeout,
      );
      final text = output.exitCode == 0 ? output.stdout : output.stderr;
      if (text.trim().isEmpty) {
        return RegisterManualResult.failure(template, [
          "No output from discovery commands for CLI manual '$name'.",
        ]);
      }
      return RegisterManualResult(
        manualCallTemplate: template,
        manual: parseManualOutput(text),
      );
    } on FormatException catch (e) {
      return RegisterManualResult.failure(template, [
        "Could not parse a UTCP manual from CLI manual '$name': ${e.message}",
      ]);
    } on UtcpException catch (e) {
      return RegisterManualResult.failure(template, [e.message]);
    }
  }

  @override
  Future<Object?> callTool(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) => _call(_Run(), toolCallTemplate, arguments);

  /// Yields the whole result once. Cancelling the subscription kills the
  /// running commands.
  @override
  Stream<Object?> callToolStreaming(
    UtcpClient caller,
    String toolName,
    ToolArguments arguments,
    CallTemplate toolCallTemplate,
  ) {
    final run = _Run();
    late final StreamController<Object?> controller;
    controller = StreamController(
      onListen: () async {
        try {
          controller.add(await _call(run, toolCallTemplate, arguments));
        } on Object catch (e, stack) {
          controller.addError(e, stack);
        }
        run.complete();
        await controller.close();
      },
      onCancel: () {
        run.abort('was cancelled');
        return run.finished;
      },
    );
    return controller.stream;
  }

  Future<Object?> _call(
    _Run run,
    CallTemplate toolCallTemplate,
    ToolArguments arguments,
  ) async {
    final template = requireCallTemplate<CliCallTemplate>(toolCallTemplate);
    return parseToolOutput(
      await _execute(run, template, arguments, callTimeout),
      Shell.host,
    );
  }

  /// Kills every running command and waits until they have exited. Later
  /// calls fail.
  @override
  Future<void> close() async {
    _closed = true;
    final runs = _runs.toList();
    for (final run in runs) {
      run.abort('was stopped because the protocol was closed');
    }
    await Future.wait([for (final run in runs) run.finished]);
  }

  Future<ScriptOutput> _execute(
    _Run run,
    CliCallTemplate template,
    ToolArguments arguments,
    Duration timeout,
  ) async {
    if (_closed) throw const UtcpException('CLI protocol is closed.');
    _runs.add(run);
    final shell = Shell.host;
    Directory? captureDir;
    try {
      captureDir = await Directory.systemTemp.createTemp('utcp_cli_');
      final script = buildShellScript(
        template.commands,
        arguments,
        shell: shell,
        nonce: randomNonce(),
        captureFile: '${captureDir.path}${Platform.pathSeparator}output',
      );
      final process = await _start(shell, script, template);
      return requireFinished(await _wait(run, process, timeout), script);
    } on FileSystemException catch (e) {
      throw UtcpException('Could not create the CLI output file: ${e.message}');
    } finally {
      await captureDir?.delete(recursive: true);
      _runs.remove(run);
      run.complete();
    }
  }

  Future<Process> _start(
    Shell shell,
    ShellScript script,
    CliCallTemplate template,
  ) async {
    try {
      return await Process.start(
        shell.executable,
        shell.arguments(script.source),
        workingDirectory: template.workingDir,
        environment: subprocessEnvironment(
          template,
          script,
          Platform.environment,
          shell,
        ),
        includeParentEnvironment: false,
      );
    } on ProcessException catch (e) {
      final where = switch (template.workingDir) {
        null => '',
        final dir => " in '$dir'",
      };
      throw UtcpException(
        'Could not start ${shell.executable}$where: ${e.message}',
      );
    }
  }

  Future<ScriptOutput> _wait(
    _Run run,
    Process process,
    Duration timeout,
  ) async {
    process.stdin.close().ignore();
    var budget = maxOutputBytes;
    Future<String> read(Stream<List<int>> stream) async {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in stream) {
        budget -= chunk.length;
        if (budget < 0) {
          run.abort('wrote more than $maxOutputBytes bytes of output');
          break;
        }
        bytes.add(chunk);
      }
      return const Utf8Decoder(allowMalformed: true).convert(bytes.takeBytes());
    }

    final finished = Future.wait([
      read(process.stdout),
      read(process.stderr),
      process.exitCode,
    ]);
    final timer = Timer(
      timeout,
      () => run.abort('timed out after ${timeout.inMilliseconds} ms'),
    );
    try {
      final outcome = await Future.any<Object>([finished, run.aborted]);
      // An abort can race a finishing script; its reason wins, so output
      // cut short by the limit is never returned as a result.
      if (outcome case [
        final String stdout,
        final String stderr,
        final int exitCode,
      ] when run.reason == null) {
        return (stdout: stdout, stderr: stderr, exitCode: exitCode);
      }
      await killProcessTree(process);
      // The pipes close once every writer is dead; the bound only guards
      // against a writer that escaped the kill.
      await finished.timeout(
        const Duration(seconds: 5),
        onTimeout: () => const [],
      );
      throw UtcpException('CLI command ${run.reason}.');
    } finally {
      timer.cancel();
    }
  }
}

/// One script execution, which [abort] stops from outside.
final class _Run {
  final _aborted = Completer<String>();
  final _finished = Completer<void>();

  String? _reason;

  /// Why the run was aborted, or null while it was not.
  String? get reason => _reason;

  /// Completes with the reason when the run is aborted.
  Future<String> get aborted => _aborted.future;

  /// Completes when the run, and any process it started, has ended.
  Future<void> get finished => _finished.future;

  void abort(String why) {
    if (_aborted.isCompleted) return;
    _reason = why;
    _aborted.complete(why);
  }

  void complete() {
    if (!_finished.isCompleted) _finished.complete();
  }
}
