import 'dart:async';

/// Completes with the first event of [stream] that satisfies [test].
///
/// Subscribes immediately, so call it before triggering the event. Fails with a
/// [TimeoutException] naming [reason] after [timeout], and with a [StateError]
/// if [stream] closes first.
Future<T> waitFor<T>(
  Stream<T> stream,
  bool Function(T value) test, {
  Duration timeout = const Duration(seconds: 10),
  String reason = 'event',
}) {
  return stream.firstWhere(test).timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          '$reason did not arrive within $timeout',
          timeout,
        ),
      );
}

/// Completes once [condition] holds, polling every [interval].
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 20),
  String reason = 'condition',
}) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > timeout) {
      throw TimeoutException('$reason did not hold within $timeout', timeout);
    }
    await Future.delayed(interval);
  }
}

/// Completes with the events [stream] emits during [duration].
Future<List<T>> collect<T>(Stream<T> stream, Duration duration) async {
  final events = <T>[];
  final subscription = stream.listen(events.add);
  await Future.delayed(duration);
  await subscription.cancel();
  return events;
}

/// Runs [action] and returns how long its future took.
Future<Duration> timed(Future<void> Function() action) async {
  final clock = Stopwatch()..start();
  await action();
  return clock.elapsed;
}
