/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:async';

/// Hands values to [emit] at most once per [interval]: at once when the last one went out at least
/// [interval] ago (leading edge), else the latest value once [interval] has passed (trailing edge). With a
/// zero [interval], every value goes out at once.
class ThrottledEmitter<T> {
  final Duration interval;
  final void Function(T value) _emit;

  final _clock = Stopwatch()..start();
  Duration? _last;
  Timer? _timer;
  var _hasPending = false;
  late T _pending;
  var _nextAtOnce = false;

  ThrottledEmitter(this.interval, this._emit);

  void add(T value) {
    if (interval <= Duration.zero) {
      _emit(value);
      return;
    }
    final now = _clock.elapsed;
    final last = _last;
    if (_nextAtOnce || (_timer == null && (last == null || now - last >= interval))) {
      flush(value);
      return;
    }
    _pending = value;
    _hasPending = true;
    _timer ??= Timer(interval - (now - last!), _fire);
  }

  void _fire() {
    _timer = null;
    if (_hasPending) {
      _hasPending = false;
      _last = _clock.elapsed;
      _emit(_pending);
    }
  }

  /// Hands [value] out at once, instead of any pending one.
  void flush(T value) {
    cancel();
    _last = _clock.elapsed;
    _emit(value);
  }

  /// Hands a pending value out now instead of when the interval has passed.
  void flushPending() {
    if (_hasPending) {
      flush(_pending);
    }
  }

  /// The next value goes out at once, e.g. the first position after a seek.
  void nextAtOnce() {
    if (interval > Duration.zero) {
      _nextAtOnce = true;
    }
  }

  /// Drops a pending value.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _hasPending = false;
    _nextAtOnce = false;
  }
}
