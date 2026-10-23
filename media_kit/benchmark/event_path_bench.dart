import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/media_kit.dart';

import '../test/common/headless.dart';
import '../test/common/test_media.dart';
import '../test/common/waits.dart';

/// Event-path micro-benchmark: what one libmpv event costs on the Dart side.
///
/// Usage, from the package root:
///   dart benchmark/event_path_bench.dart [--seconds 20] [--modes throughput,realtime]
///     [--profile-period 500] [--media file] [--output file.json]
///
/// The player runs in a spawned isolate, which takes the same event transport as
/// release builds, with no video or audio output, CPU decoding and `loop-file=inf`.
/// Modes:
/// * `throughput`: the 720p60 clip with `untimed=yes` and `aid=no`, as fast as it decodes;
/// * `realtime`: the 720p60 clip at normal speed.
///
/// In JIT the benchmark restarts itself with the profiler enabled and reads CPU samples
/// and allocation traces of the player isolate from its own VM service. An AOT build
/// (`dart compile exe`) reports wall-clock rates only.
Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (int i = 0; i + 1 < arguments.length; i += 2) {
    options[arguments[i].replaceFirst('--', '')] = arguments[i + 1];
  }
  if (!_aot &&
      !Platform.executableArguments
          .any((argument) => argument.startsWith('--sample-buffer-duration'))) {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        ...Platform.executableArguments,
        '--profiler',
        '--profile-vm',
        '--sample-buffer-duration=120',
        '--profile-period=${options['profile-period'] ?? 500}',
        Platform.script.toFilePath(),
        ...arguments,
      ],
      mode: ProcessStartMode.inheritStdio,
    );
    exit(await process.exitCode);
  }
  final seconds = int.parse(options['seconds'] ?? '20');
  final modes = (options['modes'] ?? 'throughput,realtime').split(',');
  var media = options['media'];
  if (media == null) {
    await TestMedia.ensure();
    media = TestMedia.bench720p60;
  }
  _VmService? vm;
  if (!_aot) {
    final info = await Service.controlWebServer(
      enable: true,
      silenceOutput: true,
    );
    vm = await _VmService.connect(info.serverWebSocketUri!);
  }
  final results = <String, Object?>{
    'benchmark': 'event_path_bench',
    'date': DateTime.now().toUtc().toIso8601String(),
    'compiler': _aot ? 'aot' : 'jit',
    'dart': Platform.version,
    'host': '${Platform.operatingSystem} ${Platform.numberOfProcessors} cpus',
    'git': await _git(),
    'media': media.split('/').last,
    'seconds': seconds,
  };
  for (final mode in modes) {
    stderr.writeln('event_path_bench: $mode for $seconds s');
    results[mode] = await _measure(vm, mode, media, seconds, results);
  }
  await vm?.close();
  final json = const JsonEncoder.withIndent('  ').convert(results);
  final output = options['output'];
  if (output == null) {
    stdout.writeln(json);
  } else {
    File(output).writeAsStringSync('$json\n');
    stderr.writeln('event_path_bench: wrote $output');
  }
  exit(0);
}

const bool _aot = bool.fromEnvironment('dart.vm.product');

const Map<String, String> _traced = {
  '_OneByteString': 'dart:core',
  '_TwoByteString': 'dart:core',
  'PlayerState': 'package:media_kit/src/models/player_state.dart',
  'Duration': 'dart:core',
  '_Future': 'dart:async',
  '_Closure': 'dart:core',
  'Pointer': 'dart:ffi',
  '_Double': 'dart:core',
};

class _Window {
  const _Window(this.counters, this.origin, this.end);

  final Map<String, num> counters;
  final int? origin;
  final int? end;

  int get events => counters['events']!.toInt();

  double get seconds => counters['micros']! / 1e6;
}

Future<_Window> _window(
  _VmService? vm,
  SendPort commands,
  StreamIterator<Object?> messages,
  Duration duration,
) async {
  final origin = (await vm?.call('getVMTimelineMicros'))?['timestamp'] as int?;
  commands.send('start');
  await Future.delayed(duration);
  commands.send('stop');
  await messages.moveNext();
  final counters = (messages.current as Map).cast<String, num>();
  final end = (await vm?.call('getVMTimelineMicros'))?['timestamp'] as int?;
  return _Window(counters, origin, end);
}

Future<Map<String, Object?>> _measure(
  _VmService? vm,
  String mode,
  String media,
  int seconds,
  Map<String, Object?> results,
) async {
  final port = ReceivePort();
  final messages = StreamIterator<Object?>(port);
  final isolate = await Isolate.spawn(
    _player,
    [port.sendPort, mode, media],
    debugName: 'bench-$mode',
  );
  await messages.moveNext();
  final commands = messages.current as SendPort;
  await messages.moveNext();
  final versions = messages.current as Map;
  results['mpv'] ??= versions['mpv'];
  results['ffmpeg'] ??= versions['ffmpeg'];
  final id = _aot ? null : Service.getIsolateId(isolate);
  final _Window window;
  Map<String, Object?>? cpu;
  Map<String, Object?>? allocations;
  try {
    window = await _window(vm, commands, messages, Duration(seconds: seconds));
    if (vm != null && id != null) {
      cpu = _cpu(
        await vm.call('getCpuSamples', {
          'isolateId': id,
          'timeOriginMicros': window.origin,
          'timeExtentMicros': window.end! - window.origin!,
        }),
        window,
      );
      allocations = await _allocations(
        vm,
        id,
        commands,
        messages,
        Duration(milliseconds: mode == 'realtime' ? 3000 : 250),
      );
    }
  } finally {
    commands.send('dispose');
    await messages.moveNext();
    isolate.kill();
    await messages.cancel();
  }
  double rate(String name) => _round(window.counters[name]! / window.seconds);
  return {
    'seconds': _round(window.seconds),
    'events': window.events,
    'eventsPerSecond': rate('events'),
    'positionsPerSecond': rate('positions'),
    'seekbarRepaintsPerSecond': rate('repaints'),
    'labelChangesPerSecond': rate('labels'),
    if (cpu != null) 'cpu': cpu,
    if (allocations != null) 'allocations': allocations,
  };
}

Map<String, Object?> _cpu(Map<String, dynamic> samples, _Window window) {
  final period = samples['samplePeriod'] as int;
  final count = samples['sampleCount'] as int;
  final functions = (samples['functions'] as List).cast<Map<String, dynamic>>();
  double perEvent(num ticks) => _round(ticks * period / window.events, 3);
  num inclusive(bool Function(String name) test) => functions
          .where((function) => test(_qualifiedName(function['function'])))
          .fold<num>(0, (max, function) {
        final ticks = function['inclusiveTicks'] as num;
        return ticks > max ? ticks : max;
      });
  final ranked = [
    for (final function in functions)
      if (function['kind'] == 'Dart') function,
  ]..sort(
      (a, b) =>
          (b['exclusiveTicks'] as num).compareTo(a['exclusiveTicks'] as num),
    );
  final kinds = <String, num>{};
  final native = <String, num>{};
  for (final function in functions) {
    final ticks = function['exclusiveTicks'] as num;
    final kind = function['kind'] as String? ?? '?';
    kinds[kind] = (kinds[kind] ?? 0) + ticks;
    if (kind == 'Native') {
      final library = _qualifiedName(function['function']).split('+').first;
      native[library] = (native[library] ?? 0) + ticks;
    }
  }
  final libraries = native.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final timestamps = [
    for (final sample in (samples['samples'] as List).cast<Map>())
      sample['timestamp'] as int,
  ];
  return {
    'samplePeriodMicros': period,
    'samples': count,
    'complete': timestamps.length < 200
        ? null
        : timestamps.reduce((a, b) => a < b ? a : b) <
            window.origin! + (window.end! - window.origin!) ~/ 10,
    'busyPercent': _round(100 * count * period / (window.seconds * 1e6)),
    'microsPerEvent': perEvent(count),
    'handlerMicrosPerEvent': perEvent(
      inclusive((name) => name == 'NativePlayer._handler'),
    ),
    'drainLoopMicrosPerEvent': perEvent(
      inclusive(
        (name) => name.startsWith('InitializerNativeCallable._callback'),
      ),
    ),
    'mpvWaitEventMicrosPerEvent': perEvent(
      inclusive((name) => name == 'mpv_wait_event'),
    ),
    'exclusivePercentByKind': {
      for (final entry in kinds.entries)
        entry.key: _round(100 * entry.value / count),
    },
    'nativeExclusivePercent': {
      for (final entry in libraries.take(6))
        entry.key: _round(100 * entry.value / count),
    },
    'dartExclusivePercent': {
      for (final function in ranked.take(12))
        _qualifiedName(function['function']):
            _round(100 * (function['exclusiveTicks'] as num) / count),
    },
  };
}

Future<Map<String, Object?>> _allocations(
  _VmService vm,
  String id,
  SendPort commands,
  StreamIterator<Object?> messages,
  Duration duration,
) async {
  final classes = <String, String>{};
  final list = await vm.call('getClassList', {'isolateId': id});
  for (final type in (list['classes'] as List).cast<Map<String, dynamic>>()) {
    final name = type['name'] as String;
    final library = (type['library'] as Map?)?['uri'];
    if (_traced[name] != null &&
        (library == null || library == _traced[name])) {
      classes[name] ??= type['id'] as String;
    }
  }
  Future<void> trace(bool enable) => Future.wait([
        for (final type in classes.values)
          vm.call('setTraceClassAllocation', {
            'isolateId': id,
            'classId': type,
            'enable': enable,
          }),
      ]);
  await trace(true);
  final window = await _window(vm, commands, messages, duration);
  await trace(false);
  final result = <String, Object?>{
    'seconds': _round(window.seconds),
    'events': window.events,
  };
  var complete = true;
  for (final entry in classes.entries) {
    final traces = await vm.call('getAllocationTraces', {
      'isolateId': id,
      'timeOriginMicros': window.origin,
      'timeExtentMicros': window.end! - window.origin!,
      'classId': entry.value,
    });
    final samples = (traces['samples'] as List).cast<Map>();
    if (samples.length > 100) {
      final first = samples
          .map((sample) => sample['timestamp'] as int)
          .reduce((a, b) => a < b ? a : b);
      complete &= first < window.origin! + (window.end! - window.origin!) ~/ 10;
    }
    result[entry.key] = _round(samples.length / window.events, 3);
  }
  result['complete'] = complete;
  return result;
}

String _qualifiedName(Object? function) {
  if (function is! Map) {
    return '$function';
  }
  final name = function['name'] as String? ?? '?';
  final owner = function['owner'];
  if (owner is Map &&
      (owner['type'] == '@Class' || owner['type'] == '@Function')) {
    return '${_qualifiedName(owner)}.$name';
  }
  return name;
}

double _round(num value, [int digits = 2]) =>
    double.parse(value.toStringAsFixed(digits));

Future<Map<String, Object?>?> _git() async {
  try {
    Future<String> git(List<String> arguments) async =>
        (await Process.run('git', arguments)).stdout.toString().trim();
    return {
      'head': await git(['rev-parse', '--short=8', 'HEAD']),
      'lib': await git(['log', '-1', '--format=%h', '--abbrev=8', '--', 'lib']),
      'dirty': (await git(['status', '--porcelain', '--', 'lib'])).isNotEmpty,
    };
  } catch (_) {
    return null;
  }
}

Future<void> _player(List<Object> arguments) async {
  final port = arguments[0] as SendPort;
  final mode = arguments[1] as String;
  final media = arguments[2] as String;
  final commands = ReceivePort();
  port.send(commands.sendPort);
  initializeHeadless();
  final player = await headlessPlayer();
  final native = player.platform as NativePlayer;
  await native.setProperty('loop-file', 'inf');
  if (mode == 'throughput') {
    await native.setProperty('untimed', 'yes');
    await native.setProperty('aid', 'no');
  }
  var events = 0;
  var positions = 0;
  var repaints = 0;
  var labels = 0;
  int? pixel;
  int? second;
  await native.observeEvent(
    generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE.value,
    (_) async {
      events++;
    },
  );
  player.stream.position.listen((position) {
    positions++;
    final duration = player.state.duration;
    if (duration > Duration.zero) {
      final next = position.inMicroseconds * 1000 ~/ duration.inMicroseconds;
      if (next != pixel) {
        pixel = next;
        repaints++;
      }
    }
    if (position.inSeconds != second) {
      second = position.inSeconds;
      labels++;
    }
  });
  final playing = waitFor(
    player.stream.position,
    (position) => position > Duration.zero,
    timeout: const Duration(seconds: 30),
  );
  await player.open(Media(media));
  await playing;
  await Future.delayed(const Duration(seconds: 2));
  port.send({
    'mpv': await native.getProperty('mpv-version'),
    'ffmpeg': await native.getProperty('ffmpeg-version'),
  });
  final clock = Stopwatch();
  await for (final command in commands) {
    switch (command) {
      case 'start':
        events = 0;
        positions = 0;
        repaints = 0;
        labels = 0;
        clock
          ..reset()
          ..start();
      case 'stop':
        port.send({
          'micros': clock.elapsedMicroseconds,
          'events': events,
          'positions': positions,
          'repaints': repaints,
          'labels': labels,
        });
      case 'dispose':
        await player.dispose();
        port.send(true);
        commands.close();
    }
  }
}

class _VmService {
  _VmService._(this._socket) {
    _socket.listen((data) {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      final completer = _pending.remove(message['id']);
      if (completer == null) {
        return;
      }
      if (message['error'] != null) {
        completer.completeError(StateError('${message['error']}'));
      } else {
        completer.complete(message['result'] as Map<String, dynamic>);
      }
    });
  }

  static Future<_VmService> connect(Uri uri) async =>
      _VmService._(await WebSocket.connect('$uri'));

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final id = '${_next++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future;
  }

  Future<void> close() => _socket.close();

  final WebSocket _socket;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  int _next = 0;
}
