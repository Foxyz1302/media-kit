/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:synchronized/synchronized.dart';

/// One player's share of the process-wide hardware decoder budget ([VideoController.maxHardwareDecoders]).
///
/// The decision is made per file, in mpv's `on_preloaded` hook, before mpv creates the decoders: within the
/// budget the player decodes with its configured `hwdec`, over it on the CPU (`hwdec=no`). A player that
/// plays takes the decoder of a paused one (a hidden one first), which then decodes on the CPU; a player
/// put on the CPU by the budget asks again when it starts playing.
class HardwareDecoderBudget {
  /// See [VideoController.maxHardwareDecoders].
  static int? max;

  /// The players whose current file decodes on hardware, or is about to.
  static final _holders = <HardwareDecoderBudget>{};

  static final _members = <HardwareDecoderBudget>{};

  static final _lock = Lock();

  /// How long a player that gives up its decoder gets to release it.
  static const _releaseTimeout = Duration(milliseconds: 500);

  final Player player;

  /// The configured `hwdec`, used whenever this player may decode on hardware.
  final String hwdec;

  /// Whether a view shows this player's output; a hidden player gives up its decoder first.
  final bool Function() visible;

  /// The current file decodes on the CPU because of the budget.
  var _demoted = false;

  /// The current file already took a paused holder's decoder after the hardware refused one.
  var _retried = false;

  var _disposed = false;

  final _subscriptions = <StreamSubscription<dynamic>>[];

  NativePlayer get _platform => player.platform as NativePlayer;

  /// Whether this player is subject to the budget: it decodes on hardware unless told otherwise.
  bool get _enabled => !_disposed && hwdec.isNotEmpty && hwdec != 'no';

  HardwareDecoderBudget(this.player, this.hwdec, {required this.visible}) {
    _members.add(this);
    _subscriptions.add(player.stream.playing.listen((playing) {
      if (playing && _demoted) {
        unawaited(_lock.synchronized(_promote));
      }
    }));
    _subscriptions.add(player.stream.videoParams.listen((_) {
      if (_holders.contains(this)) {
        unawaited(_lock.synchronized(_onDecoder));
      }
    }));
  }

  /// The decoder of this file is up. The hardware may have refused it anyway (no hardware decoder for the
  /// codec, or its memory or pixel-rate budget is spent, e.g. 4 VP9 1440p60 decoders on the SM7435): mpv
  /// then decodes on the CPU. A playing player takes the decoder of a paused holder & asks once again;
  /// otherwise its slot goes to another player.
  Future<void> _onDecoder() async {
    if (!_holders.contains(this) || await _onHardware()) {
      return;
    }
    _holders.remove(this);
    if (max != null && !_retried && player.state.playing) {
      _retried = true;
      final victims = _paused();
      if (victims.isNotEmpty) {
        await victims.first._demote();
        _holders.add(this);
        unawaited(_setHwdec('no').then((_) => _setHwdec(hwdec)));
        return;
      }
    }
    await _promoteWaiting();
  }

  Future<void> _setHwdec(String value) => _platform
          .setProperty('hwdec', value, waitForInitialization: false)
          .catchError((Object exception, StackTrace stacktrace) {
        debugPrint(exception.toString());
        debugPrint(stacktrace.toString());
      });

  /// The paused holders, hidden ones first.
  List<HardwareDecoderBudget> _paused() => _holders
      .where((holder) => holder != this && !holder.player.state.playing)
      .toList()
    ..sort((a, b) => (a.visible() ? 1 : 0) - (b.visible() ? 1 : 0));

  /// Whether mpv decodes this player's video on hardware now (`hwdec-current`).
  Future<bool> _onHardware() async {
    if (_disposed) {
      return false;
    }
    try {
      final current = await _platform.getProperty(
        'hwdec-current',
        waitForInitialization: false,
      );
      return current.isNotEmpty && current != 'no';
    } catch (_) {
      return false;
    }
  }

  /// Runs in `on_preloaded`: picks this file's `hwdec` before mpv creates its decoders.
  Future<void> onPreloaded() async {
    if (!_enabled) {
      return;
    }
    _retried = false;
    final limit = max;
    if (limit == null) {
      if (_demoted) {
        _platform.setPropertySync('hwdec', hwdec);
        _demoted = false;
      }
      return;
    }
    if (!await _hasVideo()) {
      _holders.remove(this);
      return;
    }
    await _lock.synchronized(() async {
      if (_disposed) {
        return;
      }
      _holders.remove(this);
      final granted = _holders.length < limit ||
          (player.state.playing && await _evict(limit));
      _platform.setPropertySync('hwdec', granted ? hwdec : 'no');
      _demoted = !granted;
      if (granted) {
        _holders.add(this);
      }
    });
  }

  /// Runs in `on_unload`: the file's decoder goes with it.
  Future<void> onUnload() async {
    if (_holders.remove(this)) {
      unawaited(_lock.synchronized(_promoteWaiting));
    }
  }

  Future<bool> _hasVideo() async {
    Future<String> get(String property) =>
        _platform.getProperty(property, waitForInitialization: false);
    final count = int.tryParse(await get('track-list/count')) ?? 0;
    for (var i = 0; i < count; i++) {
      if (await get('track-list/$i/type') == 'video' &&
          await get('track-list/$i/albumart') != 'yes') {
        return true;
      }
    }
    return false;
  }

  /// Takes the decoder of a paused holder (a hidden one first) so that this player fits in [limit].
  Future<bool> _evict(int limit) async {
    for (final victim in _paused()) {
      if (_holders.length < limit) {
        break;
      }
      await victim._demote();
    }
    return _holders.length < limit;
  }

  /// Gives up this player's hardware decoder: mpv re-creates its decoder on the CPU, at the same position.
  Future<void> _demote() async {
    _holders.remove(this);
    _demoted = true;
    if (_disposed) {
      return;
    }
    try {
      // Not awaited: the reply comes through this player's event loop, which may be busy.
      unawaited(_platform
          .setProperty('hwdec', 'no', waitForInitialization: false)
          .catchError((Object _) {}));
      final deadline = DateTime.now().add(_releaseTimeout);
      while (await _onHardware() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } catch (exception, stacktrace) {
      debugPrint(exception.toString());
      debugPrint(stacktrace.toString());
    }
  }

  /// Back on hardware for a player that plays, if the budget allows it (taking a paused holder's decoder).
  Future<void> _promote() async {
    final limit = max;
    if (!_enabled || !_demoted || _holders.contains(this)) {
      return;
    }
    if (limit != null && _holders.length >= limit && !await _evict(limit)) {
      return;
    }
    _holders.add(this);
    _demoted = false;
    // Not awaited, under [_lock]: the reply comes through this player's event loop, which waits for
    // [_lock] if this player is in its own on_preloaded hook.
    unawaited(_setHwdec(hwdec));
  }

  /// A slot came free: the first playing player on the CPU because of the budget gets it.
  static Future<void> _promoteWaiting() async {
    for (final member in _members.toList()) {
      if (member._demoted && member.player.state.playing) {
        await member._promote();
        return;
      }
    }
  }

  void dispose() {
    _disposed = true;
    _members.remove(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_holders.remove(this)) {
      unawaited(_lock.synchronized(_promoteWaiting));
    }
  }
}
