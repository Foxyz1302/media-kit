import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/real.dart';

typedef _View = ({Size size, BoxFit fit, double? aspectRatio});

_View _view(double width, double height, [BoxFit fit = BoxFit.contain]) =>
    (size: Size(width, height), fit: fit, aspectRatio: null);

void main() {
  const cap4k = (width: 2168, height: 1220);
  const cap1080 = (width: 1920, height: 1080);

  group('AndroidVideoController.viewSurfaceSizeFor', () {
    test('a 4K video in a small view renders at the view size', () {
      expect(
        AndroidVideoController.viewSurfaceSizeFor(3840, 2160, [_view(366, 206)], cap4k),
        (width: 366, height: 206),
      );
    });

    test('a 4K video full screen in portrait renders at the picture size', () {
      expect(
        AndroidVideoController.viewSurfaceSizeFor(3840, 2160, [_view(1220, 2712)], cap4k),
        (width: 1220, height: 686),
      );
    });

    test('never above the video size within the display', () {
      expect(
        AndroidVideoController.viewSurfaceSizeFor(1920, 1080, [_view(2712, 1220)], cap1080),
        cap1080,
      );
      expect(
        AndroidVideoController.viewSurfaceSizeFor(3840, 2160, [_view(2712, 1220)], cap4k),
        cap4k,
      );
    });

    test('the largest view wins; none or scaleDown keep the cap', () {
      expect(
        AndroidVideoController.viewSurfaceSizeFor(
          3840,
          2160,
          [_view(366, 206), _view(1220, 2712)],
          cap4k,
        ),
        (width: 1220, height: 686),
      );
      expect(
        AndroidVideoController.viewSurfaceSizeFor(
          3840,
          2160,
          [_view(366, 206), _view(366, 206, BoxFit.scaleDown)],
          cap4k,
        ),
        cap4k,
      );
    });

    test('no view keeps the cap', () {
      expect(AndroidVideoController.viewSurfaceSizeFor(3840, 2160, [], cap4k), cap4k);
    });
  });
}
