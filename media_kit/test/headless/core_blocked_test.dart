@TestOn('linux')
@Tags(['headless'])
library;

import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:test/test.dart';

import '../common/players.dart';
import '../common/test_media.dart';

void main() {
  setUpAll(setUpHeadless);

  test('core-blocked-does-not-block-event-loop', () async {
    // mpv's core opens the audio output on its own thread. ao=pcm on a FIFO without a reader blocks it
    // in fopen, as a hung audio device does (Starsync: openal on Linux, stalls of 18 to 50 s). The FIFO
    // gets its reader after [block], from another process: a test isolate frozen by a synchronous call
    // still gets unblocked.
    const block = Duration(seconds: 4);
    final directory = await Directory.systemTemp.createTemp('media_kit_core_blocked');
    addTearDown(() => directory.delete(recursive: true));
    final fifo = '${directory.path}/ao.fifo';
    final made = await Process.run('mkfifo', [fifo]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    final player = await createPlayer();
    final native = player.platform as NativePlayer;
    await native.setProperty('ao-pcm-file', fifo);
    await native.setProperty('ao', 'pcm');
    await native.setProperty('volume', '0');

    var hookRan = false;
    native.onUnloadHooks.add(() async => hookRan = true);

    final opened = player.open(Media(TestMedia.audio));
    final reader = await Process.start(
      'sh',
      ['-c', 'sleep ${block.inSeconds}; exec cat "\$0" > /dev/null', fifo],
    );
    addTearDown(() => reader.kill());

    // The core reaches the audio output right after the file is opened.
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    var longest = Duration.zero;
    final tick = Stopwatch()..start();
    final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (tick.elapsed > longest) {
        longest = tick.elapsed;
      }
      tick.reset();
    });

    final clock = Stopwatch()..start();
    var settled = <String, Duration>{};
    Future<void> track(String name, Future<Object?> Function() call) async {
      await call();
      settled[name] = clock.elapsed;
    }

    final calls = Future.wait([
      track('getProperty', () => native.getProperty('volume')),
      track('setProperty', () => native.setProperty('volume', '0')),
      track('setPropertySync', () async => native.setPropertySync('volume', '0')),
      track('command', () => native.command(['set', 'volume', '0'])),
      track('pause', () => player.pause()),
    ]);
    final waited = clock.elapsed;

    await calls.timeout(const Duration(seconds: 20));
    await opened.timeout(const Duration(seconds: 20));
    ticker.cancel();
    print(
      'core-blocked-does-not-block-event-loop: issuing the calls took ${waited.inMilliseconds} ms, the longest event-loop gap was ${longest.inMilliseconds} ms, the calls settled at ${settled.map((k, v) => MapEntry(k, v.inMilliseconds))} ms',
    );

    expect(
      waited,
      lessThan(const Duration(milliseconds: 200)),
      reason: 'a call waited on the blocked core on the calling isolate',
    );
    expect(
      longest,
      lessThan(const Duration(milliseconds: 500)),
      reason: "the event loop stalled while mpv's core was blocked",
    );
    expect(
      settled['getProperty']!,
      greaterThan(const Duration(seconds: 1)),
      reason: "the core wasn't blocked: the test proves nothing",
    );

    await player.stop();
    await releasePlayer(player);
    expect(hookRan, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('log-failed-set-once', () async {
    final player = await createPlayer();
    final native = player.platform as NativePlayer;
    final lines = <String>[];
    final subscription = player.stream.log.listen(
      (log) => lines.add('${log.level} ${log.text}'),
    );
    await player.open(Media(TestMedia.audio), play: false);
    await native.setProperty('media-kit-no-such-option', 'no');
    await native.command(['no-such-command']);
    await player.stop();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await subscription.cancel();
    final errors = lines.where((line) => line.contains('error: ')).toList();
    print('log-failed-set-once: $errors');
    expect(
      errors.where((line) => line.contains('media-kit-no-such-option')),
      hasLength(1),
    );
    expect(
      errors.where((line) => line.contains('event:')),
      isEmpty,
      reason: 'a failed request is logged again, without its name, by the event loop',
    );
    expect(
      errors.where((line) => line.contains('http-header-fields')),
      isEmpty,
      reason: 'on_unload failed to reset the HTTP headers',
    );
  });
}
