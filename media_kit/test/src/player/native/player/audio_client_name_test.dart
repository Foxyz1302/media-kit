import 'dart:io';

import 'package:media_kit/src/media_kit.dart';
import 'package:media_kit/src/player/native/player/player.dart';
import 'package:media_kit/src/player/platform_player.dart';
import 'package:media_kit/src/player/player.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';
import 'package:universal_platform/universal_platform.dart';

void main() {
  setUp(() {
    MediaKit.ensureInitialized();
    // For preventing video driver & audio driver initialization errors in unit-tests.
    NativePlayer.test = true;
  });

  Future<String> audioClientName(Player player) async {
    final platform = player.platform as NativePlayer;
    await platform.waitForPlayerInitialization;
    return platform.getProperty('audio-client-name');
  }

  test('player-audio-client-name-defaults-to-executable-name', () async {
    final player = Player();
    addTearDown(player.dispose);
    expect(
      await audioClientName(player),
      basenameWithoutExtension(Platform.resolvedExecutable),
    );
  }, skip: UniversalPlatform.isWeb || !(Platform.isWindows || Platform.isLinux || Platform.isMacOS));

  test('player-audio-client-name-configuration-override', () async {
    final player = Player(
      configuration: const PlayerConfiguration(audioClientName: 'media_kit_test_app'),
    );
    addTearDown(player.dispose);
    expect(await audioClientName(player), 'media_kit_test_app');
  }, skip: UniversalPlatform.isWeb);

  test('player-audio-client-name-empty-keeps-mpv-default', () async {
    final player = Player(
      configuration: const PlayerConfiguration(audioClientName: ''),
    );
    addTearDown(player.dispose);
    expect(await audioClientName(player), 'mpv');
  }, skip: UniversalPlatform.isWeb);
}
