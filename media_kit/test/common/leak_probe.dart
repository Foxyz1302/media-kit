import 'dart:io';

/// {@template resource_snapshot}
///
/// ResourceSnapshot
/// ----------------
/// Process-wide resource counters read from `/proc/self` (Linux only).
///
/// {@endtemplate}
class ResourceSnapshot {
  /// {@macro resource_snapshot}
  const ResourceSnapshot(
    this.fds,
    this.threads,
    this.nativeThreads,
    this.rssKiB,
  );

  /// Reads the counters of the current process.
  factory ResourceSnapshot.take() => ResourceSnapshot(
        openFds().length,
        threadCount(),
        nativeThreadCount(),
        residentSetKiB(),
      );

  /// Restores a snapshot written by [toJson].
  factory ResourceSnapshot.fromJson(Map<String, dynamic> json) =>
      ResourceSnapshot(
        json['fds'],
        json['threads'],
        json['nativeThreads'],
        json['rssKiB'],
      );

  /// Open file descriptors.
  final int fds;

  /// Threads.
  final int threads;

  /// Threads not owned by the Dart VM, see [nativeThreadCount].
  final int nativeThreads;

  /// Resident set size, in KiB.
  final int rssKiB;

  Map<String, int> toJson() => {
        'fds': fds,
        'threads': threads,
        'nativeThreads': nativeThreads,
        'rssKiB': rssKiB,
      };

  @override
  String toString() =>
      'fds: $fds, threads: $threads ($nativeThreads native), rss: ${rssKiB ~/ 1024} MiB';
}

/// Open file descriptors of the current process and their targets, e.g. `socket:[1234]`.
Map<int, String> openFds() {
  final result = <int, String>{};
  for (final entry in Directory('/proc/self/fd').listSync(followLinks: false)) {
    final fd = int.tryParse(entry.path.split('/').last);
    if (fd == null) {
      continue;
    }
    try {
      result[fd] = Link(entry.path).targetSync();
    } on FileSystemException {
      continue;
    }
  }
  return result;
}

/// Threads of the current process.
int threadCount() => Directory('/proc/self/task').listSync().length;

/// Threads of the current process that the Dart VM does not own: libmpv, FFmpeg, drivers.
int nativeThreadCount() => threadNames()
    .entries
    .where(
      (entry) =>
          !entry.key.startsWith('Dart') && !entry.key.startsWith('dart:'),
    )
    .fold(0, (sum, entry) => sum + entry.value);

/// Thread names of the current process, with their counts.
Map<String, int> threadNames() {
  final result = <String, int>{};
  for (final entry in Directory('/proc/self/task').listSync()) {
    try {
      final name = File('${entry.path}/comm').readAsStringSync().trim();
      result[name] = (result[name] ?? 0) + 1;
    } on FileSystemException {
      continue;
    }
  }
  return result;
}

/// Resident set size of the current process, in KiB.
int residentSetKiB() {
  for (final line in File('/proc/self/status').readAsLinesSync()) {
    if (line.startsWith('VmRSS:')) {
      return int.parse(line.split(RegExp(r'\s+'))[1]);
    }
  }
  throw StateError('VmRSS is missing from /proc/self/status');
}

/// Entries of [after] missing from [before]: what grew between two samples of [openFds] or [threadNames].
Map<K, Object> grown<K>(Map<K, Object> before, Map<K, Object> after) {
  final result = <K, Object>{};
  for (final entry in after.entries) {
    final previous = before[entry.key];
    if (previous == null) {
      result[entry.key] = entry.value;
    } else if (previous is int && entry.value is int) {
      final delta = (entry.value as int) - previous;
      if (delta > 0) {
        result[entry.key] = delta;
      }
    }
  }
  return result;
}
