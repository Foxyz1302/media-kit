import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:media_kit/media_kit.dart';

import '../../common/headless.dart';
import '../../common/leak_probe.dart';
import '../../common/waits.dart';

/// Usage: isolate_kill_helper.dart <iterations> <players> <media>
///
/// Every iteration spawns an isolate that owns playing players and kills it,
/// rotating through [_modes], then keeps the process running while libmpv still
/// calls into the dead isolate (#1348). Finally plays [media] once more, as an
/// engine restart would. Prints one JSON object per line.
Future<void> main(List<String> arguments) async {
  final iterations = int.parse(arguments[0]);
  final players = int.parse(arguments[1]);
  final media = arguments[2];
  initializeHeadless();
  _print({'phase': 'baseline', ...ResourceSnapshot.take().toJson()});
  for (int i = 0; i < iterations; i++) {
    final mode = _modes[i % _modes.length];
    final ready = ReceivePort();
    final exited = ReceivePort();
    final isolate = await Isolate.spawn(
      _owner,
      [ready.sendPort, players, media, mode],
      debugName: 'owner',
      onExit: exited.sendPort,
    );
    await ready.first.timeout(const Duration(seconds: 30));
    isolate.kill(priority: Isolate.immediate);
    await exited.first.timeout(const Duration(seconds: 10));
    await Future.delayed(const Duration(milliseconds: 1500));
    _print({
      'phase': 'killed',
      'iteration': i,
      'mode': mode,
      ...ResourceSnapshot.take().toJson(),
    });
  }
  await Future.delayed(const Duration(seconds: 6));
  final after = ResourceSnapshot.take();
  final player = await headlessPlayer();
  final playing = waitFor(
    player.stream.position,
    (position) => position >= const Duration(milliseconds: 300),
    timeout: const Duration(seconds: 15),
  );
  await player.open(Media(media));
  await playing;
  await player.dispose();
  _print({
    'phase': 'survived',
    'after': after.toJson(),
    'threadNames': threadNames(),
  });
  await stdout.flush();
  exit(0);
}

const List<String> _modes = ['playing', 'opening', 'disposing'];

void _print(Map<String, Object?> message) =>
    stdout.writeln(jsonEncode(message));

Future<void> _owner(List<Object> arguments) async {
  final ready = arguments[0] as SendPort;
  final count = arguments[1] as int;
  final media = arguments[2] as String;
  final mode = arguments[3] as String;
  initializeHeadless();
  final players = <Player>[];
  for (int i = 0; i < count; i++) {
    final player = await headlessPlayer();
    await player.setPlaylistMode(PlaylistMode.single);
    players.add(player);
  }
  if (mode == 'opening') {
    for (final player in players) {
      unawaited(player.open(Media(media)));
    }
  } else {
    for (final player in players) {
      final playing = waitFor(
        player.stream.position,
        (position) => position >= const Duration(milliseconds: 200),
        timeout: const Duration(seconds: 15),
      );
      await player.open(Media(media));
      await playing;
    }
    if (mode == 'disposing') {
      for (final player in players) {
        unawaited(player.dispose());
      }
    }
  }
  ready.send(true);
  await Completer<void>().future;
}
