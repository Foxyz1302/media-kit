@TestOn('linux')
@Tags(['headless'])
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:test/test.dart';

import '../common/headless.dart';
import '../common/media_server.dart';
import '../common/players.dart';
import '../common/test_media.dart';
import '../common/waits.dart';

void main() {
  setUpAll(setUpHeadless);

  List<String> videos() => [
        TestMedia.h264,
        TestMedia.hevc,
        TestMedia.vp9,
        TestMedia.av1,
      ];

  Future<void> openAndPlay(
    Player player,
    String media, {
    Duration until = const Duration(milliseconds: 200),
  }) async {
    final playing = waitFor(
      player.stream.position,
      (position) => position >= until,
      reason: 'position $until in $media',
    );
    await player.open(Media(media));
    await playing;
  }

  Future<void> seekAndWait(Player player, Duration target) async {
    final arrived = waitFor(
      player.stream.position,
      (position) =>
          position >= target && position < target + const Duration(seconds: 2),
      reason: 'position after seeking to $target',
    );
    await player.seek(target);
    await arrived;
  }

  Future<void> expectClosed(Player player) async {
    final streams = <Stream<Object?>>[
      player.stream.position,
      player.stream.playing,
      player.stream.completed,
      player.stream.error,
    ];
    for (final stream in streams) {
      await stream.drain<void>().timeout(const Duration(seconds: 5));
    }
  }

  group('loops', () {
    test('lifecycle-create-dispose', () async {
      for (int i = 0; i < 40; i++) {
        final player = await createPlayer();
        await player.handle;
        await releasePlayer(player);
      }
    });
    test('lifecycle-create-dispose-before-initialized', () async {
      for (int i = 0; i < 40; i++) {
        final player = trackPlayer(Player());
        unawaited(forceSoftwareDecoding(player).catchError((_) {}));
        await releasePlayer(player);
      }
    });
    test('lifecycle-open-play-seek-dispose', () async {
      for (int i = 0; i < 16; i++) {
        final player = await createPlayer();
        await openAndPlay(player, videos()[i % 4]);
        await seekAndWait(player, const Duration(seconds: 3));
        await releasePlayer(player);
        await expectClosed(player);
      }
    });
    test('lifecycle-open-dispose-immediately', () async {
      for (int i = 0; i < 16; i++) {
        final player = await createPlayer();
        await player.open(Media(videos()[i % 4]));
        await releasePlayer(player);
        await expectClosed(player);
      }
    });
  });

  group('concurrency', () {
    test('lifecycle-many-players', () async {
      final media = [
        ...videos(),
        TestMedia.audio,
        TestMedia.chapters,
        TestMedia.h264,
        TestMedia.hevc,
      ];
      final players = await Future.wait([
        for (final _ in media) createPlayer(),
      ]);
      await Future.wait([
        for (int i = 0; i < players.length; i++)
          openAndPlay(
            players[i],
            media[i],
            until: const Duration(milliseconds: 500),
          ),
      ]);
      await Future.wait([
        for (final player in players)
          seekAndWait(player, const Duration(seconds: 2)),
      ]);
      await Future.wait([for (final player in players) player.pause()]);
      await Future.wait([for (final player in players) releasePlayer(player)]);
    });
    test('lifecycle-players-storm', () async {
      for (int round = 0; round < 3; round++) {
        final players = await Future.wait([
          for (int i = 0; i < 12; i++) createPlayer(),
        ]);
        await Future.wait([
          for (int i = 0; i < players.length; i++)
            players[i].open(Media(videos()[i % 4])),
        ]);
        await Future.wait([
          for (final player in players) releasePlayer(player),
        ]);
      }
    });
    test('lifecycle-open-storm', () async {
      final player = await createPlayer();
      final calls = <Future<void>>[];
      for (int i = 0; i < 40; i++) {
        calls.add(player.open(Media(videos()[i % 4])));
        if (i % 5 == 4) {
          calls.add(player.stop());
        }
      }
      await Future.wait(calls).timeout(const Duration(seconds: 60));
      await openAndPlay(
        player,
        TestMedia.h264,
        until: const Duration(milliseconds: 500),
      );
      expect(player.state.playlist.medias.single, Media(TestMedia.h264));
      expect(player.state.duration.inMilliseconds, closeTo(6000, 50));
      expect(player.state.completed, isFalse);
      expect(player.state.playing, isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));
    test('lifecycle-open-close-storm', () async {
      final disposals = <Future<void>>[];
      for (int i = 0; i < 24; i++) {
        final player = await createPlayer();
        unawaited(player.open(Media(videos()[i % 4])));
        disposals.add(releasePlayer(player));
      }
      await Future.wait(disposals);
    });
  });

  group('dispose', () {
    test('lifecycle-dispose-during-open', () async {
      for (int i = 0; i < 8; i++) {
        final player = await createPlayer();
        final open = player.open(Media(videos()[i % 4]));
        final dispose = player.dispose();
        await Future.wait([
          open.catchError((_) {}),
          dispose,
        ]).timeout(const Duration(seconds: 10));
        await expectClosed(player);
      }
    });
    final opens = <String, Faults>{
      'latency': const Faults(latency: Duration(seconds: 3)),
      'slow-headers': const Faults(headerDelay: Duration(seconds: 1)),
      'stalled-body': const Faults(
        stallAfterBytes: 0,
        stallFor: Duration(seconds: 30),
      ),
    };
    for (final entry in opens.entries) {
      test('lifecycle-dispose-during-network-open-${entry.key}', () async {
        final server = await MediaServer.start();
        addTearDown(server.close);
        final url = server.serveFile(
          '/stream.mp4',
          TestMedia.stream,
          faults: entry.value,
        );
        final player = await createPlayer();
        final requested = server.onRequest.first;
        await player.open(Media('$url'));
        await requested.timeout(const Duration(seconds: 5));
        final elapsed = await timed(() => player.dispose());
        print(
          'lifecycle-dispose-during-network-open-${entry.key}: dispose ${elapsed.inMilliseconds} ms',
        );
        expect(elapsed, lessThan(const Duration(seconds: 5)));
        await expectClosed(player);
      });
    }
    test('lifecycle-dispose-during-seek', () async {
      for (int i = 0; i < 8; i++) {
        final player = await createPlayer();
        await openAndPlay(player, videos()[i % 4]);
        final seek = player.seek(const Duration(seconds: 4));
        final dispose = player.dispose();
        await Future.wait([
          seek.catchError((_) {}),
          dispose,
        ]).timeout(const Duration(seconds: 10));
        await expectClosed(player);
      }
    });
    test('lifecycle-dispose-during-network-seek', () async {
      final server = await MediaServer.start();
      addTearDown(server.close);
      final url = server.serveFile(
        '/stream.mp4',
        TestMedia.stream,
        faults: const Faults(bytesPerSecond: 150000),
      );
      final player = await createPlayer();
      final playing = waitFor(
        player.stream.position,
        (position) => position >= const Duration(milliseconds: 500),
        reason: 'position 0.5 s',
      );
      await player.open(Media('$url'));
      await playing;
      server.setFaults(
          '/stream.mp4', const Faults(latency: Duration(seconds: 10)));
      final requested = waitFor(
        server.onRequest,
        (request) => request.rangeStart > 0,
        reason: 'the range request of the seek',
      );
      await player.seek(const Duration(seconds: 8));
      await requested;
      final elapsed = await timed(() => player.dispose());
      print(
        'lifecycle-dispose-during-network-seek: dispose ${elapsed.inMilliseconds} ms',
      );
      expect(elapsed, lessThan(const Duration(seconds: 5)));
      await expectClosed(player);
    });
    test('lifecycle-methods-after-dispose-throw', () async {
      final player = await createPlayer();
      await player.open(Media(TestMedia.h264), play: false);
      await player.dispose();
      final calls = <String, Future<void> Function()>{
        'open': () => player.open(Media(TestMedia.h264)),
        'stop': player.stop,
        'play': player.play,
        'pause': player.pause,
        'playOrPause': player.playOrPause,
        'add': () => player.add(Media(TestMedia.h264)),
        'remove': () => player.remove(0),
        'next': player.next,
        'previous': player.previous,
        'jump': () => player.jump(0),
        'move': () => player.move(0, 1),
        'seek': () => player.seek(Duration.zero),
        'setPlaylistMode': () => player.setPlaylistMode(PlaylistMode.loop),
        'setVolume': () => player.setVolume(50),
        'setRate': () => player.setRate(1.5),
        'setPitch': () => player.setPitch(1.5),
        'setShuffle': () => player.setShuffle(true),
        'setAudioDevice': () => player.setAudioDevice(AudioDevice.auto()),
        'setVideoTrack': () => player.setVideoTrack(VideoTrack.auto()),
        'setAudioTrack': () => player.setAudioTrack(AudioTrack.auto()),
        'setSubtitleTrack': () => player.setSubtitleTrack(SubtitleTrack.auto()),
        'screenshot': () => player.screenshot(),
      };
      for (final entry in calls.entries) {
        await expectLater(
          entry.value().timeout(const Duration(seconds: 5)),
          throwsA(isNot(isA<TimeoutException>())),
          reason: '${entry.key} after dispose',
        );
      }
    });
    test('lifecycle-double-dispose', () async {
      final player = await createPlayer();
      await player.open(Media(TestMedia.h264));
      final first = player.dispose();
      final second = player.dispose();
      await expectLater(
        first.timeout(const Duration(seconds: 10)),
        completes,
      );
      await expectLater(
        second.timeout(const Duration(seconds: 10)),
        completes,
        reason: 'dispose must be idempotent (DECISIONS.md, P1-C3)',
      );
    }, tags: 'known-failing');
  });

  group('isolation', () {
    test('lifecycle-player-not-blocked-by-another', () async {
      final a = await createPlayer();
      final b = await createPlayer();
      await a.open(Media(TestMedia.h264), play: false);
      await b.open(Media(TestMedia.h264), play: false);
      var finished = 0;
      final seeks = [
        for (int i = 0; i < 300; i++)
          a.seek(Duration(milliseconds: i * 10)).then((_) => finished++),
      ];
      final elapsed = await timed(b.play);
      final finishedBeforeB = finished;
      await Future.wait(seeks);
      print(
        'lifecycle-player-not-blocked-by-another: B.play() ${elapsed.inMilliseconds} ms, A seeks finished before it: $finishedBeforeB/${seeks.length}',
      );
      expect(
        finishedBeforeB,
        lessThan(seeks.length),
        reason:
            "B.play() waited for all of A's queued seeks: every player shares one static lock (P1-C2)",
      );
    }, tags: 'known-failing');
    test('lifecycle-unobserve-property-keeps-position', () async {
      final player = await createPlayer();
      final native = player.platform as NativePlayer;
      await player.setPlaylistMode(PlaylistMode.single);
      await openAndPlay(player, TestMedia.h264);
      await native.observeProperty('time-pos', (_) async {});
      await native.unobserveProperty('time-pos');
      final positions = await collect(
        player.stream.position,
        const Duration(seconds: 1),
      );
      expect(
        positions.length,
        greaterThan(5),
        reason:
            'unobserveProperty removed the internal time-pos observer: both use reply_userdata = name.hashCode (E-8, P1-C4)',
      );
    }, tags: 'known-failing');
  });
}
