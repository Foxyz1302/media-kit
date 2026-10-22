import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
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

const _host = 'http://127.0.0.1:8787';
const _allClips = [
  'h264_1080p60.mp4',
  'h264_1440p60.mp4',
  'hevc_1440p60.mp4',
  'vp9_1440p60.webm',
  'av1_1440p60.mp4',
];

enum BenchConfig { mkDefault, mkCopy, mkGpuMediacodec, mkEmbed, native }

const _clipsDefine = String.fromEnvironment('BENCH_CLIPS');
const _configsDefine = String.fromEnvironment('BENCH_CONFIGS');
const _passesDefine = String.fromEnvironment('BENCH_PASSES');
const _mpvLogDefine = String.fromEnvironment('BENCH_MPV_LOG', defaultValue: 'warn');
const _trace = bool.fromEnvironment('BENCH_TRACE');
const _version = 3;

List<String> _csv(String s) => [for (final e in s.split(',')) if (e.trim().isNotEmpty) e.trim()];

final List<String> _clips = _clipsDefine.isEmpty ? _allClips : _csv(_clipsDefine);
final List<BenchConfig> _configs = _configsDefine.isEmpty
    ? BenchConfig.values
    : [for (final n in _csv(_configsDefine)) BenchConfig.values.byName(n)];
final List<String> _passes = _passesDefine.isEmpty ? const ['portrait', 'landscape'] : _csv(_passesDefine);
final MPVLogLevel _mpvLogLevel = MPVLogLevel.values.byName(_mpvLogDefine);

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

final _http = HttpClient();

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

class _BenchPageState extends State<BenchPage> {
  Widget? _video;
  bool _overlay = false;
  String _status = 'waiting for host';

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
    await _post({
      'type': 'hello',
      'version': _version,
      'clips': _clips,
      'configs': [for (final c in _configs) c.name],
      'passes': _passes,
      'trace': _trace,
      'mpvLog': _mpvLogLevel.name,
      'refreshRate': view.display.refreshRate,
      'physicalSize': _viewSize(),
      'clockSkewUs': lastVsync == null ? null : developer.Timeline.now - lastVsync,
      'epochMs': DateTime.now().millisecondsSinceEpoch,
    });
    var nativeId = 1000;
    for (final pass in _passes) {
      await _setOrientation(pass);
      for (final clip in _clips) {
        for (final cfg in _configs) {
          final viewSize = _viewSize();
          Map<String, dynamic> result;
          try {
            result = cfg == BenchConfig.native ? await _runNative(clip, nativeId++) : await _runMediaKit(clip, cfg);
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
          await _post(result);
        }
      }
    }
    await _setOrientation('portrait');
    await _post({'type': 'done', 'version': _version, 'epochMs': DateTime.now().millisecondsSinceEpoch});
    if (mounted) setState(() => _status = 'done');
  }

  VideoControllerConfiguration _videoConfig(BenchConfig cfg) => switch (cfg) {
        BenchConfig.mkDefault => const VideoControllerConfiguration(),
        BenchConfig.mkCopy => const VideoControllerConfiguration(vo: 'gpu', hwdec: 'mediacodec-copy'),
        BenchConfig.mkGpuMediacodec => const VideoControllerConfiguration(vo: 'gpu', hwdec: 'mediacodec'),
        BenchConfig.mkEmbed => const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec'),
        BenchConfig.native => throw StateError('native is not a media_kit configuration'),
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
    if (fail == null) {
      final t0 = developer.Timeline.now;
      final c0 = await _props(np, counters);
      await Future<void>.delayed(_plainWindow);
      final t1 = developer.Timeline.now;
      final c1 = await _props(np, counters);
      setState(() => _overlay = true);
      await Future<void>.delayed(_overlayWindow);
      final t2 = developer.Timeline.now;
      final c2 = await _props(np, counters);
      win = [t0, t1, t2];
      pos = [for (final c in [c0, c1, c2]) double.tryParse(c['time-pos'] ?? '') ?? 0];
      result['counters'] = {'start': c0, 'plainEnd': c1, 'overlayEnd': c2};
    }
    result['info'] = await _props(np, [
      'hwdec-current',
      'current-vo',
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
    result['rebuffers'] = rebuffers;
    result['errors'] = errors;
    result['mpvLog'] = logs;
    return result;
  }

  Future<Map<String, dynamic>> _runNative(String clip, int id) async {
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
      _status = '$clip · native';
      _overlay = false;
      _video = NativeVideoPlayer(controller: c);
    });
    await c.initialize();
    final result = <String, dynamic>{
      'runStartEpochMs': DateTime.now().millisecondsSinceEpoch,
      'ttffMeaning': 'load() -> first playing state (the plugin\'s own startup metric)',
      'renderMode': 'platform view via initSurfaceAndroidView (androidTextureMode=false, the default)',
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
    result['rebuffers'] = rebuffers;
    result['errors'] = errors;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_video != null) SizedBox.expand(child: _video!),
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
