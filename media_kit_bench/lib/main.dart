import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// Automated playback benchmark. The host serves clips and collects results on
// 127.0.0.1:8787 through `adb reverse`; nothing is stored on the device.
//
// Per run: open -> first frame (ttffMs) -> playback actually advancing
// (timeToMotionMs, startStallMs) -> 9 s plain window -> 5 s window with an
// animated controls overlay. The whole matrix runs once in portrait and once
// in landscape (immersive), because landscape has far more pixels to draw.
//
// Narrow the matrix with --dart-define:
//   BENCH_CLIPS=h264_1440p60.mp4,...   BENCH_CONFIGS=mkDefault,native,...
//   BENCH_PASSES=portrait               BENCH_MPV_LOG=v
//   BENCH_TRACE=true  (media_kit runs also report time-pos every 50 ms from
//                      open() and every mpv log line with its offset in ms)
//   BENCH_VIEWS=full,small  (small: the whole run in the corner mini-player rect,
//                      30% of the width; default full)

const _host = 'http://127.0.0.1:8787';
const _allClips = [
  'h264_1080p60.mp4',
  'h264_1440p60.mp4',
  'hevc_1440p60.mp4',
  'vp9_1440p60.webm',
  'av1_1440p60.mp4',
];

// native: better_native_video_player's default hybrid-composition platform view.
// nativeTexture: the user's app settings (texture mode, feed buffering, lightweight inline views),
// applied through the plugin's global config, so it never shares an app launch with `native`.
enum BenchConfig { mkDefault, mkCopy, mkGpuMediacodec, mkEmbed, native, nativeTexture }

const _clipsDefine = String.fromEnvironment('BENCH_CLIPS');
const _configsDefine = String.fromEnvironment('BENCH_CONFIGS');
const _passesDefine = String.fromEnvironment('BENCH_PASSES');
const _mpvLogDefine = String.fromEnvironment('BENCH_MPV_LOG', defaultValue: 'warn');
const _trace = bool.fromEnvironment('BENCH_TRACE');
// BENCH_LINK_TEST=<clip>: before the matrix, time one full GET of that clip so network limits of the
// adb-reverse link can be told apart from decode or render limits.
const _linkTestClip = String.fromEnvironment('BENCH_LINK_TEST');
// BENCH_ANIMATE=mkDefault,nativeTexture: after the overlay window, those configs also run an animated
// window that moves the video between full screen and a corner mini-player, one transition per second.
const _animateDefine = String.fromEnvironment('BENCH_ANIMATE');
const _animatedWindow = Duration(seconds: 6);
// BENCH_CHECKS=true: run the functional regression checks instead of the performance matrix.
const _checks = bool.fromEnvironment('BENCH_CHECKS');
const _liveHlsUrl = String.fromEnvironment('BENCH_LIVE_HLS', defaultValue: '$_host/clips/live.m3u8');
// Local HLS VOD from tool/encode_check_clips.sh by default. Apple's public bipbop master
// (https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8)
// works too, if the phone's own connection loads its variants fast enough.
const _vodHlsUrl = String.fromEnvironment('BENCH_VOD_HLS', defaultValue: '$_host/clips/vod.m3u8');
const _viewsDefine = String.fromEnvironment('BENCH_VIEWS');
const _version = 5;

List<String> _csv(String s) => [for (final e in s.split(',')) if (e.trim().isNotEmpty) e.trim()];

final List<String> _clips = _clipsDefine.isEmpty ? _allClips : _csv(_clipsDefine);
// nativeTexture changes the plugin's global config, so it only runs when asked for explicitly.
final List<BenchConfig> _configs = _configsDefine.isEmpty
    ? [for (final c in BenchConfig.values) if (c != BenchConfig.nativeTexture) c]
    : [for (final n in _csv(_configsDefine)) BenchConfig.values.byName(n)];
final List<String> _passes = _passesDefine.isEmpty ? const ['portrait', 'landscape'] : _csv(_passesDefine);
final MPVLogLevel _mpvLogLevel = MPVLogLevel.values.byName(_mpvLogDefine);
final Set<BenchConfig> _animated = {for (final n in _csv(_animateDefine)) BenchConfig.values.byName(n)};
final List<String> _views = _viewsDefine.isEmpty ? const ['full'] : _csv(_viewsDefine);

const _hostAttachDelay = Duration(seconds: 6);
const _ttffTimeout = Duration(seconds: 20);
const _motionTimeout = Duration(seconds: 20);
const _motionThresholdSeconds = 0.2;
const _plainWindow = Duration(seconds: 9);
const _overlayWindow = Duration(seconds: 5);
const _gap = Duration(seconds: 2);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (_configs.contains(BenchConfig.nativeTexture)) {
    if (_configs.contains(BenchConfig.native)) {
      throw StateError('native and nativeTexture need separate app launches: the plugin config is global');
    }
    // Must be set before any NativeVideoPlayerController is created.
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig(
      androidTextureMode: true,
      androidBufferConfig: NativeVideoPlayerAndroidBufferConfig.feed(),
      lightweightInlineViews: true,
    );
  }
  runApp(const BenchApp());
}

class _FrameSample {
  final int vsyncUs;
  final double buildMs;
  final double rasterMs;
  const _FrameSample(this.vsyncUs, this.buildMs, this.rasterMs);
}

final List<_FrameSample> _frames = [];

void _onTimings(List<ui.FrameTiming> timings) {
  for (final t in timings) {
    _frames.add(_FrameSample(
      t.timestampInMicroseconds(ui.FramePhase.vsyncStart),
      t.buildDuration.inMicroseconds / 1000.0,
      t.rasterDuration.inMicroseconds / 1000.0,
    ));
  }
}

double _pct(List<double> sorted, double p) =>
    sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];

double _avg(List<double> xs) => xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

double _r2(double v) => (v * 100).roundToDouble() / 100;

Map<String, dynamic> _windowStats(int fromUs, int toUs, {double? playedSeconds}) {
  final w = _frames.where((f) => f.vsyncUs >= fromUs && f.vsyncUs < toUs).toList();
  final seconds = (toUs - fromUs) / 1e6;
  final build = w.map((f) => f.buildMs).toList()..sort();
  final raster = w.map((f) => f.rasterMs).toList()..sort();
  return {
    'fromUs': fromUs,
    'toUs': toUs,
    'seconds': _r2(seconds),
    if (playedSeconds != null) 'playbackRate': _r2(playedSeconds / seconds),
    'flutterFrames': w.length,
    'flutterFps': _r2(w.length / seconds),
    'buildAvgMs': _r2(_avg(build)),
    'buildP90Ms': _r2(_pct(build, .9)),
    'buildP99Ms': _r2(_pct(build, .99)),
    'rasterAvgMs': _r2(_avg(raster)),
    'rasterP90Ms': _r2(_pct(raster, .9)),
    'rasterP99Ms': _r2(_pct(raster, .99)),
    'over8ms': w.where((f) => f.buildMs > 8.33 || f.rasterMs > 8.33).length,
    'over16ms': w.where((f) => f.buildMs > 16.67 || f.rasterMs > 16.67).length,
  };
}

/// One animated window: Flutter frame stats plus playback-position samples ([ms into window, seconds]).
class _AnimatedPhase {
  _AnimatedPhase(this.startUs, this.startEpochMs);
  final int startUs;
  final int startEpochMs;
  late int endUs;
  late int endEpochMs;
  final samples = <List<num>>[];

  Map<String, dynamic> stats() {
    var backJumps = 0;
    var maxStallMs = 0;
    var lastAdvanceMs = samples.isEmpty ? 0 : samples.first[0];
    for (var i = 1; i < samples.length; i++) {
      final dp = samples[i][1] - samples[i - 1][1];
      if (dp < -0.05) backJumps++;
      if (dp > 0.001) {
        lastAdvanceMs = samples[i][0];
      } else {
        maxStallMs = math.max(maxStallMs, (samples[i][0] - lastAdvanceMs).toInt());
      }
    }
    final played = samples.length < 2 ? 0.0 : (samples.last[1] - samples.first[1]).toDouble();
    return {
      ..._windowStats(startUs, endUs, playedSeconds: played),
      'startEpochMs': startEpochMs,
      'endEpochMs': endEpochMs,
      'backJumps': backJumps,
      'maxStallMs': maxStallMs,
      'samples': samples,
    };
  }
}

final _http = HttpClient();

/// Whether the engine runs Hybrid Composition++: the EnableHcpp flag, API 34+, Impeller Vulkan and the
/// SurfaceControl swapchain. With it, every platform view create is routed to HCPP.
Future<Object> _hcppActive() async {
  if (!Platform.isAndroid) return false;
  try {
    return await HybridAndroidViewController.checkIfSupported();
  } catch (e, st) {
    debugPrint('HCPP check failed: $e\n$st');
    return 'error: $e';
  }
}

Future<void> _post(Map<String, dynamic> body) async {
  try {
    final req = await _http.postUrl(Uri.parse('$_host/result'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final resp = await req.close();
    await resp.drain<void>();
  } catch (e, st) {
    debugPrint('result post failed: $e\n$st');
  }
}

Future<bool> _waitFor(Future<bool> Function() condition, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: const BenchPage(),
      );
}

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> with TickerProviderStateMixin {
  Widget? _video;
  bool _overlay = false;
  // BENCH_VIEWS=small: the run stays in the mini-player rect and skips the animated window.
  bool _small = false;
  // 0 = full screen, 1 = corner mini-player; driven only during an animated window.
  late final AnimationController _mini = AnimationController(vsync: this, duration: const Duration(seconds: 1));
  String _status = 'waiting for host';

  @override
  void dispose() {
    _mini.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _runAll());
  }

  String _viewSize() {
    final v = WidgetsBinding.instance.platformDispatcher.views.first;
    return '${v.physicalSize.width.toInt()}x${v.physicalSize.height.toInt()}';
  }

  Future<void> _setOrientation(String pass) async {
    if (pass == 'landscape') {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  Future<void> _runAll() async {
    await Future<void>.delayed(_hostAttachDelay);
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final lastVsync = _frames.isEmpty ? null : _frames.last.vsyncUs;
    final hcpp = await _hcppActive();
    debugPrint('bench: HybridAndroidViewController.checkIfSupported() = $hcpp');
    await _post({
      'type': 'hello',
      'version': _version,
      'clips': _clips,
      'configs': [for (final c in _configs) c.name],
      'passes': _passes,
      'trace': _trace,
      'mpvLog': _mpvLogLevel.name,
      'animated': [for (final c in _animated) c.name],
      'views': _views,
      'linkTest': _linkTestClip,
      'hcppActive': hcpp,
      'refreshRate': view.display.refreshRate,
      'physicalSize': _viewSize(),
      'clockSkewUs': lastVsync == null ? null : developer.Timeline.now - lastVsync,
      'epochMs': DateTime.now().millisecondsSinceEpoch,
    });
    if (_checks) {
      await _setOrientation('portrait');
      await _runChecks();
      await _post({'type': 'done', 'version': _version, 'epochMs': DateTime.now().millisecondsSinceEpoch});
      if (mounted) setState(() => _status = 'done');
      return;
    }
    if (_linkTestClip.isNotEmpty) {
      if (mounted) setState(() => _status = 'link test · $_linkTestClip');
      await _post(await _linkTest(_linkTestClip));
    }
    var nativeId = 1000;
    for (final pass in _passes) {
      await _setOrientation(pass);
      for (final clip in _clips) {
        for (final cfg in _configs) {
          for (final benchView in _views) {
            final viewSize = _viewSize();
            _small = benchView == 'small';
            _mini.value = _small ? 1 : 0;
            Map<String, dynamic> result;
            try {
              result = cfg == BenchConfig.native || cfg == BenchConfig.nativeTexture
                  ? await _runNative(clip, cfg, nativeId++)
                  : await _runMediaKit(clip, cfg);
            } catch (e, st) {
              result = {
                'ok': false,
                'error': 'exception: $e',
                'stack': st.toString().split('\n').take(6).join(' | '),
              };
              if (mounted) {
                setState(() {
                  _video = null;
                  _overlay = false;
                });
              }
              await Future<void>.delayed(_gap);
            }
            result['type'] = 'run';
            result['version'] = _version;
            result['pass'] = pass;
            result['viewSize'] = viewSize;
            result['clip'] = clip;
            result['config'] = cfg.name;
            result['view'] = benchView;
            _small = false;
            _mini.value = 0;
            await _post(result);
          }
        }
      }
    }
    await _setOrientation('portrait');
    await _post({'type': 'done', 'version': _version, 'epochMs': DateTime.now().millisecondsSinceEpoch});
    if (mounted) setState(() => _status = 'done');
  }

  /// [ms since start, mpv time-pos] every 200 ms for [d].
  Future<List<List<num>>> _samplePos(NativePlayer np, Duration d) async {
    final out = <List<num>>[];
    final sw = Stopwatch()..start();
    while (sw.elapsed < d) {
      out.add([sw.elapsedMilliseconds, await _timePos(np)]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return out;
  }

  /// Runs [body] with a fresh Player rendered through a default VideoController.
  Future<Map<String, dynamic>> _check(
    String name,
    Future<Map<String, dynamic>> Function(Player player, NativePlayer np, VideoController controller) body,
  ) async {
    final player = Player(configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn));
    final np = player.platform as NativePlayer;
    final logs = <String>[];
    final sub = player.stream.log.listen((l) {
      if (logs.length < 40) logs.add('[${l.level}] ${l.prefix}: ${l.text}'.trim());
    });
    final controller = VideoController(player);
    setState(() {
      _status = 'check · $name';
      _video = Video(controller: controller, controls: NoVideoControls, fit: BoxFit.contain);
    });
    await WidgetsBinding.instance.endOfFrame;
    Map<String, dynamic> result;
    try {
      result = await body(player, np, controller);
    } catch (e, st) {
      result = {'pass': false, 'error': '$e', 'stack': st.toString().split('\n').take(6).join(' | ')};
    }
    result['info'] = await _props(np, ['hwdec-current', 'video-params/w', 'video-params/h', 'estimated-vf-fps']);
    setState(() => _video = null);
    await WidgetsBinding.instance.endOfFrame;
    await sub.cancel();
    await player.dispose();
    result['mpvLog'] = logs;
    await Future<void>.delayed(_gap);
    return result;
  }

  Future<void> _runChecks() async {
    const long = '$_host/clips/long_720p30_6min.mp4';
    bool noneBelow(List<List<num>> s, double min, {int afterMs = 0}) =>
        s.where((e) => e[0] >= afterMs && e[1] > 0).every((e) => e[1] >= min);
    final checks = <String, Future<Map<String, dynamic>> Function(Player, NativePlayer, VideoController)>{
      // media-kit#1215: Media.start must survive the Surface attach.
      'mediaStart5min': (p, np, c) async {
        await p.open(Media(long, start: const Duration(minutes: 5)));
        final s = await _samplePos(np, const Duration(seconds: 8));
        return {'pass': noneBelow(s, 299.5) && s.last[1] >= 303, 'samples': s};
      },
      // media-kit#1215: a seek issued right after open() must stick.
      'seekRightAfterOpen': (p, np, c) async {
        await p.open(Media(long));
        await p.seek(const Duration(minutes: 2));
        final s = await _samplePos(np, const Duration(seconds: 8));
        return {'pass': noneBelow(s, 119.5, afterMs: 1500) && s.last[1] >= 123, 'samples': s};
      },
      // media-kit#1417: MP4 whose first keyframe is 8 s in (audio from 0): playback must start at 0.
      'lateFirstKeyframeMp4': (p, np, c) async {
        await p.open(Media('$_host/clips/late_keyframe.mp4'));
        final s = await _samplePos(np, const Duration(seconds: 14));
        final first = s.firstWhere((e) => e[1] > 0.05, orElse: () => [0, -1]);
        return {'pass': first[1] >= 0 && first[1] < 3 && s.last[1] >= 10, 'firstMovingPos': first[1], 'samples': s};
      },
      // Harder variant: MPEG-TS cut mid-GOP, so not even the codec parameters exist before the keyframe
      // 9.4 s in; the video size is unknown until then.
      'lateKeyframeTsNoCodecParams': (p, np, c) async {
        await p.open(Media('$_host/clips/late_keyframe.ts'));
        final s = await _samplePos(np, const Duration(seconds: 14));
        final first = s.firstWhere((e) => e[1] > 0.05, orElse: () => [0, -1]);
        return {'pass': first[1] >= 0 && first[1] < 3 && s.last[1] >= 10, 'firstMovingPos': first[1], 'samples': s};
      },
      // media-kit#1445: a live (non-seekable) HLS stream must render & keep playing.
      'liveHls': (p, np, c) async {
        await p.open(Media(_liveHlsUrl));
        await c.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 20), onTimeout: () {});
        final s = await _samplePos(np, const Duration(seconds: 15));
        final start = s.firstWhere((e) => e[1] > 0, orElse: () => [0, 0])[1];
        final w = int.tryParse(await _prop(np, 'video-params/w')) ?? 0;
        return {'pass': s.last[1] - start >= 10 && w > 0, 'advancedSeconds': s.last[1] - start, 'samples': s};
      },
      // media-kit#997: start position on HLS VOD.
      'hlsVodStart60s': (p, np, c) async {
        final sw = Stopwatch()..start();
        await p.open(Media(_vodHlsUrl, start: const Duration(seconds: 60)));
        // Generous budget: a public master with many variants loads over the phone's own connection.
        final loaded = await _waitFor(() async => await _timePos(np) > 0, const Duration(seconds: 40));
        final loadMs = sw.elapsedMilliseconds;
        final s = await _samplePos(np, const Duration(seconds: 10));
        return {
          'pass': loaded && noneBelow(s, 59) && s.last[1] >= 62,
          'loaded': loaded,
          'loadMs': loadMs,
          'samples': s,
        };
      },
      // media-kit#1453: loop at end of file, then open the next item: no abort.
      'eofLoopThenNext': (p, np, c) async {
        await p.setPlaylistMode(PlaylistMode.single);
        await p.open(Media('$_host/clips/short_a_4s.mp4'));
        final s1 = await _samplePos(np, const Duration(seconds: 9));
        var wrapped = false;
        for (var i = 1; i < s1.length; i++) {
          if (s1[i - 1][1] > 3.0 && s1[i][1] < 1.0) wrapped = true;
        }
        await p.open(Media('$_host/clips/short_b_4s.mp4'));
        final s2 = await _samplePos(np, const Duration(seconds: 3));
        return {'pass': wrapped && s2.last[1] > 1.0, 'wrapped': wrapped, 'samples': s1, 'samplesNext': s2};
      },
      // media-kit#1453: complete at end of file, then open the next item: no abort.
      'eofCompleteThenNext': (p, np, c) async {
        await p.setPlaylistMode(PlaylistMode.none);
        await p.open(Media('$_host/clips/short_a_4s.mp4'));
        final completed = await _waitFor(() async => p.state.completed, const Duration(seconds: 12));
        await p.open(Media('$_host/clips/short_b_4s.mp4'));
        final s2 = await _samplePos(np, const Duration(seconds: 3));
        return {'pass': completed && s2.last[1] > 1.0, 'completed': completed, 'samplesNext': s2};
      },
    };
    for (final entry in checks.entries) {
      final r = await _check(entry.key, entry.value);
      r['type'] = 'check';
      r['version'] = _version;
      r['name'] = entry.key;
      await _post(r);
    }
  }

  Future<Map<String, dynamic>> _linkTest(String clip) async {
    final sw = Stopwatch()..start();
    var bytes = 0;
    String? error;
    try {
      final req = await _http.getUrl(Uri.parse('$_host/clips/$clip'));
      final resp = await req.close();
      await for (final chunk in resp) {
        bytes += chunk.length;
      }
    } catch (e) {
      error = '$e';
    }
    final seconds = sw.elapsedMilliseconds / 1000;
    return {
      'type': 'link',
      'version': _version,
      'clip': clip,
      'bytes': bytes,
      'ms': sw.elapsedMilliseconds,
      'MBps': seconds > 0 ? _r2(bytes / 1e6 / seconds) : null,
      'Mbps': seconds > 0 ? _r2(bytes * 8 / 1e6 / seconds) : null,
      'error': error,
    };
  }

  VideoControllerConfiguration _videoConfig(BenchConfig cfg) => switch (cfg) {
        BenchConfig.mkDefault => const VideoControllerConfiguration(),
        BenchConfig.mkCopy => const VideoControllerConfiguration(vo: 'gpu', hwdec: 'mediacodec-copy'),
        BenchConfig.mkGpuMediacodec => const VideoControllerConfiguration(vo: 'gpu', hwdec: 'mediacodec'),
        BenchConfig.mkEmbed => const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec'),
        BenchConfig.native ||
        BenchConfig.nativeTexture =>
          throw StateError('${cfg.name} is not a media_kit configuration'),
      };

  Future<String> _prop(NativePlayer np, String name) async {
    try {
      return await np.getProperty(name);
    } catch (e) {
      return 'ERR:$e';
    }
  }

  Future<Map<String, String>> _props(NativePlayer np, List<String> names) async =>
      {for (final n in names) n: await _prop(np, n)};

  Future<double> _timePos(NativePlayer np) async => double.tryParse(await _prop(np, 'time-pos')) ?? 0;

  /// mpv's GPU time per fresh frame (vo-passes, GL timer queries): the sum of every pass's average & peak,
  /// in ms, & the passes' descriptions.
  Future<Map<String, dynamic>> _gpuPasses(NativePlayer np) async {
    final count = int.tryParse(await _prop(np, 'vo-passes/fresh/count')) ?? 0;
    var avg = 0.0;
    var peak = 0.0;
    final desc = <String>[];
    for (var i = 0; i < count; i++) {
      avg += (int.tryParse(await _prop(np, 'vo-passes/fresh/$i/avg')) ?? 0) / 1e6;
      peak += (int.tryParse(await _prop(np, 'vo-passes/fresh/$i/peak')) ?? 0) / 1e6;
      desc.add(await _prop(np, 'vo-passes/fresh/$i/desc'));
    }
    return {'passes': count, 'freshAvgMs': _r2(avg), 'freshPeakSumMs': _r2(peak), 'desc': desc};
  }

  Future<Map<String, dynamic>> _runMediaKit(String clip, BenchConfig cfg) async {
    final player = Player(configuration: PlayerConfiguration(logLevel: _mpvLogLevel));
    final np = player.platform as NativePlayer;
    final sw = Stopwatch();
    final logs = <String>[];
    final errors = <String>[];
    var rebuffers = 0;
    var wasBuffering = false;
    var playedOnce = false;
    final subs = <StreamSubscription<dynamic>>[
      player.stream.log.listen((l) {
        final line = '[${l.level}] ${l.prefix}: ${l.text}'.trim();
        if (_trace) {
          if (logs.length < 4000) logs.add('${sw.elapsedMilliseconds} $line');
        } else if (logs.length < 30) {
          logs.add(line);
        }
      }),
      player.stream.error.listen((e) {
        if (errors.length < 10) errors.add(e);
      }),
      player.stream.buffering.listen((b) {
        if (b && !wasBuffering && playedOnce) rebuffers++;
        wasBuffering = b;
      }),
    ];
    final controller = VideoController(player, configuration: _videoConfig(cfg));
    setState(() {
      _status = '$clip · ${cfg.name}';
      _overlay = false;
      _video = Video(controller: controller, controls: NoVideoControls, fit: BoxFit.contain);
    });
    await WidgetsBinding.instance.endOfFrame;
    final result = <String, dynamic>{'runStartEpochMs': DateTime.now().millisecondsSinceEpoch};
    final trace = <List<num>>[];
    var tracing = _trace;
    result['openEpochMs'] = DateTime.now().millisecondsSinceEpoch;
    sw.start();
    final tracer = !_trace
        ? null
        : () async {
            while (tracing) {
              final t = sw.elapsedMilliseconds;
              trace.add([t, double.tryParse(await _prop(np, 'time-pos')) ?? -1]);
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }();
    await player.open(Media('$_host/clips/$clip'));
    String? fail;
    try {
      await controller.waitUntilFirstFrameRendered.timeout(_ttffTimeout);
      result['ttffMs'] = sw.elapsedMilliseconds;
      playedOnce = true;
    } on TimeoutException {
      fail = 'no first frame within ${_ttffTimeout.inSeconds}s';
    }
    if (fail == null) {
      final firstFrameMs = sw.elapsedMilliseconds;
      final startPos = await _timePos(np);
      final moving = await _waitFor(
        () async => !player.state.buffering && await _timePos(np) >= startPos + _motionThresholdSeconds,
        _motionTimeout,
      );
      if (moving) {
        result['timeToMotionMs'] = sw.elapsedMilliseconds;
        result['startStallMs'] = sw.elapsedMilliseconds - firstFrameMs;
      } else {
        fail = 'playback did not advance within ${_motionTimeout.inSeconds}s after the first frame';
      }
    }
    const counters = [
      'frame-drop-count',
      'decoder-frame-drop-count',
      'vo-delayed-frame-count',
      'estimated-vf-fps',
      'time-pos',
    ];
    List<int>? win;
    List<double>? pos;
    _AnimatedPhase? animatedPhase;
    if (fail == null) {
      final t0 = developer.Timeline.now;
      final c0 = await _props(np, counters);
      await Future<void>.delayed(_plainWindow);
      final t1 = developer.Timeline.now;
      final c1 = await _props(np, counters);
      result['gpu'] = await _gpuPasses(np);
      setState(() => _overlay = true);
      await Future<void>.delayed(_overlayWindow);
      final t2 = developer.Timeline.now;
      final c2 = await _props(np, counters);
      win = [t0, t1, t2];
      pos = [for (final c in [c0, c1, c2]) double.tryParse(c['time-pos'] ?? '') ?? 0];
      result['counters'] = {'start': c0, 'plainEnd': c1, 'overlayEnd': c2};
      if (_animated.contains(cfg) && !_small) {
        animatedPhase = await _animatedPhase(() => _timePos(np));
        result['counters']['animatedEnd'] = await _props(np, counters);
      }
    }
    result['info'] = await _props(np, [
      'hwdec-current',
      'current-vo',
      'android-surface-size',
      'osd-dimensions/w',
      'osd-dimensions/h',
      'video-codec',
      'container-fps',
      'video-params/w',
      'video-params/h',
      'video-params/pixelformat',
    ]);
    result['ok'] = fail == null;
    result['error'] = fail;
    result['runEndEpochMs'] = DateTime.now().millisecondsSinceEpoch;
    tracing = false;
    await tracer;
    if (_trace) result['trace'] = trace;
    setState(() {
      _overlay = false;
      _video = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    for (final s in subs) {
      await s.cancel();
    }
    await player.dispose();
    await Future<void>.delayed(_gap);
    if (win != null && pos != null) {
      result['plain'] = _windowStats(win[0], win[1], playedSeconds: pos[1] - pos[0]);
      result['overlay'] = _windowStats(win[1], win[2], playedSeconds: pos[2] - pos[1]);
    }
    if (animatedPhase != null) result['animated'] = animatedPhase.stats();
    result['rebuffers'] = rebuffers;
    result['errors'] = errors;
    result['mpvLog'] = logs;
    return result;
  }

  Future<Map<String, dynamic>> _runNative(String clip, BenchConfig cfg, int id) async {
    final c = NativeVideoPlayerController(
      id: id,
      autoPlay: true,
      allowsPictureInPicture: false,
      canStartPictureInPictureAutomatically: false,
      lockToLandscape: false,
      showNativeControls: false,
    );
    final firstPlaying = Completer<void>();
    final errors = <String>[];
    var rebuffers = 0;
    var playedOnce = false;
    void listener(PlayerActivityEvent e) {
      if (e.state == PlayerActivityState.playing) {
        playedOnce = true;
        if (!firstPlaying.isCompleted) firstPlaying.complete();
      }
      if (e.state == PlayerActivityState.buffering && playedOnce) rebuffers++;
      if (e.state == PlayerActivityState.error && errors.length < 10) errors.add('error ${e.data ?? ''}');
    }

    c.addActivityListener(listener);
    setState(() {
      _status = '$clip · ${cfg.name}';
      _overlay = false;
      _video = NativeVideoPlayer(controller: c);
    });
    await c.initialize();
    final result = <String, dynamic>{
      'runStartEpochMs': DateTime.now().millisecondsSinceEpoch,
      'ttffMeaning': 'load() -> first playing state (the plugin\'s own startup metric)',
      'renderMode': cfg == BenchConfig.nativeTexture
          ? 'texture (androidTextureMode=true, feed buffering, lightweightInlineViews=true)'
          : 'platform view via initSurfaceAndroidView (androidTextureMode=false, the default)',
    };
    final sw = Stopwatch()..start();
    await c.load(url: '$_host/clips/$clip');
    String? fail;
    try {
      await firstPlaying.future.timeout(_ttffTimeout);
      result['ttffMs'] = sw.elapsedMilliseconds;
    } on TimeoutException {
      fail = 'never reached playing within ${_ttffTimeout.inSeconds}s';
    }
    if (fail == null) {
      final playingMs = sw.elapsedMilliseconds;
      final moving = await _waitFor(
        () async => c.currentPosition.inMilliseconds >= (_motionThresholdSeconds * 1000).round(),
        _motionTimeout,
      );
      if (moving) {
        result['timeToMotionMs'] = sw.elapsedMilliseconds;
        result['startStallMs'] = sw.elapsedMilliseconds - playingMs;
      } else {
        fail = 'position did not advance within ${_motionTimeout.inSeconds}s after playing';
      }
    }
    List<int>? win;
    List<int>? pos;
    _AnimatedPhase? animatedPhase;
    if (fail == null) {
      final t0 = developer.Timeline.now;
      final p0 = c.currentPosition.inMilliseconds;
      await Future<void>.delayed(_plainWindow);
      final t1 = developer.Timeline.now;
      final p1 = c.currentPosition.inMilliseconds;
      setState(() => _overlay = true);
      await Future<void>.delayed(_overlayWindow);
      final t2 = developer.Timeline.now;
      final p2 = c.currentPosition.inMilliseconds;
      win = [t0, t1, t2];
      pos = [p0, p1, p2];
      result['positionsMs'] = pos;
      if (_animated.contains(cfg) && !_small) {
        animatedPhase = await _animatedPhase(() async => c.currentPosition.inMilliseconds / 1000);
      }
    }
    result['ok'] = fail == null;
    result['error'] = fail;
    result['runEndEpochMs'] = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _overlay = false;
      _video = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    c.removeActivityListener(listener);
    await c.dispose();
    await Future<void>.delayed(_gap);
    if (win != null && pos != null) {
      result['plain'] = _windowStats(win[0], win[1], playedSeconds: (pos[1] - pos[0]) / 1000);
      result['overlay'] = _windowStats(win[1], win[2], playedSeconds: (pos[2] - pos[1]) / 1000);
    }
    if (animatedPhase != null) {
      result['animated'] = animatedPhase.stats()
        ..['positionGranularity'] = 'NativeVideoPlayerConfig.timeUpdateInterval (500 ms by default)';
    }
    result['rebuffers'] = rebuffers;
    result['errors'] = errors;
    return result;
  }

  /// Animates the video between full screen and a corner mini-player (one transition per second)
  /// for [_animatedWindow], sampling the playback position every 100 ms.
  Future<_AnimatedPhase> _animatedPhase(Future<double> Function() position) async {
    setState(() => _overlay = false);
    final phase = _AnimatedPhase(developer.Timeline.now, DateTime.now().millisecondsSinceEpoch);
    final sw = Stopwatch()..start();
    _mini.repeat(reverse: true);
    while (sw.elapsed < _animatedWindow) {
      phase.samples.add([sw.elapsedMilliseconds, await position()]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    phase.samples.add([sw.elapsedMilliseconds, await position()]);
    phase.endUs = developer.Timeline.now;
    phase.endEpochMs = DateTime.now().millisecondsSinceEpoch;
    _mini.stop();
    _mini.value = 0;
    await WidgetsBinding.instance.endOfFrame;
    return phase;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Always the same tree, full screen while _mini is 0, so animating never re-parents the video.
          if (_video != null)
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, box) => AnimatedBuilder(
                  animation: _mini,
                  child: _video,
                  builder: (context, child) {
                    final full = Offset.zero & box.biggest;
                    final w = box.maxWidth * 0.3;
                    final mini = Rect.fromLTWH(box.maxWidth - w - 16, box.maxHeight - w * 9 / 16 - 96, w, w * 9 / 16);
                    final rect = Rect.lerp(full, mini, Curves.easeInOut.transform(_mini.value))!;
                    return Stack(children: [Positioned.fromRect(rect: rect, child: child!)]);
                  },
                ),
              ),
            ),
          if (_overlay) const Align(alignment: Alignment.bottomCenter, child: _ControlsOverlay()),
          Positioned(
            top: 36,
            left: 8,
            child: Text(_status, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ControlsOverlay extends StatefulWidget {
  const _ControlsOverlay();

  @override
  State<_ControlsOverlay> createState() => _ControlsOverlayState();
}

class _ControlsOverlayState extends State<_ControlsOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ac =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ac,
      builder: (context, _) => Container(
        height: 110,
        color: Colors.black.withValues(alpha: 0.55),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: _ac.value),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.pause, color: Colors.white),
                const SizedBox(width: 12),
                Text('0:${(_ac.value * 59).floor().toString().padLeft(2, '0')}',
                    style: const TextStyle(color: Colors.white)),
                const Spacer(),
                Transform.rotate(
                  angle: _ac.value * 6.283,
                  child: const Icon(Icons.settings, color: Colors.white),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
