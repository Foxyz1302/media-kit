// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/src/video_controller/native_video_controller/real.dart';

const _channel = MethodChannel('com.alexmercerind/media_kit_video');

final _sizes = <String>[];

Object? _created;

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
  bool? renderAtWidgetSize,
}) async {
  final controller = await NativeVideoController.create(
    player,
    VideoControllerConfiguration(
      hwdec: 'no',
      width: width,
      height: height,
      renderAtWidgetSize: renderAtWidgetSize,
    ),
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

/// Waits until a size given to [NativeVideoController.setViewSize] has settled & been sent.
Future<void> _settled(NativeVideoController controller) async {
  await Future<void>.delayed(
    NativeVideoController.settleDelay + const Duration(milliseconds: 150),
  );
  await controller.lock.synchronized(() async {});
}

final _view = Object();

void _display(Size size, double devicePixelRatio) {
  final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher;
  for (final display in dispatcher.displays) {
    display.size = size;
    display.devicePixelRatio = devicePixelRatio;
  }
  dispatcher.implicitView?.physicalSize = size * devicePixelRatio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  setUp(() {
    _display(const Size(3840, 2160), 1.0);
    _sizes.clear();
    _created = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'VideoOutputManager.Create':
          final handle = int.parse(call.arguments['handle']);
          scheduleMicrotask(() => _resize(handle));
          return _created;
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

  group('the output follows the view', () {
    test('once its size has settled, not on every change', () async {
      final player = Player();
      final controller = await _create(player);
      await _videoParams(player, controller, 1280, 720);
      for (final width in [640.0, 800.0, 1200.0, 1600.0, 1920.0]) {
        controller.setViewSize(_view, Size(width, 1080));
      }
      expect(_sizes, ['1280x720']);
      await _settled(controller);
      expect(_sizes, ['1280x720', '1920x1080']);
      controller.setViewSize(_view, const Size(1600, 900));
      await Future<void>.delayed(NativeVideoController.settleDelay ~/ 3);
      controller.setViewSize(_view, const Size(1920, 1080));
      await _settled(controller);
      expect(_sizes, ['1280x720', '1920x1080'], reason: 'back where it was');
      await player.dispose();
    });

    test('fitted to the picture, without bars', () async {
      final player = Player();
      final controller = await _create(player);
      await _videoParams(player, controller, 1920, 800);
      controller.setViewSize(_view, const Size(2560, 1440));
      await _settled(controller);
      expect(_sizes.last, '2560x1066');
      await _videoParams(player, controller, 1440, 1080);
      expect(_sizes.last, '1920x1440', reason: 'a new file fits at once');
      await player.dispose();
    });

    test('the largest view wins, and a view that goes away is dropped', () async {
      final player = Player();
      final controller = await _create(player);
      final fullscreen = Object();
      await _videoParams(player, controller, 1280, 720);
      controller.setViewSize(_view, const Size(960, 540));
      controller.setViewSize(fullscreen, const Size(2560, 1440));
      await _settled(controller);
      expect(_sizes.last, '2560x1440');
      controller.setViewSize(fullscreen, null);
      await _settled(controller);
      expect(_sizes.last, '960x540', reason: 'the view shows it smaller');
      controller.setViewSize(_view, null);
      await _settled(controller);
      expect(_sizes.last, '960x540', reason: 'without a view the size stays');
      await player.dispose();
    });

    test('a view that shows the output at its own size keeps the video size', () async {
      final player = Player();
      final controller = await _create(player);
      await _videoParams(player, controller, 1280, 720);
      controller.setViewSize(_view, const Size(2560, 1440), fit: BoxFit.scaleDown);
      await _settled(controller);
      expect(_sizes, ['1280x720']);
      await player.dispose();
    });

    test('a size set with setSize wins, until setSize() hands back', () async {
      final player = Player();
      final controller = await _create(player);
      await _videoParams(player, controller, 1280, 720);
      await controller.setSize(width: 3840, height: 2160);
      controller.setViewSize(_view, const Size(1920, 1080));
      await _settled(controller);
      await _videoParams(player, controller, 640, 360);
      expect(_sizes, ['1280x720', '3840x2160']);
      await controller.setSize();
      expect(_sizes, ['1280x720', '3840x2160', '1920x1080']);
      await player.dispose();
    });

    test('a size from the configuration wins', () async {
      final player = Player();
      final controller = await _create(player, width: 1280, height: 720);
      controller.setViewSize(_view, const Size(1920, 1080));
      await _videoParams(player, controller, 640, 360);
      await _settled(controller);
      expect(_sizes, isEmpty);
      await player.dispose();
    });

    test('not when renderAtWidgetSize is off', () async {
      final player = Player();
      final controller = await _create(player, renderAtWidgetSize: false);
      controller.setViewSize(_view, const Size(1920, 1080));
      await _videoParams(player, controller, 640, 360);
      await _settled(controller);
      expect(_sizes, ['640x360']);
      await player.dispose();
    });

    test('not when the output does not render on a GPU', () async {
      _created = {'gpu': false};
      final player = Player();
      final controller = await _create(player);
      controller.setViewSize(_view, const Size(1920, 1080));
      await _videoParams(player, controller, 640, 360);
      await _settled(controller);
      expect(_sizes, ['640x360']);
      await player.dispose();
    });

    test('within the largest display, in its physical pixels', () async {
      _display(const Size(1280, 720), 2.0);
      final player = Player();
      final controller = await _create(player);
      await _videoParams(player, controller, 1280, 720);
      controller.setViewSize(_view, const Size(3840, 2160));
      await _settled(controller);
      expect(_sizes, ['1280x720', '2560x1440']);
      await player.dispose();
    }, skip: !Platform.isLinux ? 'GTK reports scaled monitor sizes' : false);

    test('nothing is sent once the player is disposed', () async {
      final player = Player();
      final controller = await _create(player);
      await _videoParams(player, controller, 1280, 720);
      controller.setViewSize(_view, const Size(1920, 1080));
      await player.dispose();
      await _settled(controller);
      expect(_sizes, ['1280x720']);
    });
  }, skip: !Platform.isLinux ? 'on by default on GNU/Linux only' : false);

  group('outputSizeFor', () {
    (int, int)? size(
      int width,
      int height,
      double viewWidth,
      double viewHeight, {
      BoxFit fit = BoxFit.contain,
      double? aspectRatio,
      (double, double)? display,
    }) =>
        NativeVideoController.outputSizeFor(
          width,
          height,
          Size(viewWidth, viewHeight),
          fit: fit,
          aspectRatio: aspectRatio,
          display: display,
        );

    test('the picture fitted in the view, without bars', () {
      expect(size(1280, 720, 1920, 1080), (1920, 1080));
      expect(size(1920, 800, 1920, 1080), (1920, 800));
      expect(size(1440, 1080, 1920, 1080), (1440, 1080));
      expect(size(720, 1280, 1920, 1080), (608, 1080));
    });

    test('the side that does not meet the view keeps its parity', () {
      expect(size(1920, 1080, 1000, 700), (1000, 562));
      expect(size(1440, 1080, 1001, 700), (933, 700));
      expect(size(1920, 1080, 1366, 768), (1366, 768));
    });

    test('below the video size only when the view is smaller', () {
      expect(size(3840, 2160, 1920, 1080), (1920, 1080));
      expect(size(3840, 2160, 5000, 2812, display: (1920, 1080)), (3840, 2160));
    });

    test('within the display', () {
      expect(size(1280, 720, 3840, 2160, display: (1920, 1080)), (1920, 1080));
      expect(size(1280, 720, 1920, 1080, display: (2560, 1440)), (1920, 1080));
      expect(size(720, 1280, 2160, 3840, display: (1920, 1080)), (1080, 1920));
    });

    test('other fits', () {
      expect(size(1920, 1080, 1000, 1000, fit: BoxFit.cover), (1778, 1000));
      expect(size(1920, 1080, 1000, 1000, fit: BoxFit.fitWidth), (1000, 562));
      expect(size(1920, 1080, 1000, 1000, fit: BoxFit.fitHeight), (1778, 1000));
      expect(size(1280, 720, 1000, 1000, fit: BoxFit.fill), (1778, 1000));
      expect(size(1280, 720, 1000, 1000, aspectRatio: 1.0), (1778, 1000));
      expect(size(1280, 720, 1920, 1080, fit: BoxFit.none), isNull);
      expect(size(1280, 720, 1920, 1080, fit: BoxFit.scaleDown), isNull);
    });
  });
}
