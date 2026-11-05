/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:isolate';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/execmem_restriction.dart';
import 'package:media_kit/src/player/native/core/initializer_isolate.dart';
import 'package:media_kit/src/player/native/core/initializer_native_callable.dart';
import 'package:media_kit/src/values.dart';

/// {@template initializer}
///
/// Initializer
/// -----------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class Initializer {
  /// Singleton instance.
  static Initializer? _instance;

  /// {@macro initializer}
  Initializer._(this.mpv);

  /// {@macro initializer}
  factory Initializer(generated.MPV mpv) {
    _instance ??= Initializer._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Whether the handles of this isolate deliver their events through a helper isolate that waits in
  /// `mpv_wait_event`, instead of a `NativeCallable` wakeup callback.
  ///
  /// Hot-restart tears down the Dart isolate, which invalidates any previously
  /// registered `NativeCallable` trampolines. In debug mode, prefer the isolate
  /// based implementation to avoid native -> Dart callbacks that can outlive
  /// the isolate and crash with "Callback invoked after it has been deleted".
  /// See: https://github.com/media-kit/media-kit/issues/1340
  /// We still use NativeCallable based implementation in release mode and unit tests for better performance.
  bool get usesIsolate => (kDebugMode && isMainIsolate()) || isExecmemRestricted;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    if (usesIsolate) {
      return InitializerIsolate().create(callback, options: options);
    }
    return InitializerNativeCallable(mpv).create(callback, options: options);
  }

  /// Stops delivering the events of [ctx]. No event reaches the callback once this returns, and the
  /// returned [Future] completes once the callback in flight, if any, has finished & nothing waits in
  /// `mpv_wait_event` on [ctx] anymore: only then may [ctx] be destroyed.
  Future<void> dispose(Pointer<generated.mpv_handle> ctx) {
    if (usesIsolate) {
      return InitializerIsolate().dispose(mpv, ctx);
    }
    return InitializerNativeCallable(mpv).dispose(ctx);
  }

  /// Marks [ctx] as possibly having a render context: if this isolate dies with [ctx] alive, [ctx] is
  /// not destroyed (mpv would abort the process), only stopped.
  void markRenderContext(Pointer<generated.mpv_handle> ctx) {
    if (!usesIsolate) {
      InitializerNativeCallable(mpv).markRenderContext(ctx);
    }
  }

  /// Takes [ctx] off the handles destroyed when this isolate dies, right before it's destroyed.
  void release(Pointer<generated.mpv_handle> ctx) {
    if (!usesIsolate) {
      InitializerNativeCallable(mpv).release(ctx);
    }
  }

  bool isMainIsolate() {
    final name = Isolate.current.debugName;
    return name == 'main';
  }
}
