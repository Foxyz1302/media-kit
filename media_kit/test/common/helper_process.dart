import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

import 'test_media.dart';

/// {@template helper_result}
///
/// HelperResult
/// ------------
/// Outcome of [runHelper].
///
/// {@endtemplate}
class HelperResult {
  /// {@macro helper_result}
  const HelperResult(this.exitCode, this.stdout, this.stderr, this.timedOut);

  /// Exit code; a negative value is the signal that ended the process, e.g. -6 for SIGABRT.
  final int exitCode;

  final String stdout;

  final String stderr;

  /// Whether the process was killed for running longer than its timeout.
  final bool timedOut;

  /// The JSON objects the helper printed, one per line.
  List<Map<String, dynamic>> get messages => [
        for (final line in LineSplitter.split(stdout))
          if (line.startsWith('{')) jsonDecode(line) as Map<String, dynamic>,
      ];

  @override
  String toString() =>
      'exit code: $exitCode${timedOut ? ' (timed out)' : ''}\nstdout:\n$stdout\nstderr:\n$stderr';
}

/// Runs the Dart [script] (relative to the package root) in a new process with the
/// current package configuration, core dumps disabled, and [environment] added.
Future<HelperResult> runHelper(
  String script,
  List<String> arguments, {
  Duration timeout = const Duration(minutes: 3),
  Map<String, String> environment = const {},
}) async {
  final root = await packageRoot();
  final packages = await Isolate.packageConfig;
  final process = await Process.start(
    '/bin/sh',
    [
      '-c',
      r'ulimit -c 0 && exec "$@"',
      'sh',
      Platform.resolvedExecutable,
      '--packages=${packages!.toFilePath()}',
      path.join(root, script),
      ...arguments,
    ],
    environment: environment,
  );
  final stdout = process.stdout.transform(utf8.decoder).join();
  final stderr = process.stderr.transform(utf8.decoder).join();
  var timedOut = false;
  final exitCode = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return process.exitCode;
    },
  );
  return HelperResult(exitCode, await stdout, await stderr, timedOut);
}
