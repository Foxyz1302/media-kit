// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/src/video_controller/native_video_controller/real.dart';

const _channel = MethodChannel('com.alexmercerind/media_kit_video');

final _sizes = <String>[];

void _resize(int handle) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _channel.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('VideoOutput.Resize', {
        'handle': handle,
        'id': handle,
        'rect': {'left': 0, 'top': 0, 'width': 1, 'height': 1},
      }),
    ),
    (_) {},
  );
}

Future<NativeVideoController> _create(
  Player player, {
  int? width,
  int? height,
}) async {
  final controller = await NativeVideoController.create(
    player,
    VideoControllerConfiguration(hwdec: 'no', width: width, height: height),
  );
  return controller as NativeVideoController;
}

Future<void> _videoParams(
  Player player,
  NativeVideoController controller,
  int dw,
  int dh, {
  int rotate = 0,
}) async {
  player.platform!.videoParamsController.add(
    VideoParams(dw: dw, dh: dh, rotate: rotate),
  );
  await Future<void>.delayed(Duration.zero);
  await controller.lock.synchronized(() async {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUp(() {
    _sizes.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'VideoOutputManager.Create':
          final handle = int.parse(call.arguments['handle']);
          scheduleMicrotask(() => _resize(handle));
        case 'VideoOutputManager.SetSize':
          _sizes.add('${call.arguments['width']}x${call.arguments['height']}');
      }
      return null;
    });
  });

  test('without a set size, each file sends its video size', () async {
    final player = Player();
    final controller = await _create(player);
    await _videoParams(player, controller, 1920, 1080);
    await _videoParams(player, controller, 1920, 1080);
    await _videoParams(player, controller, 1280, 720, rotate: 90);
    expect(_sizes, ['1920x1080', '720x1280']);
    await player.dispose();
  });

  test('a size set with setSize stays across files', () async {
    final player = Player();
    final controller = await _create(player);
    await _videoParams(player, controller, 1920, 1080);
    await controller.setSize(width: 3840, height: 2160);
    await _videoParams(player, controller, 1280, 720);
    await _videoParams(player, controller, 2560, 1440);
    expect(_sizes, ['1920x1080', '3840x2160']);
    await controller.setSize();
    await _videoParams(player, controller, 1920, 1080);
    expect(_sizes, ['1920x1080', '3840x2160', '2560x1440', '1920x1080']);
    await player.dispose();
  });

  test('a size from the configuration stays across files', () async {
    final player = Player();
    final controller = await _create(player, width: 1280, height: 720);
    await _videoParams(player, controller, 1920, 1080);
    await _videoParams(player, controller, 640, 360);
    expect(_sizes, isEmpty);
    await player.dispose();
  });
}
