import 'dart:async';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:test/test.dart';

import 'headless.dart';
import 'test_media.dart';

/// Initializes media_kit for headless tests and generates the [TestMedia] fixtures.
Future<void> setUpHeadless() async {
  initializeHeadless();
  await TestMedia.ensure();
}

/// Creates a CPU-decoding [Player] that [releasePlayer] disposes after the current test.
Future<Player> createPlayer({
  PlayerConfiguration configuration = const PlayerConfiguration(),
}) async {
  final player = trackPlayer(Player(configuration: configuration));
  await forceSoftwareDecoding(player);
  return player;
}

/// Makes [releasePlayer] dispose [player] after the current test.
Player trackPlayer(Player player) {
  _live.add(player);
  addTearDown(() => releasePlayer(player));
  return player;
}

/// Disposes [player] unless it was released already.
///
/// An earlier `dispose` by the test itself is tolerated. A dispose that does not
/// finish within [timeout] fails the test, after the player's wakeup callback is
/// cleared: libmpv calling into the test isolate after it shut down would abort
/// the whole test process (#1348).
Future<void> releasePlayer(
  Player player, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (!_live.remove(player)) {
    return;
  }
  try {
    await player.dispose().timeout(timeout);
  } on TimeoutException {
    await _neutralise(player);
    fail('Player.dispose did not finish within $timeout');
  } on AssertionError catch (_) {}
}

Future<void> _neutralise(Player player) async {
  final handle = await player.handle.timeout(
    const Duration(seconds: 1),
    onTimeout: () => 0,
  );
  if (handle == 0) {
    return;
  }
  final mpv = generated.MPV(DynamicLibrary.open(NativeLibrary.path));
  final ctx = Pointer<generated.mpv_handle>.fromAddress(handle);
  mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);
  final quit = 'quit'.toNativeUtf8();
  mpv.mpv_command_string(ctx, quit.cast());
  calloc.free(quit);
}

final Set<Player> _live = <Player>{};
