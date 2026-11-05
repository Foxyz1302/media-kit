@TestOn('linux')
@Tags(['headless'])
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:test/test.dart';

import '../common/players.dart';
import '../common/test_media.dart';
import '../common/waits.dart';

void main() {
  setUpAll(setUpHeadless);

  /// Position events while [player] plays [TestMedia.h264] for 2 s, & the last position seen.
  Future<(int, Duration)> countPositions(Player player) async {
    await player.open(Media(TestMedia.h264));
    await waitFor(
      player.stream.position,
      (position) => position >= const Duration(milliseconds: 200),
      reason: 'playback',
    );
    var events = 0;
    var last = Duration.zero;
    final subscription = player.stream.position.listen((position) {
      events++;
      last = position;
    });
    await Future<void>.delayed(const Duration(seconds: 2));
    await subscription.cancel();
    return (events, last);
  }

  test('position-update-interval-default-every-change', () async {
    final player = await createPlayer();
    final (events, _) = await countPositions(player);
    expect(events, greaterThan(30));
  });

  test('position-update-interval-throttles-stream-not-state', () async {
    final player = await createPlayer(
      configuration: const PlayerConfiguration(
        positionUpdateInterval: Duration(milliseconds: 250),
      ),
    );
    final (events, last) = await countPositions(player);
    expect(events, inInclusiveRange(6, 10));
    expect(player.state.position, greaterThanOrEqualTo(last));
    expect(
      player.state.position - last,
      lessThan(const Duration(milliseconds: 300)),
    );
  });

  test('position-update-interval-seek-and-pause-emit-at-once', () async {
    final player = await createPlayer(
      configuration: const PlayerConfiguration(
        positionUpdateInterval: Duration(seconds: 2),
      ),
    );
    await countPositions(player);
    final sought = Completer<Duration>();
    final subscription = player.stream.position.listen((position) {
      if (position >= const Duration(seconds: 5) && !sought.isCompleted) {
        sought.complete(position);
      }
    });
    final watch = Stopwatch()..start();
    await player.seek(const Duration(seconds: 5));
    await sought.future.timeout(const Duration(seconds: 1));
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    await subscription.cancel();

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final paused = player.stream.position.first;
    await player.pause();
    final position = await paused.timeout(const Duration(seconds: 1));
    expect(position, greaterThan(const Duration(seconds: 5)));
  });
}
