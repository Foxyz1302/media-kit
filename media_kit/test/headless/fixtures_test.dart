@TestOn('linux')
@Tags(['headless'])
library;

import 'package:media_kit/media_kit.dart';
import 'package:test/test.dart';

import '../common/players.dart';
import '../common/test_media.dart';
import '../common/waits.dart';

void main() {
  setUpAll(setUpHeadless);

  final videos = <String, String Function()>{
    'h264': () => TestMedia.h264,
    'hevc': () => TestMedia.hevc,
    'vp9': () => TestMedia.vp9,
    'av1': () => TestMedia.av1,
  };
  for (final entry in videos.entries) {
    test('fixture-${entry.key}', () async {
      final player = await createPlayer();
      final width = waitFor(player.stream.width, (width) => width != null);
      final playing = waitFor(
        player.stream.position,
        (position) => position >= const Duration(milliseconds: 500),
        reason: 'position 0.5 s',
      );
      await player.open(Media(entry.value()));
      expect(await width, 320);
      await playing;
      expect(player.state.height, 240);
      expect(player.state.duration.inMilliseconds, closeTo(6000, 50));
      final native = player.platform as NativePlayer;
      expect(await native.getProperty('hwdec'), 'no');
      expect(await native.getProperty('hwdec-current'), anyOf('no', ''));
    });
  }
  test('fixture-audio', () async {
    final player = await createPlayer();
    final sampleRate = waitFor(
      player.stream.audioParams,
      (params) => params.sampleRate != null,
    );
    final playing = waitFor(
      player.stream.position,
      (position) => position >= const Duration(milliseconds: 500),
      reason: 'position 0.5 s',
    );
    await player.open(Media(TestMedia.audio));
    expect((await sampleRate).sampleRate, 48000);
    await playing;
    expect(player.state.duration.inMilliseconds, closeTo(6000, 50));
    expect(player.state.width, isNull);
  });
  test('fixture-chapters', () async {
    final player = await createPlayer();
    final native = player.platform as NativePlayer;
    final tracks = waitFor(
      player.stream.tracks,
      (tracks) => tracks.subtitle.length > 2,
    );
    await player.open(Media(TestMedia.chapters), play: false);
    final loaded = await tracks;
    expect(await native.getProperty('chapter-list/count'), '3');
    expect(await native.getProperty('chapter-list/1/title'), 'Two');
    expect(double.parse(await native.getProperty('chapter-list/2/time')), 4.0);
    expect(
      loaded.audio.skip(2).map((track) => track.language),
      ['eng', 'jpn'],
    );
    expect(loaded.subtitle.skip(2).map((track) => track.language), ['eng']);
  });
  test('fixture-late-keyframe', () async {
    final player = await createPlayer();
    final positions = <Duration>[];
    final subscription = player.stream.position.listen(positions.add);
    addTearDown(subscription.cancel);
    final native = player.platform as NativePlayer;
    final playing = waitFor(
      player.stream.position,
      (position) => position >= const Duration(milliseconds: 500),
      reason: 'position 0.5 s',
    );
    final ended = waitFor(
      player.stream.completed,
      (completed) => completed,
      timeout: const Duration(seconds: 20),
      reason: 'end of file',
    );
    await player.open(Media(TestMedia.lateKeyframe));
    await playing;
    final start = positions.firstWhere((position) => position > Duration.zero);
    expect(
      start < const Duration(seconds: 1) ||
          (start >= const Duration(milliseconds: 7900) &&
              start < const Duration(milliseconds: 8200)),
      isTrue,
      reason:
          'playback starts at 0 or at the first keyframe (8 s), not at $start',
    );
    expect(player.state.duration.inMilliseconds, closeTo(12000, 50));
    expect(await native.getProperty('video-params/w'), '320');
    await ended;
    expect(player.state.position.inMilliseconds, closeTo(12000, 200));
  });
  test('fixture-truncated', () async {
    final player = await createPlayer();
    final ended = waitFor(
      player.stream.completed,
      (completed) => completed,
      timeout: const Duration(seconds: 15),
      reason: 'end of the truncated file',
    );
    await player.open(Media(TestMedia.truncated));
    await ended;
    expect(player.state.position, lessThan(const Duration(seconds: 5)));
  });
  test('fixture-corrupt', () async {
    final player = await createPlayer();
    final error = waitFor(player.stream.error, (_) => true);
    await player.open(Media(TestMedia.corrupt));
    expect(await error, isNotEmpty);
    expect(player.state.completed, isFalse);
  });
}
