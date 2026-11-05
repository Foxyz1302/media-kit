/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/initializer.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';

/// {@template initializer_native_callable}
///
/// InitializerNativeCallable
/// -------------------------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// mpv's wakeup callback is a `NativeCallable` owned by a guardian isolate, which forwards each
/// wakeup to this isolate. If this isolate dies with live handles, the `NativeCallable` stays valid
/// (no "Callback invoked after it has been deleted", #1348) & the guardian destroys the handles it
/// can destroy safely: see [_guardian].
///
/// {@endtemplate}
class InitializerNativeCallable {
  /// Singleton instance.
  static InitializerNativeCallable? _instance;

  /// {@macro initializer}
  InitializerNativeCallable._(this.mpv);

  /// {@macro initializer}
  factory InitializerNativeCallable(generated.MPV mpv) {
    _instance ??= InitializerNativeCallable._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    final Future<_Guardian> spawning = _guardianFuture ??= _spawnGuardian();
    final _Guardian guardian;
    try {
      guardian = await spawning;
    } catch (_) {
      if (identical(_guardianFuture, spawning)) {
        _guardianFuture = null;
      }
      rethrow;
    }
    final ctx = mpv.mpv_create();
    if (ctx == nullptr) {
      return ctx;
    }
    for (final entry in options.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_option_string(ctx, name.cast(), value.cast());
      calloc.free(name);
      calloc.free(value);
    }
    mpv.mpv_initialize(ctx);
    _pumps[ctx.address] = _EventPump(callback);
    guardian.wakeups.keepIsolateAlive = true;
    guardian.control.send(['add', ctx.address]);
    mpv.mpv_set_wakeup_callback(ctx, guardian.wakeup, ctx.cast());
    return ctx;
  }

  /// Stops delivering the events of [ctx]; see [Initializer.dispose].
  Future<void> dispose(Pointer<generated.mpv_handle> ctx) {
    final pump = _pumps.remove(ctx.address);
    if (pump == null) {
      return Future<void>.value();
    }
    pump.closed = true;
    if (_pumps.isEmpty) {
      _guardianNow?.wakeups.keepIsolateAlive = false;
    }

    // mpv_set_wakeup_callback takes the lock mpv calls the callback under: once it returns, mpv never
    // calls the callback for [ctx] again.
    mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);

    if (!pump.draining) {
      return Future<void>.value();
    }
    return (pump.drained ??= Completer<void>()).future;
  }

  /// Tells the guardian that [ctx] may have a render context: if this isolate dies, it must not
  /// destroy [ctx], as mpv aborts the process when a handle is destroyed before its render context.
  void markRenderContext(Pointer<generated.mpv_handle> ctx) {
    _guardianNow?.control.send(['render', ctx.address]);
  }

  /// Hands [ctx] over to the guardian, which destroys it in a worker isolate; see [Initializer.destroy].
  ///
  /// One message: if this isolate dies at any point, [ctx] is destroyed exactly once.
  Future<void> destroy(Pointer<generated.mpv_handle> ctx) {
    final guardian = _guardianNow;
    if (guardian == null) {
      return terminateDestroyElsewhere(NativeLibrary.path, ctx.address);
    }
    final reply = ReceivePort();
    guardian.control.send(['destroy', ctx.address, reply.sendPort]);
    return reply.first.then((_) {});
  }

  void _callback(Pointer<generated.mpv_handle> ctx) {
    final pump = _pumps[ctx.address];
    // A drain in progress reads until the queue is empty, which includes the events this wakeup is for.
    if (pump == null || pump.closed || pump.draining) {
      return;
    }
    _drain(ctx, pump);
  }

  Future<void> _drain(
    Pointer<generated.mpv_handle> ctx,
    _EventPump pump,
  ) async {
    pump.draining = true;
    try {
      // The event stays valid until the next mpv_wait_event, so every callback finishes before it.
      while (!pump.closed) {
        final event = mpv.mpv_wait_event(ctx, 0);
        if (event == nullptr) break;
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_NONE) break;
        try {
          await pump.callback(event);
        } catch (exception, stacktrace) {
          print(exception.toString());
          print(stacktrace.toString());
        }
      }
    } finally {
      pump.draining = false;
      final drained = pump.drained;
      pump.drained = null;
      drained?.complete();
    }
  }

  Future<_Guardian> _spawnGuardian() async {
    final wakeups = RawReceivePort();
    wakeups.handler = (Object? message) {
      if (message is int) {
        _callback(Pointer.fromAddress(message));
      }
    };
    final handshake = ReceivePort();
    await Isolate.spawn(
      _guardian,
      [handshake.sendPort, wakeups.sendPort, NativeLibrary.path],
      debugName: 'media_kit: guardian',
    );
    final reply = await handshake.first as List<Object?>;
    final control = reply[0] as SendPort;
    final wakeup =
        Pointer<NativeFunction<Void Function(Pointer<Void>)>>.fromAddress(
      reply[1] as int,
    );
    // The guardian learns that this isolate died after it ran its last Dart code.
    Isolate.current.addOnExitListener(control, response: 'exit');
    return _guardianNow = _Guardian(control, wakeup, wakeups);
  }

  Future<_Guardian>? _guardianFuture;

  _Guardian? _guardianNow;

  final _pumps = HashMap<int, _EventPump>();
}

/// The guardian of the handles of one isolate, as seen from that isolate.
class _Guardian {
  _Guardian(this.control, this.wakeup, this.wakeups);

  /// Takes `['add', address]`, `['render', address]`, `['destroy', address, reply]` & `'exit'`.
  final SendPort control;

  /// The wakeup callback to give mpv.
  final Pointer<NativeFunction<Void Function(Pointer<Void>)>> wakeup;

  /// Receives the wakeups: the address of the handle that has events.
  final RawReceivePort wakeups;
}

/// The guardian isolate: owns the `NativeCallable` mpv calls on new events & forwards each wakeup.
///
/// It keeps the handles its owner created until the owner hands them over for destruction
/// (`destroy`, in a worker isolate, so the forwarding never waits for a destroy). When the owner dies with handles left, it clears their wakeup callback & destroys
/// them, except the ones that may still have a render context: those only get `quit` & stay alive,
/// because mpv aborts when a handle is destroyed before its render context (`mp_clients_destroy`).
void _guardian(List<Object?> arguments) {
  final handshake = arguments[0] as SendPort;
  final owner = arguments[1] as SendPort;
  final libmpv = arguments[2] as String;
  final mpv = generated.MPV(DynamicLibrary.open(libmpv));
  final wakeup = NativeCallable<Void Function(Pointer<Void>)>.listener(
    (Pointer<Void> ctx) => owner.send(ctx.address),
  );
  final guarded = HashMap<int, bool>();
  final control = RawReceivePort();
  control.handler = (Object? message) {
    switch (message) {
      case ['add', final int address]:
        guarded[address] = false;
      case ['render', final int address]:
        if (guarded.containsKey(address)) {
          guarded[address] = true;
        }
      case ['destroy', final int address, final SendPort reply]:
        guarded.remove(address);
        terminateDestroyElsewhere(libmpv, address).then(
          (_) => reply.send(null),
          onError: (Object exception) {
            print(exception);
            reply.send(null);
          },
        );
      case 'exit':
        for (final MapEntry(key: address, value: render) in guarded.entries) {
          final ctx = Pointer<generated.mpv_handle>.fromAddress(address);
          mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);
          if (render) {
            final quit = 'quit'.toNativeUtf8();
            mpv.mpv_command_string(ctx, quit.cast());
            calloc.free(quit);
          } else {
            mpv.mpv_terminate_destroy(ctx);
          }
        }
        guarded.clear();
        wakeup.close();
        control.close();
    }
  };
  handshake.send([control.sendPort, wakeup.nativeFunction.address]);
}

/// The event delivery of one mpv handle.
class _EventPump {
  _EventPump(this.callback);

  final EventCallback callback;

  /// Whether a drain is reading the handle's events.
  bool draining = false;

  /// Whether the delivery stopped: no more mpv_wait_event & no more callbacks.
  bool closed = false;

  /// Completed once the drain in progress has finished, for [InitializerNativeCallable.dispose].
  Completer<void>? drained;
}

typedef EventCallback = Future<void> Function(Pointer<generated.mpv_event>);
