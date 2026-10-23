@TestOn('linux')
@Tags(['headless'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../common/helper_process.dart';
import '../common/test_media.dart';

const String _helper = 'test/headless/helpers/leak_helper.dart';

const Map<String, String> _environment = {'MALLOC_ARENA_MAX': '2'};

void main() {
  setUpAll(TestMedia.ensure);

  Map<String, dynamic> phase(HelperResult result, String name) =>
      result.messages.lastWhere((message) => message['phase'] == name);

  test('leak-open-play-seek-dispose-cycles', () async {
    final cycles =
        int.tryParse(Platform.environment['MEDIA_KIT_LEAK_CYCLES'] ?? '') ?? 30;
    final result = await runHelper(
      _helper,
      [
        'cycles',
        '$cycles',
        TestMedia.h264,
        TestMedia.hevc,
        TestMedia.vp9,
        TestMedia.av1,
      ],
      environment: _environment,
      timeout: const Duration(minutes: 5),
    );
    expect(result.exitCode, 0, reason: '$result');
    final baseline = phase(result, 'baseline');
    final settled = phase(result, 'settled');
    final last = phase(result, 'final');
    final peak = result.messages
        .where((message) => message['phase'] == 'cycle')
        .map((message) => message['fds'] as int)
        .fold(0, (a, b) => a > b ? a : b);
    print(
      'leak-open-play-seek-dispose-cycles: ${2 * cycles} cycles of ${last['cycleMs']} ms. '
      'fds ${baseline['fds']} -> ${last['fds']} (peak $peak), '
      'native threads ${baseline['nativeThreads']} -> ${last['nativeThreads']}, '
      'rss ${baseline['rssKiB'] ~/ 1024} -> ${settled['rssKiB'] ~/ 1024} -> ${last['rssKiB'] ~/ 1024} MiB',
    );
    expect(
      last['fds'] - baseline['fds'],
      lessThanOrEqualTo(2),
      reason:
          'file descriptors left after ${2 * cycles} cycles: ${last['grownFds']}',
    );
    expect(
      last['nativeThreads'] - baseline['nativeThreads'],
      lessThanOrEqualTo(1),
      reason:
          'threads left after ${2 * cycles} cycles: ${last['grownThreads']}',
    );
    expect(
      last['rssKiB'] - settled['rssKiB'],
      lessThanOrEqualTo(16 * 1024),
      reason: 'RSS grew between cycle $cycles and cycle ${2 * cycles}',
    );
  }, timeout: const Timeout(Duration(minutes: 6)));
  test('leak-playback-file-descriptors', () async {
    final result = await runHelper(
      _helper,
      ['playback', '10', TestMedia.h264],
      environment: _environment,
    );
    expect(result.exitCode, 0, reason: '$result');
    final samples = result.messages
        .where((message) => message['phase'] == 'playback')
        .toList();
    final first = samples[1];
    final last = samples.last;
    print(
      'leak-playback-file-descriptors: fds ${first['fds']} -> ${last['fds']}, '
      'native threads ${first['nativeThreads']} -> ${last['nativeThreads']}, '
      'rss ${first['rssKiB'] ~/ 1024} -> ${last['rssKiB'] ~/ 1024} MiB, '
      '${last['positions']} positions',
    );
    expect(last['positions'], greaterThan(200));
    expect(
      last['fds'] - first['fds'],
      lessThanOrEqualTo(1),
      reason:
          'file descriptors grew during playback (#1391): ${phase(result, 'grown')['grownFds']}',
    );
    expect(
        last['nativeThreads'] - first['nativeThreads'], lessThanOrEqualTo(1));
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('leak-resources-released-after-dispose', () async {
    final result = await runHelper(
      _helper,
      ['release', '10', TestMedia.h264],
      environment: _environment,
    );
    expect(result.exitCode, 0, reason: '$result');
    final released = phase(result, 'released')['releasedAfterMs'];
    print('leak-resources-released-after-dispose: $released ms');
    expect(
      released,
      isNotNull,
      reason:
          'threads and file descriptors were not released within 10 s of dispose',
    );
    expect(
      released,
      lessThanOrEqualTo(1000),
      reason: 'mpv_terminate_destroy runs 5 s after dispose (L-6, P1-C3)',
    );
  }, tags: 'known-failing', timeout: const Timeout(Duration(minutes: 2)));
}
