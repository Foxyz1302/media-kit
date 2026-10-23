import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:media_kit/media_kit.dart';

import '../../common/headless.dart';
import '../../common/leak_probe.dart';
import '../../common/waits.dart';

/// Usage:
///   leak_helper.dart cycles <count> <media>...
///   leak_helper.dart playback <seconds> <media>
///   leak_helper.dart release <timeout seconds> <media>
///
/// Prints one JSON object per line. The workload runs in a spawned isolate: like
/// release builds and `dart test`, it takes the NativeCallable event transport.
Future<void> main(List<String> arguments) async {
  final port = ReceivePort();
  await Isolate.spawn(_run, [port.sendPort, ...arguments], debugName: 'leak');
  await for (final message in port) {
    if (message == null) {
      break;
    }
    stdout.writeln(jsonEncode(message));
  }
  await stdout.flush();
  exit(0);
}

const Duration _deferredDestroy = Duration(seconds: 6);

Future<void> _run(List<Object> arguments) async {
  final port = arguments[0] as SendPort;
  final mode = arguments[1] as String;
  final count = int.parse(arguments[2] as String);
  final media = arguments.skip(3).cast<String>().toList();
  initializeHeadless();
  switch (mode) {
    case 'cycles':
      await _cycles(port, count, media);
    case 'playback':
      await _playback(port, count, media.first);
    case 'release':
      await _release(port, count, media.first);
  }
  port.send(null);
}

Future<void> _cycle(String media) async {
  final player = await headlessPlayer();
  final playing = waitFor(
    player.stream.position,
    (position) => position >= const Duration(milliseconds: 200),
    timeout: const Duration(seconds: 15),
  );
  await player.open(Media(media));
  await playing;
  final seeked = waitFor(
    player.stream.position,
    (position) =>
        position >= const Duration(seconds: 2) &&
        position < const Duration(seconds: 4),
    timeout: const Duration(seconds: 15),
  );
  await player.seek(const Duration(seconds: 2));
  await seeked;
  await player.dispose();
}

Future<void> _settle() async {
  await Future.delayed(_deferredDestroy);
  var threads = nativeThreadCount();
  var stable = Stopwatch()..start();
  final clock = Stopwatch()..start();
  while (stable.elapsed < const Duration(seconds: 1) &&
      clock.elapsed < const Duration(seconds: 10)) {
    await Future.delayed(const Duration(milliseconds: 250));
    final current = nativeThreadCount();
    if (current != threads) {
      threads = current;
      stable = Stopwatch()..start();
    }
  }
}

Map<String, Object?> _sample(String phase,
    [Map<String, Object?> extra = const {}]) {
  return {
    'phase': phase,
    ...ResourceSnapshot.take().toJson(),
    ...extra,
  };
}

Future<void> _cycles(SendPort port, int count, List<String> media) async {
  for (int i = 0; i < 5; i++) {
    await _cycle(media[i % media.length]);
  }
  await _settle();
  final fds = openFds();
  final threads = threadNames();
  port.send(_sample('baseline'));
  final clock = Stopwatch()..start();
  for (int block = 1; block <= 2; block++) {
    for (int i = 1; i <= count; i++) {
      await _cycle(media[i % media.length]);
      if (i % 10 == 0) {
        port.send(_sample('cycle', {'cycle': (block - 1) * count + i}));
      }
    }
    final elapsed = clock.elapsed;
    await _settle();
    if (block == 1) {
      port.send(_sample('settled', {'cycle': count}));
      clock.reset();
    } else {
      port.send(
        _sample('final', {
          'cycle': 2 * count,
          'cycleMs': elapsed.inMilliseconds / count,
          'grownFds': {
            for (final entry in grown(fds, openFds()).entries)
              '${entry.key}': entry.value,
          },
          'grownThreads': grown(threads, threadNames()),
        }),
      );
    }
  }
}

Future<void> _release(SendPort port, int seconds, String media) async {
  for (int i = 0; i < 2; i++) {
    await _cycle(media);
  }
  await _settle();
  final baseline = ResourceSnapshot.take();
  port.send(_sample('baseline'));
  await _cycle(media);
  final clock = Stopwatch()..start();
  int? released;
  while (clock.elapsed < Duration(seconds: seconds)) {
    final current = ResourceSnapshot.take();
    if (current.fds <= baseline.fds + 1 &&
        current.nativeThreads <= baseline.nativeThreads) {
      released = clock.elapsedMilliseconds;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 50));
  }
  port.send(_sample('released', {'releasedAfterMs': released}));
  await _settle();
}

Future<void> _playback(SendPort port, int seconds, String media) async {
  final player = await headlessPlayer();
  await player.setPlaylistMode(PlaylistMode.single);
  final playing = waitFor(
    player.stream.position,
    (position) => position > Duration.zero,
    timeout: const Duration(seconds: 15),
  );
  await player.open(Media(media));
  await playing;
  var positions = 0;
  final subscription = player.stream.position.listen((_) => positions++);
  final fds = openFds();
  for (int i = 0; i <= seconds; i++) {
    port.send(_sample('playback', {'second': i, 'positions': positions}));
    if (i < seconds) {
      await Future.delayed(const Duration(seconds: 1));
    }
  }
  port.send({
    'phase': 'grown',
    'grownFds': {
      for (final entry in grown(fds, openFds()).entries)
        '${entry.key}': entry.value,
    },
  });
  await subscription.cancel();
  await player.dispose();
  await _settle();
}
