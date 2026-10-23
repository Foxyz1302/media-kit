/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/src/utils/query_decoders.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';
import 'package:synchronized/synchronized.dart';

/// {@template native_video_controller}
///
/// NativeVideoController
/// ---------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on:
/// * Windows
/// * GNU/Linux
/// * macOS
/// * iOS
///
/// {@endtemplate}
class NativeVideoController extends PlatformVideoController {
  /// Whether [NativeVideoController] is supported on the current platform or not.
  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  /// Width of the video (from [VideoParams]).
  int? videoParamsWidth;

  /// Height of the video (from [VideoParams]).
  int? videoParamsHeight;

  /// [Lock] used to synchronize [onLoadHooks], [onUnloadHooks] & [subscription].
  final lock = Lock();

  var _disposed = false;

  /// How long the views' sizes stay unchanged before the output follows them
  /// ([VideoControllerConfiguration.renderAtWidgetSize]).
  static const settleDelay = Duration(milliseconds: 120);

  /// The views showing this output, from [setViewSize].
  final _views =
      HashMap<Object, ({Size size, BoxFit fit, double? aspectRatio})>();

  /// Fits the output to [_views] once their sizes have settled.
  Timer? _settle;

  /// The size last sent to the native output.
  (int?, int?)? _sent;

  /// Whether the native output renders on a GPU, as `VideoOutputManager.Create` answers. Where it doesn't
  /// say, H/W rendering is taken for GPU rendering.
  late var _gpu = configuration.enableHardwareAcceleration;

  /// Whether the output follows [_views]: on GNU/Linux & Windows per
  /// [VideoControllerConfiguration.renderAtWidgetSize] (by default on GNU/Linux only), rendering on a GPU,
  /// without a size set.
  bool get _followsViews =>
      (Platform.isLinux || Platform.isWindows) &&
      (configuration.renderAtWidgetSize ?? Platform.isLinux) &&
      _gpu &&
      (width == null || height == null);

  NativePlayer get platform => player.platform as NativePlayer;

  Future<void> setProperty(String key, String value) async {
    await platform.setProperty(key, value, waitForInitialization: false);
  }

  Future<void> setProperties(Map<String, String> properties) async {
    // ORDER IS IMPORTANT.
    for (final entry in properties.entries) {
      await setProperty(entry.key, entry.value);
    }
  }

  /// [StreamSubscription] for listening to video [Rect].
  StreamSubscription<VideoParams>? videoParamsSubscription;

  /// {@macro native_video_controller}
  NativeVideoController._(super.player, super.configuration)
      : width = configuration.width,
        height = configuration.height {
    if (width != null && height != null) {
      _sent = (width, height);
    }
    videoParamsSubscription = player.stream.videoParams.listen(
      (event) => lock.synchronized(() async {
        if (_disposed || [0, null].contains(event.dw) || [0, null].contains(event.dh)) {
          return;
        }

        final int width;
        final int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        if (_disposed || videoParamsWidth == width && videoParamsHeight == height) {
          return;
        }

        videoParamsWidth = width;
        videoParamsHeight = height;

        // A size set through the configuration or [setSize] stays across files.
        if (this.width != null && this.height != null) {
          return;
        }

        final fitted = _followsViews ? _fitToViews() : null;
        await _sendSize(fitted?.$1 ?? width, fitted?.$2 ?? height);
      }),
    );
  }

  /// {@macro native_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Update [configuration] to have default values.
    configuration = configuration.copyWith(
      vo: configuration.vo ?? 'libmpv',
      hwdec: configuration.hwdec ?? 'auto',
    );

    // Retrieve the native handle of the [Player].
    final handle = await player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // In case no video-decoders are found, this means media_kit_libs_***_audio is being used.
    // Thus, --vid=no is required to prevent libmpv from trying to decode video (otherwise bad things may happen).
    //
    // Search for common H264 decoder to check if video support is available.
    final decoders = await queryDecoders(handle);
    if (!decoders.contains('h264')) {
      throw UnsupportedError(
        '[VideoController] is not available.'
        ' '
        'Please use media_kit_libs_***_video instead of media_kit_libs_***_audio.',
      );
    }

    // Creation:
    final controller = NativeVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.platform?.release.add(controller._dispose);

    // Store the [NativeVideoController] in the [_controllers].
    _controllers[handle] = controller;

    await controller.setProperties({
      'vo': configuration.vo!,
      'hwdec': configuration.hwdec!,
      'vid': 'auto',
    });

    // Wait until first texture ID is received.
    // We are not waiting on the native-side itself because it will block the UI thread.
    final completer = Completer<void>();
    void listener() {
      final value = controller.id.value;
      if (value != null) {
        debugPrint('NativeVideoController: Texture ID: $value');
        completer.complete();
      }
    }

    controller.id.addListener(listener);

    final created = await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
      'configuration': {
        'width': configuration.width.toString(),
        'height': configuration.height.toString(),
        'enableHardwareAcceleration': configuration.enableHardwareAcceleration,
      },
    });
    if (created case {'gpu': final bool gpu}) {
      controller._gpu = gpu;
    }

    await completer.future;
    controller.id.removeListener(listener);

    // Return the [VideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({int? width, int? height}) async {
    await player.handle;
    if (this.width == width && this.height == height) {
      // No need to resize if the requested size is same as the current size.
      return;
    }
    if (width != null && height != null) {
      this.width = width;
      this.height = height;
      await lock.synchronized(() => _sendSize(width, height));
    } else {
      this.width = null;
      this.height = null;
      await lock.synchronized(() {
        final fitted = _followsViews ? _fitToViews() : null;
        return _sendSize(
          fitted?.$1 ?? videoParamsWidth,
          fitted?.$2 ?? videoParamsHeight,
        );
      });
    }
  }

  @override
  void setViewSize(
    Object view,
    Size? size, {
    BoxFit fit = BoxFit.contain,
    double? aspectRatio,
  }) {
    if (_disposed) {
      return;
    }
    if (size == null || size.isEmpty || !size.isFinite) {
      _views.remove(view);
    } else {
      _views[view] = (size: size, fit: fit, aspectRatio: aspectRatio);
    }
    if (!_followsViews) {
      return;
    }
    _settle?.cancel();
    _settle = Timer(
      settleDelay,
      () => lock.synchronized(() async {
        if (_disposed || !_followsViews) {
          return;
        }
        final fitted = _fitToViews();
        if (fitted != null) {
          await _sendSize(fitted.$1, fitted.$2);
        }
      }),
    );
  }

  /// The size the output follows [_views] at, the largest any of them needs; the video's own size when one
  /// shows it at that ([outputSizeFor]); null without a view or a video.
  (int, int)? _fitToViews() {
    final videoWidth = videoParamsWidth;
    final videoHeight = videoParamsHeight;
    if (videoWidth == null || videoHeight == null || videoWidth <= 0 || videoHeight <= 0 || _views.isEmpty) {
      return null;
    }
    final display = _displaySize();
    (int, int)? largest;
    for (final view in _views.values) {
      final size = outputSizeFor(
        videoWidth,
        videoHeight,
        view.size,
        fit: view.fit,
        aspectRatio: view.aspectRatio,
        display: display,
      );
      if (size == null) {
        return (videoWidth, videoHeight);
      }
      if (largest == null || size.$1 * size.$2 > largest.$1 * largest.$2) {
        largest = size;
      }
    }
    return largest;
  }

  Future<void> _sendSize(int? width, int? height) async {
    if (_disposed || _sent == (width, height)) {
      return;
    }
    _sent = (width, height);
    final handle = await player.handle;
    await _channel.invokeMethod('VideoOutputManager.SetSize', {
      'handle': handle.toString(),
      'width': width?.toString() ?? 'null',
      'height': height?.toString() ?? 'null',
    });
  }

  /// The longer & shorter side of the largest display, in physical pixels; the largest view's when the
  /// embedder reports no display.
  static (double, double)? _displaySize() {
    try {
      var long = 0.0;
      var short = 0.0;
      final dispatcher = ServicesBinding.instance.platformDispatcher;
      for (final display in dispatcher.displays) {
        // GTK gives a monitor's size in its scaled pixels.
        final scale = Platform.isLinux ? display.devicePixelRatio : 1.0;
        final size = display.size * scale;
        long = math.max(long, size.longestSide);
        short = math.max(short, size.shortestSide);
      }
      if (long <= 0 || short <= 0) {
        for (final view in dispatcher.views) {
          long = math.max(long, view.physicalSize.longestSide);
          short = math.max(short, view.physicalSize.shortestSide);
        }
      }
      return long > 0 && short > 0 ? (long, short) : null;
    } catch (exception, stacktrace) {
      debugPrint(exception.toString());
      debugPrint(stacktrace.toString());
      return null;
    }
  }

  /// The output size for a [videoWidth] x [videoHeight] video that a view of [view] physical pixels shows
  /// with [fit] (& [aspectRatio], when given), on displays whose largest is [display] (its longer & shorter
  /// side, in physical pixels). Null for [BoxFit.none] & [BoxFit.scaleDown], which show the output at its
  /// own size.
  ///
  /// The output has the video's aspect ratio & the size of the picture on screen, without letterbox. When
  /// the picture maps 1:1 to the view's pixels, the side that meets the view's edges is the view's & the
  /// other keeps the view's parity, so a centred picture sits on whole pixels. The size never exceeds
  /// [display], & never goes below the video's own size unless the view shows the video smaller.
  static (int, int)? outputSizeFor(
    int videoWidth,
    int videoHeight,
    Size view, {
    BoxFit fit = BoxFit.contain,
    double? aspectRatio,
    (double, double)? display,
  }) {
    if (fit == BoxFit.none || fit == BoxFit.scaleDown || videoWidth <= 0 || videoHeight <= 0 || view.isEmpty) {
      return null;
    }
    final aspect = videoWidth / videoHeight;
    final shown = aspectRatio ?? aspect;
    final viewWidth = math.max(1, view.width.round());
    final viewHeight = math.max(1, view.height.round());
    final wider = viewWidth / viewHeight > shown;
    // Whether the picture's height is the view's (else its width is).
    final heightFits = switch (fit) {
      BoxFit.contain => wider,
      BoxFit.cover => !wider,
      BoxFit.fitHeight => true,
      _ => false,
    };
    // The picture's size on screen; [BoxFit.fill] stretches it to the view.
    final double shownWidth;
    final double shownHeight;
    if (fit == BoxFit.fill) {
      shownWidth = viewWidth.toDouble();
      shownHeight = viewHeight.toDouble();
    } else if (heightFits) {
      shownWidth = viewHeight * shown;
      shownHeight = viewHeight.toDouble();
    } else {
      shownWidth = viewWidth.toDouble();
      shownHeight = viewWidth / shown;
    }
    final scale = math.max(shownWidth / videoWidth, shownHeight / videoHeight);
    var limited = scale;
    if (display != null) {
      limited = math.min(
        limited,
        math.min(
          display.$1 / math.max(videoWidth, videoHeight),
          display.$2 / math.min(videoWidth, videoHeight),
        ),
      );
    }
    limited = math.max(limited, math.min(1.0, scale));
    if (limited == 1.0) {
      return (videoWidth, videoHeight);
    }
    if (limited != scale || aspectRatio != null || fit == BoxFit.fill) {
      return (
        math.max(1, (videoWidth * limited).round()),
        math.max(1, (videoHeight * limited).round()),
      );
    }
    // The integer nearest to [x] whose difference to [full] is even.
    int even(double x, int full) => math.max(1, full - 2 * ((full - x) / 2).round());
    return heightFits
        ? (even(viewHeight * aspect, viewWidth), viewHeight)
        : (viewWidth, even(viewWidth / aspect, viewHeight));
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    _disposed = true;
    _settle?.cancel();
    _views.clear();
    super.dispose();
    await videoParamsSubscription?.cancel();
    final handle = await player.handle;
    _controllers.remove(handle);
    await _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
  }

  /// Currently created [NativeVideoController]s.
  /// This is used to notify about updated texture IDs & [Rect]s through [_channel].
  static final _controllers = HashMap<int, NativeVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler((MethodCall call) async {
          try {
            debugPrint(call.method.toString());
            debugPrint(call.arguments.toString());
            switch (call.method) {
              case 'VideoOutput.Resize':
                {
                  // Notify about updated texture ID & [Rect].
                  final int handle = call.arguments['handle'];
                  final Rect rect = Rect.fromLTWH(
                    call.arguments['rect']['left'] * 1.0,
                    call.arguments['rect']['top'] * 1.0,
                    call.arguments['rect']['width'] * 1.0,
                    call.arguments['rect']['height'] * 1.0,
                  );
                  final int id = call.arguments['id'];
                  _controllers[handle]?.rect.value = rect;
                  _controllers[handle]?.id.value = id;
                  // Notify about the first frame being rendered.
                  if (rect.width > 0 && rect.height > 0) {
                    final completer = _controllers[handle]
                        ?.waitUntilFirstFrameRenderedCompleter;
                    if (!(completer?.isCompleted ?? true)) {
                      completer?.complete();
                    }
                  }
                  break;
                }
              default:
                {
                  break;
                }
            }
          } catch (exception, stacktrace) {
            debugPrint(exception.toString());
            debugPrint(stacktrace.toString());
          }
        });
}
