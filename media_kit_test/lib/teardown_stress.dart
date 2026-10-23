/// Linux teardown stress for the video output: players are created, played,
/// resized and disposed in parallel lanes, unsequenced, until the native
/// render context is freed while Flutter's raster thread renders with it.
///
/// Build once, then run the bundle on each windowing system:
///
///   flutter build linux --debug -t lib/teardown_stress.dart
///   STRESS_CLIPS=/path/a.mp4,/path/b.mp4 build/linux/x64/debug/bundle/media_kit_test
///   GDK_BACKEND=x11 STRESS_CLIPS=... build/linux/x64/debug/bundle/media_kit_test
///
/// Environment:
///   STRESS_CLIPS            comma separated files, required
///   STRESS_MODE             teardown (default), bench or shot
///   STRESS_LANES            players alive at once (4)
///   STRESS_ITERATIONS       create/dispose iterations per lane (25)
///   STRESS_MAX_LIFETIME_MS  longest life of a player (2000)
///   STRESS_SEQUENCED        1: pause and wait before dispose, as apps do today
///   STRESS_SHADERS          glsl-shaders value, e.g. an Anime4K chain
///   STRESS_SEED             random seed
///   STRESS_BENCH_SECONDS    bench: measured seconds (20)
///   STRESS_SIZE             bench, shot: fixed output size, WIDTHxHEIGHT
///   STRESS_SHOT             shot: PNG of the texture at 0.5 s of the first
///                           clip, as Flutter draws it, 2x a 640x360 lane
///   STRESS_MPV_LOG          mpv messages logged from this level (error)
///   STRESS_HWDEC            hwdec of the video controllers (auto)
///   STRESS_SIZES            setSize choices: video or WIDTHxHEIGHT, comma
///                           separated (video,640x360,1280x720,1920x1080,
///                           2560x1440)
///
/// Exit status: 0 when every iteration ended, 1 on errors, 2 without clips,
/// 3 when no iteration ended for 60 s; a crash leaves the signal's status.

import 'dart:async';
import 'dart:ffi' show DynamicLibrary, DynamicLibraryExtension, Int32, Void;
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

final _environment = Platform.environment;

int _integer(String key, int fallback) =>
    int.tryParse(_environment[key] ?? '') ?? fallback;

final _clips = (_environment['STRESS_CLIPS'] ?? '')
    .split(',')
    .where((e) => e.isNotEmpty)
    .toList();
final _mode = _environment['STRESS_MODE'] ?? 'teardown';
final _lanes = _integer('STRESS_LANES', 4);
final _iterations = _integer('STRESS_ITERATIONS', 25);
final _maxLifetime = _integer('STRESS_MAX_LIFETIME_MS', 2000);
final _sequenced = _environment['STRESS_SEQUENCED'] == '1';
final _shaders = _environment['STRESS_SHADERS'];
final _seed = _integer('STRESS_SEED', DateTime.now().millisecondsSinceEpoch);
final _benchSeconds = _integer('STRESS_BENCH_SECONDS', 20);
final _benchSize = _environment['STRESS_SIZE'];
final _hwdec = _environment['STRESS_HWDEC'];
final _mpvLogLevel = MPVLogLevel.values.firstWhere(
  (e) => e.name == _environment['STRESS_MPV_LOG'],
  orElse: () => MPVLogLevel.error,
);

final _outputSizes = [
  for (final size in (_environment['STRESS_SIZES'] ??
          'video,640x360,1280x720,1920x1080,2560x1440')
      .split(','))
    if (size.split('x') case [final width, final height])
      Size(double.parse(width), double.parse(height))
    else
      null,
];

void _log(String message) => stdout.writeln('stress: $message');

Future<Never> _exit(int code) async {
  _log('exit $code');
  await stdout.flush();
  DynamicLibrary.process()
      .lookupFunction<Void Function(Int32), void Function(int)>('_exit')(code);
  throw StateError('_exit returned');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (_clips.isEmpty) {
    _log('STRESS_CLIPS is empty');
    await _exit(2);
  }
  runApp(const MaterialApp(home: StressScreen()));
}

class _Lane {
  VideoController? controller;
  bool visible = true;
  Size size = const Size(320, 180);
}

class StressScreen extends StatefulWidget {
  const StressScreen({super.key});

  @override
  State<StressScreen> createState() => _StressScreenState();
}

class _StressScreenState extends State<StressScreen>
    with SingleTickerProviderStateMixin {
  late final _lane = List.generate(_lanes, (_) => _Lane());
  late final _spinner = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();
  final _shotKey = GlobalKey();
  final _random = Random(_seed);
  final _stopwatch = Stopwatch()..start();
  var _status = '';
  var _ended = 0;
  var _errors = 0;
  var _progress = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _spinner.dispose();
    super.dispose();
  }

  void _update(VoidCallback callback) {
    if (mounted) {
      setState(callback);
    }
  }

  String _clip() => _clips[_random.nextInt(_clips.length)];

  Size _laneSize() {
    final width = 160.0 + _random.nextInt(480);
    return Size(width, width * 9.0 / 16.0);
  }

  Duration _lifetime() {
    final bucket = _random.nextInt(10);
    if (bucket < 3) {
      return Duration(milliseconds: _random.nextInt(150));
    }
    if (bucket < 6) {
      return Duration(milliseconds: 150 + _random.nextInt(550));
    }
    return Duration(milliseconds: 700 + _random.nextInt(max(1, _maxLifetime - 700)));
  }

  Future<void> _run() async {
    _log('mode=$_mode lanes=$_lanes iterations=$_iterations seed=$_seed '
        'sequenced=$_sequenced shaders=${_shaders != null} hwdec=${_hwdec ?? 'auto'} '
        'backend=${_environment['GDK_BACKEND'] ?? 'default'} '
        'session=${_environment['XDG_SESSION_TYPE']}');
    try {
      await _probe();
      if (_mode == 'bench') {
        await _bench();
      } else if (_mode == 'shot') {
        await _shot();
      } else {
        await _teardown();
      }
    } catch (exception, stacktrace) {
      _errors++;
      _log('error: $exception\n$stacktrace');
    }
    _update(() => _status = 'waiting for mpv_terminate_destroy');
    await Future.delayed(const Duration(milliseconds: 6500));
    _log('${_errors == 0 ? 'PASS' : 'FAIL'} ended=$_ended errors=$_errors '
        'elapsed=${_stopwatch.elapsed.inMilliseconds} ms');
    await _exit(_errors == 0 ? 0 : 1);
  }

  Player _player() {
    final player = Player(
      configuration: PlayerConfiguration(
        bufferSize: 4 * 1024 * 1024,
        logLevel: _mpvLogLevel,
      ),
    );
    player.stream.log.listen(
      (e) => _log('mpv ${e.level} ${e.prefix}: ${e.text.trim()}'),
    );
    return player;
  }

  VideoController _controller(Player player) => VideoController(
        player,
        configuration: VideoControllerConfiguration(hwdec: _hwdec),
      );

  Future<void> _probe() async {
    final player = _player();
    final controller = _controller(player);
    _update(() => _lane[0].controller = controller);
    await player.open(Media(_clips.first));
    if ((player.state.videoParams.dw ?? 0) == 0) {
      await player.stream.videoParams
          .firstWhere((e) => (e.dw ?? 0) > 0)
          .timeout(const Duration(seconds: 10));
    }
    await Future.delayed(const Duration(seconds: 1));
    final native = player.platform as NativePlayer;
    for (final property in [
      'hwdec-current',
      'current-vo',
      'video-params/hw-pixelformat',
      'video-out-params/w',
      'video-out-params/h',
      'frame-drop-count',
    ]) {
      _log('probe $property=${await native.getProperty(property)}');
    }
    await player.pause();
    _update(() => _lane[0].controller = null);
    await Future.delayed(const Duration(milliseconds: 300));
    await player.dispose();
  }

  Future<void> _teardown() async {
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(_progress) > const Duration(seconds: 60)) {
        _log('HANG: no iteration ended for 60 s');
        _exit(3);
      }
    });
    await Future.wait([
      for (var i = 0; i < _lanes; i++) _runLane(i),
    ]);
    watchdog.cancel();
  }

  Future<void> _runLane(int index) async {
    for (var iteration = 0; iteration < _iterations; iteration++) {
      try {
        await _iteration(index, iteration);
      } catch (exception, stacktrace) {
        _errors++;
        _log('lane $index iteration $iteration error: $exception\n$stacktrace');
      }
      _ended++;
      _progress = DateTime.now();
      _update(() => _status = '$_ended / ${_lanes * _iterations}');
    }
  }

  Future<void> _iteration(int index, int iteration) async {
    final lane = _lane[index];
    final player = _player();
    final controller = _controller(player);
    _update(() {
      lane.controller = controller;
      lane.visible = true;
      lane.size = _laneSize();
    });
    final lifetime = _lifetime();
    final awaitOpen = _random.nextInt(5) != 0;
    final opened = player.open(Media(_clip()));
    if (awaitOpen) {
      await opened;
    } else {
      unawaited(opened.catchError((Object exception) {
        _errors++;
        _log('lane $index iteration $iteration open error: $exception');
      }));
    }
    final shaders = _shaders;
    if (shaders != null) {
      await (player.platform as NativePlayer).setProperty('glsl-shaders', shaders);
    }
    final deadline = DateTime.now().add(lifetime);
    final actions = <String>[];
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(milliseconds: _random.nextInt(250)));
      if (!DateTime.now().isBefore(deadline)) {
        break;
      }
      actions.add(await _action(lane, player, controller));
    }
    final hwdec = await (player.platform as NativePlayer)
        .getProperty('hwdec-current');
    final unmountFirst = _random.nextBool();
    if (unmountFirst) {
      _update(() => lane.controller = null);
    }
    if (_sequenced) {
      await player.pause();
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await player.dispose();
    if (!unmountFirst) {
      _update(() => lane.controller = null);
    }
    _log('lane $index iteration ${iteration + 1}/$_iterations '
        'lifetime=${lifetime.inMilliseconds} ms hwdec=$hwdec awaitOpen=$awaitOpen '
        'unmountFirst=$unmountFirst actions=${actions.join(',')}');
  }

  Future<String> _action(
    _Lane lane,
    Player player,
    VideoController controller,
  ) async {
    switch (_random.nextInt(6)) {
      case 0:
        await player.seek(Duration(milliseconds: _random.nextInt(18000)));
        return 'seek';
      case 1:
        final size = _outputSizes[_random.nextInt(_outputSizes.length)];
        await controller.setSize(
          width: size?.width.toInt(),
          height: size?.height.toInt(),
        );
        return 'setSize(${size?.width.toInt()}x${size?.height.toInt()})';
      case 2:
        await player.open(Media(_clip()));
        return 'open';
      case 3:
        await player.playOrPause();
        return 'playOrPause';
      case 4:
        _update(() => lane.size = _laneSize());
        return 'resize';
      default:
        _update(() => lane.visible = !lane.visible);
        return lane.visible ? 'show' : 'hide';
    }
  }

  Future<void> _bench() async {
    final players = <Player>[];
    for (var i = 0; i < _lanes; i++) {
      final player = _player();
      final controller = _controller(player);
      players.add(player);
      _update(() {
        _lane[i].controller = controller;
        _lane[i].size = const Size(480, 270);
      });
      final native = player.platform as NativePlayer;
      await native.setProperty('loop-file', 'inf');
      await player.open(Media(_clips[i % _clips.length]));
      final shaders = _shaders;
      if (shaders != null) {
        await native.setProperty('glsl-shaders', shaders);
      }
      final size = _benchSize?.split('x').map(int.parse).toList();
      if (size != null && size.length == 2) {
        await controller.setSize(width: size[0], height: size[1]);
      }
    }
    _update(() => _status = 'warming up');
    await Future.delayed(const Duration(seconds: 3));
    final timings = <FrameTiming>[];
    void collect(List<FrameTiming> list) => timings.addAll(list);
    SchedulerBinding.instance.addTimingsCallback(collect);
    _update(() => _status = 'measuring');
    await Future.delayed(Duration(seconds: _benchSeconds));
    SchedulerBinding.instance.removeTimingsCallback(collect);
    String percentiles(List<int> values) {
      values.sort();
      int at(double p) => values[min(values.length - 1, (values.length * p).floor())];
      final mean = values.reduce((a, b) => a + b) / values.length;
      return 'p50=${at(0.5)} p90=${at(0.9)} p99=${at(0.99)} '
          'max=${values.last} mean=${mean.toStringAsFixed(0)} us';
    }

    _log('bench frames=${timings.length} seconds=$_benchSeconds '
        'size=${_benchSize ?? 'video'} players=$_lanes');
    _log('bench raster ${percentiles(timings.map((e) => e.rasterDuration.inMicroseconds).toList())}');
    _log('bench build ${percentiles(timings.map((e) => e.buildDuration.inMicroseconds).toList())}');
    for (final player in players) {
      final native = player.platform as NativePlayer;
      final values = <String>[];
      for (final property in [
        'hwdec-current',
        'frame-drop-count',
        'decoder-frame-drop-count',
        'vo-delayed-frame-count',
        'video-out-params/w',
        'video-out-params/h',
      ]) {
        values.add('$property=${await native.getProperty(property)}');
      }
      _log('bench player ${values.join(' ')}');
    }
    for (final player in players) {
      await player.pause();
    }
    _update(() {
      for (final lane in _lane) {
        lane.controller = null;
      }
    });
    await Future.delayed(const Duration(milliseconds: 300));
    for (final player in players) {
      await player.dispose();
    }
    _ended = players.length;
  }

  Future<void> _shot() async {
    final player = _player();
    final controller = _controller(player);
    _update(() {
      _lane[0].controller = controller;
      _lane[0].size = const Size(640, 360);
    });
    final native = player.platform as NativePlayer;
    await native.setProperty('dither-depth', 'no');
    await player.open(
      Media(_clips.first, start: const Duration(milliseconds: 500)),
      play: false,
    );
    final shaders = _shaders;
    if (shaders != null) {
      await native.setProperty('glsl-shaders', shaders);
    }
    final size = _benchSize?.split('x').map(int.parse).toList();
    if (size != null && size.length == 2) {
      await controller.setSize(width: size[0], height: size[1]);
    }
    await Future.delayed(const Duration(seconds: 3));
    final boundary =
        _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final png = await image.toByteData(format: ImageByteFormat.png);
    final path = _environment['STRESS_SHOT'] ?? 'shot.png';
    File(path).writeAsBytesSync(png!.buffer.asUint8List());
    _log('shot $path ${image.width}x${image.height}');
    _update(() => _lane[0].controller = null);
    await Future.delayed(const Duration(milliseconds: 300));
    await player.dispose();
    _ended = 1;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Wrap(
            spacing: 4.0,
            runSpacing: 4.0,
            children: [
              for (final lane in _lane)
                SizedBox(
                  width: lane.size.width,
                  height: lane.size.height,
                  child: RepaintBoundary(
                    key: lane == _lane.first ? _shotKey : null,
                    child: lane.controller != null && lane.visible
                        ? Video(
                            controller: lane.controller!,
                            controls: NoVideoControls,
                          )
                        : const ColoredBox(color: Color(0xFF202020)),
                  ),
                ),
            ],
          ),
          Positioned(
            right: 16.0,
            bottom: 16.0,
            child: Row(
              children: [
                Text(_status, style: const TextStyle(color: Colors.white)),
                const SizedBox(width: 16.0),
                RotationTransition(
                  turns: _spinner,
                  child: const Icon(Icons.autorenew, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
