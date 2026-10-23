/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/src/video_controller/video_controller.dart';

/// {@template platform_video_controller}
///
/// PlatformVideoController
/// -----------------------
///
/// This class provides the interface for platform specific [VideoController] implementations.
/// The platform specific implementations are expected to implement the methods accordingly.
///
/// The subclasses are then used in composition with the [VideoController] class, based on the platform the application is running on.
///
/// {@endtemplate}
abstract class PlatformVideoController {
  /// The [Player] instance associated with this instance.
  final Player player;

  /// User defined configuration for [VideoController].
  final VideoControllerConfiguration configuration;

  /// Texture ID of the video output, registered with Flutter engine by the native implementation.
  final ValueNotifier<int?> id = ValueNotifier<int?>(null);

  /// [Rect] of the video output, received from the native implementation.
  final ValueNotifier<Rect?> rect = ValueNotifier<Rect?>(null);

  /// {@macro platform_video_controller}
  PlatformVideoController(this.player, this.configuration);

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  Future<void> setSize({int? width, int? height});

  /// Receives the physical [size] at which [view] shows the video output, with its [fit] & [aspectRatio],
  /// or null once it no longer does. See [VideoController.setViewSize].
  void setViewSize(
    Object view,
    Size? size, {
    BoxFit fit = BoxFit.contain,
    double? aspectRatio,
  }) {}

  /// A [Future] that completes when the first video frame has been rendered.
  Future<void> get waitUntilFirstFrameRendered =>
      waitUntilFirstFrameRenderedCompleter.future;

  /// [Completer] used to signal the decoding & rendering of the first video frame.
  /// Use [waitUntilFirstFrameRendered] to wait for the first frame to be rendered.
  @protected
  final waitUntilFirstFrameRenderedCompleter = Completer<void>();

  void dispose() {
    id.dispose();
    rect.dispose();
  }
}

/// {@template video_controller_configuration}
///
/// VideoControllerConfiguration
/// ----------------------------
/// Configurable options for customizing the [VideoController] behavior.
///
/// {@endtemplate}
class VideoControllerConfiguration {
  /// Sets the [`--vo`](https://mpv.io/manual/stable/#options-vo) property on native backend.
  ///
  /// Default: Platform specific.
  /// * Windows, GNU/Linux, macOS & iOS: `libmpv`
  /// * Android: `gpu`
  final String? vo;

  /// Sets the [`--hwdec`](https://mpv.io/manual/stable/#options-hwdec) property on native backend.
  ///
  /// Default: Platform specific.
  /// * Windows, GNU/Linux, macOS & iOS : `auto`
  /// * Android: `mediacodec,mediacodec-copy`
  final String? hwdec;

  /// The scale for the video output.
  /// This may be used for performance reasons. Specifying this option will cause [width] & [height] to be ignored.
  ///
  /// Default: `1.0`
  final double scale;

  /// The fixed width for the video output.
  /// This may be used for performance reasons.
  ///
  /// Default: `null`
  final int? width;

  /// The fixed height for the video output.
  /// This may be used for performance reasons.
  ///
  /// Default: `null`
  final int? height;

  /// Whether to enable hardware acceleration.
  ///
  /// DO NOT DISABLE THIS OPTION MEANINGLESSLY.
  /// THE BATTERY WILL DRAIN, THE DEVICE MAY HEAT UP & CPU USAGE WILL BE HIGH.
  ///
  /// Default: `true`
  final bool enableHardwareAcceleration;

  /// Whether to attach `android.view.Surface` after video parameters are known.
  ///
  /// Default:
  /// * [vo] == gpu : `true`
  /// * [vo] != gpu : `false`
  final bool? androidAttachSurfaceAfterVideoParameters;

  /// Whether the video output is rendered at the size the `Video` widget shows the picture at, in physical
  /// pixels, instead of at the video's own size. mpv then scales the picture & libass draws subtitles at
  /// the screen's resolution, rather than Flutter stretching a texture of the video's size.
  ///
  /// The size is applied once a resize has settled, never on every frame of a window drag. It stays within
  /// the display's physical size & never goes below the video's own size, unless the widget shows the
  /// video smaller than that.
  ///
  /// Applies on GNU/Linux & Windows, when the video renders on a GPU & while no [width] & [height] are set,
  /// here or through [VideoController.setSize]. `true` or `false` sets it; `null` leaves it to the platform.
  ///
  /// Default (`null`):
  /// * GNU/Linux : on
  /// * Windows : off, since a resize there still replaces the texture (a blank frame) & waits for mpv's
  ///   next frame
  final bool? renderAtWidgetSize;

  /// {@macro video_controller_configuration}
  const VideoControllerConfiguration({
    this.vo,
    this.hwdec,
    this.width,
    this.height,
    this.scale = 1.0,
    this.enableHardwareAcceleration = true,
    this.androidAttachSurfaceAfterVideoParameters,
    this.renderAtWidgetSize,
  });

  /// Returns a copy of this class with the given fields replaced by the new values.
  VideoControllerConfiguration copyWith({
    String? vo,
    String? hwdec,
    double? scale,
    int? width,
    int? height,
    bool? enableHardwareAcceleration,
    bool? androidAttachSurfaceAfterVideoParameters,
    bool? renderAtWidgetSize,
  }) =>
      VideoControllerConfiguration(
        vo: vo ?? this.vo,
        hwdec: hwdec ?? this.hwdec,
        scale: scale ?? this.scale,
        width: width ?? this.width,
        height: height ?? this.height,
        enableHardwareAcceleration:
            enableHardwareAcceleration ?? this.enableHardwareAcceleration,
        androidAttachSurfaceAfterVideoParameters:
            androidAttachSurfaceAfterVideoParameters ??
                this.androidAttachSurfaceAfterVideoParameters,
        renderAtWidgetSize: renderAtWidgetSize ?? this.renderAtWidgetSize,
      );
}
