import 'package:media_kit/media_kit.dart';

/// Initializes media_kit with no video and no audio output; video is still decoded.
void initializeHeadless() {
  MediaKit.ensureInitialized();
  NativePlayer.test = true;
}

/// Creates a [Player] that decodes on the CPU only (`hwdec=no`): headless suites never touch the GPU.
Future<Player> headlessPlayer({
  PlayerConfiguration configuration = const PlayerConfiguration(),
}) async {
  final player = Player(configuration: configuration);
  await forceSoftwareDecoding(player);
  return player;
}

/// Sets `hwdec=no` on [player].
Future<void> forceSoftwareDecoding(Player player) {
  return (player.platform as NativePlayer).setProperty('hwdec', 'no');
}
