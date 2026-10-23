@TestOn('linux')
@Tags(['headless'])
library;

import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:test/test.dart';

import '../common/media_server.dart';
import '../common/players.dart';
import '../common/test_media.dart';
import '../common/waits.dart';

void main() {
  late MediaServer server;

  setUpAll(setUpHeadless);
  setUp(() async {
    server = await MediaServer.start();
  });
  tearDown(() async {
    await server.close();
  });

  List<String> errorsOf(Player player) {
    final errors = <String>[];
    final subscription = player.stream.error.listen(errors.add);
    addTearDown(subscription.cancel);
    return errors;
  }

  Future<void> expectPlaysToEnd(Faults faults, String cause) async {
    final url = server.serveFile(
      '/stream.mp4',
      TestMedia.stream,
      faults: faults,
    );
    final player = await createPlayer();
    final errors = errorsOf(player);
    final completed = waitFor(
      player.stream.completed,
      (completed) => completed,
      timeout: const Duration(seconds: 45),
      reason: 'completed',
    );
    await player.open(Media('$url'));
    await completed;
    expect(
      player.state.position,
      greaterThan(const Duration(milliseconds: 8500)),
      reason:
          'completed at ${player.state.position} of 10 s after $cause. Errors: $errors. Requests: ${server.requests}',
    );
  }

  final starts = <String, Faults>{
    'direct': const Faults(),
    'latency': const Faults(latency: Duration(milliseconds: 300)),
    'slow-headers': const Faults(headerDelay: Duration(milliseconds: 150)),
    'throttled': const Faults(bytesPerSecond: 250000),
  };
  for (final entry in starts.entries) {
    test('stream-start-latency-${entry.key}', () async {
      final url = server.serveFile(
        '/stream.mp4',
        TestMedia.stream,
        faults: entry.value,
      );
      final player = await createPlayer();
      final clock = Stopwatch()..start();
      final playing = waitFor(
        player.stream.position,
        (position) => position > Duration.zero,
        reason: 'first position',
      );
      await player.open(
        Media('$url', httpHeaders: {'X-Media-Kit-Test': entry.key}),
      );
      final opened = clock.elapsed;
      await playing;
      final started = clock.elapsed;
      print(
        'stream-start-latency-${entry.key}: open() ${opened.inMilliseconds} ms, first position ${started.inMilliseconds} ms',
      );
      expect(started, lessThan(const Duration(seconds: 5)));
      final requests = server.requestsFor('/stream.mp4');
      expect(requests, isNotEmpty);
      expect(requests.first.headers['x-media-kit-test'], entry.key);
    });
  }
  test('stream-mid-stream-disconnect-recovers', () async {
    final size = File(TestMedia.stream).lengthSync();
    await expectPlaysToEnd(
      Faults(
          bytesPerSecond: 300000, dropAfterBytes: size * 4 ~/ 10, requests: 1),
      'the connection dropped at 40%',
    );
    expect(
      server.requestsFor('/stream.mp4').map((request) => request.start),
      [0, size * 4 ~/ 10],
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
  test('stream-stall-recovers', () async {
    final size = File(TestMedia.stream).lengthSync();
    await expectPlaysToEnd(
      Faults(
        bytesPerSecond: 300000,
        stallAfterBytes: size * 4 ~/ 10,
        stallFor: const Duration(seconds: 10),
        requests: 1,
      ),
      'a 10 s stall at 40%',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
  test('stream-outage-is-an-error-not-completed', () async {
    final size = File(TestMedia.stream).lengthSync();
    final url = server.serveFile(
      '/stream.mp4',
      TestMedia.stream,
      faults: Faults(
        bytesPerSecond: 300000,
        dropAfterBytes: size * 4 ~/ 10,
        requests: 1,
        then: const Faults(status: 503),
      ),
    );
    final player = await createPlayer();
    final errors = errorsOf(player);
    await player.open(Media('$url'));
    await waitUntil(
      () => errors.isNotEmpty || player.state.completed,
      timeout: const Duration(seconds: 45),
      reason: 'an error or the end',
    );
    await Future.delayed(const Duration(seconds: 1));
    expect(
      player.state.completed,
      isFalse,
      reason:
          'completed at ${player.state.position} of 10 s although every reconnect failed with 503 (P1-C5, P1-N1). Errors: $errors',
    );
    expect(errors, isNotEmpty, reason: 'the failed reconnects raised no error');
  }, tags: 'known-failing', timeout: const Timeout(Duration(minutes: 1)));
  for (final status in [403, 404, 500]) {
    test('stream-http-$status', () async {
      final url = server.fail('/stream.mp4', status);
      final player = await createPlayer();
      final errors = errorsOf(player);
      final completed = <bool>[];
      final completions = player.stream.completed.listen(completed.add);
      addTearDown(completions.cancel);
      await player.open(Media('$url'));
      await waitUntil(() => errors.isNotEmpty, reason: 'an error');
      await Future.delayed(const Duration(seconds: 1));
      expect(errors, hasLength(1));
      expect(completed, isNot(contains(true)));
    });
  }
  test('stream-http-error-stops-playing', () async {
    final url = server.fail('/stream.mp4', 404);
    final player = await createPlayer();
    final errors = errorsOf(player);
    await player.open(Media('$url'));
    await waitUntil(() => errors.isNotEmpty, reason: 'an error');
    await Future.delayed(const Duration(seconds: 1));
    expect(
      player.state.playing,
      isFalse,
      reason:
          'open() set playing optimistically and the failed load never reset it (P1-C5, #1421)',
    );
  }, tags: 'known-failing');
  test('stream-corrupt', () async {
    final url = server.serveFile('/corrupt.mp4', TestMedia.corrupt);
    final player = await createPlayer();
    final errors = errorsOf(player);
    await player.open(Media('$url'));
    await waitUntil(() => errors.isNotEmpty, reason: 'an error');
    await Future.delayed(const Duration(seconds: 1));
    expect(errors, hasLength(1));
    expect(player.state.completed, isFalse);
  });
}
