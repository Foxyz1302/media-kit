import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

/// Root directory of package:media_kit.
Future<String> packageRoot() async {
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:media_kit/media_kit.dart'),
  );
  return path.dirname(path.dirname(library!.toFilePath()));
}

/// {@template test_media}
///
/// TestMedia
/// ---------
/// Media fixtures written by `tool/gen_test_media.sh`.
///
/// [ensure] generates them on first use into `$TMPDIR/media_kit_test_media/<script hash>`,
/// or into `$MEDIA_KIT_TEST_MEDIA_DIR` when that is set. Needs `bash` and `ffmpeg` on the `PATH`.
///
/// {@endtemplate}
abstract class TestMedia {
  /// H.264/AAC, 320x240 at 30 fps, 6 s, 1 s GOP.
  static String get h264 => _file('h264.mp4');

  /// HEVC/AAC, 320x240 at 30 fps, 6 s, 1 s GOP.
  static String get hevc => _file('hevc.mp4');

  /// VP9/Opus, 320x240 at 30 fps, 6 s, 1 s GOP.
  static String get vp9 => _file('vp9.webm');

  /// AV1/AAC, 320x240 at 30 fps, 6 s, 1 s GOP.
  static String get av1 => _file('av1.mp4');

  /// AAC only, 6 s.
  static String get audio => _file('audio.m4a');

  /// H.264 with chapters at 0, 2 and 4 s, two AAC tracks (eng, jpn) and an English SRT track, 6 s.
  static String get chapters => _file('chapters.mkv');

  /// H.264/AAC, 12 s, whose video starts with non-keyframes: the first keyframe is at 8 s.
  static String get lateKeyframe => _file('late_keyframe.mp4');

  /// The first 45% of [h264]: an intact header, then the media data ends abruptly.
  static String get truncated => _file('truncated.mp4');

  /// 64 KiB of noise named `.mp4`.
  static String get corrupt => _file('corrupt.mp4');

  /// H.264/AAC, 640x360 at 30 fps, 10 s, about 1 MB, for HTTP streaming.
  static String get stream => _file('stream.mp4');

  /// H.264/AAC, 1280x720 at 60 fps, 4 s, for the event-path benchmark.
  static String get bench720p60 => _file('bench_720p60.mp4');

  /// Directory holding the fixtures.
  static String get directory => _directory;

  /// Generates the fixtures unless they exist already.
  static Future<void> ensure() => _ensured ??= _ensure();

  static String _file(String name) {
    if (_ensured == null) {
      throw StateError('TestMedia.ensure must complete before using fixtures.');
    }
    return path.join(_directory, name);
  }

  static Future<void> _ensure() async {
    final script = path.join(await packageRoot(), 'tool', 'gen_test_media.sh');
    final override = Platform.environment['MEDIA_KIT_TEST_MEDIA_DIR'];
    _directory = override ??
        path.join(
          Directory.systemTemp.path,
          'media_kit_test_media',
          _fnv1a(File(script).readAsBytesSync()).toRadixString(16),
        );
    if (File(path.join(_directory, _last)).existsSync()) {
      return;
    }
    final staging =
        Directory('$_directory.$pid.${DateTime.now().microsecondsSinceEpoch}');
    try {
      final result = await Process.run('bash', [script, staging.path]);
      if (result.exitCode != 0) {
        throw StateError(
          'tool/gen_test_media.sh failed with exit code ${result.exitCode}:\n${result.stdout}${result.stderr}',
        );
      }
      if (override != null) {
        Directory(_directory).createSync(recursive: true);
        for (final entity in staging.listSync()) {
          entity.renameSync(path.join(_directory, path.basename(entity.path)));
        }
      } else {
        try {
          staging.renameSync(_directory);
        } on FileSystemException {
          if (!File(path.join(_directory, _last)).existsSync()) {
            rethrow;
          }
        }
      }
    } finally {
      if (staging.existsSync()) {
        staging.deleteSync(recursive: true);
      }
    }
  }

  static int _fnv1a(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  static const String _last = 'bench_720p60.mp4';

  static String _directory = '';

  static Future<void>? _ensured;
}
