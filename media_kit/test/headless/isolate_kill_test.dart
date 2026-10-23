@TestOn('linux')
@Tags(['headless'])
library;

import 'package:test/test.dart';

import '../common/helper_process.dart';
import '../common/test_media.dart';

void main() {
  setUpAll(TestMedia.ensure);

  test('isolate-kill-with-live-players-1348', () async {
    final result = await runHelper(
      'test/headless/helpers/isolate_kill_helper.dart',
      ['6', '2', TestMedia.h264],
      timeout: const Duration(minutes: 2),
    );
    expect(
      result.stderr,
      isNot(contains('Callback invoked after it has been deleted')),
      reason:
          'libmpv called the NativeCallable wakeup of a dead isolate (#1348). '
          'DECISIONS.md: a C wakeup posting through Dart_PostCObject, and a NativeFinalizer destroying mpv on a worker thread.',
    );
    expect(result.exitCode, 0, reason: '$result');
    final messages = result.messages;
    final baseline = messages.firstWhere((m) => m['phase'] == 'baseline');
    final survived = messages.where((m) => m['phase'] == 'survived').toList();
    expect(survived, hasLength(1), reason: '$result');
    final after = survived.single['after'] as Map<String, dynamic>;
    expect(
      after['nativeThreads'] - baseline['nativeThreads'],
      lessThanOrEqualTo(1),
      reason:
          'the players of the killed isolates are still running: mpv outlives its owner. Threads: ${survived.single['threadNames']}',
    );
  }, tags: 'known-failing', timeout: const Timeout(Duration(minutes: 3)));
}
