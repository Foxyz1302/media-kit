# Core lane (`core-rewrite`): progress and plan

State on 2026-10-23: research and design are done, but no code has changed yet. The branch is `origin/integration` @ `dcdb9e2c` plus this note.

## Done
- Read `DECISIONS.md` (plan @ `da4d231a`), `architecture-audit.md`, `predidit-and-binaries.md` and the new-features survey (`tmp/plan/new-flutter-features.md`). Also read Predidit's `media_kit/src/native_event_loop.c`, `native_event_loop.dart` and `hook/build.dart` (in `tmp/ro-predidit`), integration's `real.dart` (2960 lines), the initializers, `platform_player.dart` and the test-infra headless suite.
- Set up a scratch package for the build-hook experiment at `tmp/core/hooktest/`: a C bridge that includes `dart_native_api.h` from the SDK, a `CBuilder` hook and `@Native` bindings. `pub get --offline` works there; nothing has been run yet.

## Next steps (one commit each, in this order)
0. **P1-C0.** Split `real.dart` into `part` files (`real_events.dart`, `real_create.dart`, `real_ffi.dart`, `real_isolate_tasks.dart`). Pure move, no behaviour change (DECISIONS).
1. **Hook experiment first.** In `tmp/core/hooktest`, check whether `@Native` resolves in:
   - `dart run`;
   - `dart test`, including inside `Isolate.run`;
   - a plain `dart --packages=… script.dart`. The helper-process tests `leak_helper` and `isolate_kill_helper` start that way (`test/common/helper_process.dart`), and no hooks run there.

   If the plain run can't resolve, either start the helpers with `dart run`, or give the bridge a `DynamicLibrary` fallback. Then add `media_kit/hook/build.dart` (`CBuilder.library`, include `<dart-sdk>/include`, the same as Predidit) and `media_kit/src/media_kit_native.c`. Record the mechanism in DECISIONS: a build hook, per DECISIONS "The C bridge is built through a build hook". Raise `sdk` to `^3.13.0`.
2. **Lifecycle (item 1).** Wakeup: a C function registered with `mpv_set_wakeup_callback` posts an int with `Dart_PostCObject`. The pointer to `mpv_set_wakeup_callback` is passed from Dart, so the bridge doesn't link libmpv.
   - Coalesce the posts: C sets a pending flag under its mutex. Dart clears it with an O(1) leaf `ack` before each drain.
   - A `NativeFinalizer` is the safety net. `mpv_terminate_destroy` runs on a worker thread, which posts "destroyed" when done.
   - `dispose` is idempotent (a second call returns the same Future) and ordered:
     1. reject new calls;
     2. `stop`;
     3. run the `release` callbacks first, so the native video output frees mpv's render context;
     4. stop the wakeup and drain the in-flight handler;
     5. fail the pending requests;
     6. destroy on the worker, and await that, bounded;
     7. close the streams last.

     Today `PlatformPlayer.dispose` closes the streams *before* `release`, which the audit flagged.
   - Remove the `InitializerIsolate`, `InitializerNativeCallable` and the 5 s timer.
3. **Per-player lock (item 4), P1-C2.**
   - Each player gets its own `Lock`. Keep the static `NativePlayer.lock` as a deprecated, unused field, because removing it would break source compatibility.
   - Bound the waits for player and VideoController init.
   - A failed `_create` completes the init completer with an error, wrapped in `.ignore()` so nobody gets an unhandled error. Calls then throw, and dispose still works.
4. **Dispatch on `reply_userdata` (item 2), P2-E1 + P1-C4.**
   - Internal observers get ids 1..N from a const table of (name, format, handler). User observers get ids ≥ 2^40 and use `MPV_FORMAT_STRING`, so there is no synchronous `mpv_get_property_string`. This fixes E-6 and E-8.
   - All async replies go through one request map (set, command, get).
   - Handlers emit only fields that changed.
   - `_logError` builds its text lazily. Logs are decoded only when the log stream has a listener.
5. **UI-rate position (item 3).**
   - `PlayerConfiguration.positionUpdateInterval`, default 100 ms; `Duration.zero` gives today's per-event behaviour. For reference, ExoPlayer's progress bar updates at most every 200 ms.
   - Leading- and trailing-edge throttle. The position is emitted immediately after `PLAYBACK_RESTART` or a seek, and on pause, stop and EOF. `stop()`/`open()` cancel a pending trailing emission.
   - `state.position` stays exact, updated on every event.
   - `buffer` and `bufferingPercentage` get the same throttle.
6. **FFI fixes (item 5).**
   - Flags are `Int32` for set and for read (`pause`, `core-idle`, `eof-reached` and the others).
   - The `_command` argv is n+1 instead of 128 slots.
   - Screenshots use an async `screenshot-raw` command on the owning isolate. The bytes are copied in the reply handler, and only the pixel encode runs in `compute`. Today `compute` uses the raw handle in another isolate, which is a use-after-free on dispose.
   - `_getPlaylist` becomes an async `playlist` node get.
   - Every node format is checked before it is read (Predidit 803c4a27).
7. **CA bundle (item 6).**
   - Ship curl's `cacert.pem` (Mozilla roots, MPL-2.0, checked against curl's published SHA-256) as a platform-specific asset, `platforms: [android, windows]`. Use a versioned file name.
   - Windows path: `<exe dir>/data/flutter_assets/packages/media_kit/assets/ca/<file>`. In `dart test` the path is resolved from `Isolate.resolvePackageUriSync('package:media_kit/')`. The Windows CI runs pure `dart test`.
   - Android: extract with `AndroidAssetLoader`, then check the file length.
   - Set `tls-ca-file` + `tls-verify=yes` on Android and Windows. On Linux, set `tls-verify=yes` and keep the system store (DECISIONS: "TLS verification on"). This is a behaviour change, and opting out is possible: `setProperty('tls-verify','no')`.
   - If no bundle is found, don't force verify, and log.
   - Resolve the bundle once per process, starting at `ensureInitialized`.
8. **Tests.**
   - Remove the `known-failing` tag from the ones this lane fixes:
     - `isolate-kill-with-live-players-1348`;
     - `leak-resources-released-after-dispose`;
     - `lifecycle-double-dispose`;
     - `lifecycle-player-not-blocked-by-another`;
     - `lifecycle-unobserve-property-keeps-position`.
   - Add tests: dispose racing every method and the escape hatches (`setProperty`, `command`, `observeProperty`, `screenshot`), events and timers after dispose, reply routing (interleaved set/command/get replies, a user observer of `time-pos`), and finalizer-only cleanup.
   - Not this lane: `stream-outage-is-an-error-not-completed` and `stream-http-error-stops-playing` (P1-C5/P1-N1).
9. **Measure.** In the leak helper, run 50+ create/open/dispose cycles and record RSS, FDs, threads and mpv threads, with and without `malloc_trim(0)` after `mpv_terminate_destroy`. On glibc the worker would call it; on Android it would be bionic's `mallopt(M_PURGE)`. Propose it; don't adopt it.
10. **Linux.** Desktop build and a short run with at most 2 players. Then push, and update DECISIONS.

Baseline on `dcdb9e2c`: `cd media_kit && flock tmp/heavy.lock -c 'dart test test/headless --concurrency=1 --reporter=expanded'` gives 48 pass and 7 known-failing skipped. The log is `tmp/integ-headless.log`.

## Findings that shape the design (verify the first one in mpv's source)
1. **mpv aborts on destroy while a render context is alive.**
   - From memory of `client.c` `mp_destroy_client_api`: "Broken API use: mpv_render_context_free() not called" is followed by `abort()`. The render.h docs say the render context must be freed before the core is destroyed.
   - So the finalizer path must not call `mpv_terminate_destroy` on desktop while a VideoController (the render API) is attached. In that case it sends `quit` and leaks the handle, like `NativeReferenceHolder` today. It terminates on Android (vo=gpu/wid, no render context) and for players without a VideoController.
   - The bridge gets a flag that Dart sets when `isVideoControllerAttached` is set on desktop.
   - In the dispose path, terminate runs only after the `release` callbacks. Linux frees the render context synchronously inside the `Dispose` channel call; Windows answers `Dispose` after it (e67886a9).
2. **`NativeReferenceHolder` becomes a use-after-free.** On the next start it would call `mpv_set_wakeup_callback` on handles the finalizer already destroyed. Drop its use once the finalizer lands; finalizers run on isolate shutdown, which covers hot restart.
3. **A deadlock today.** The drain loop awaits each handler, so an `observeProperty` listener that awaits `setProperty` or `command` deadlocks: its reply can't be dispatched. The new loop dispatches synchronously:
   - it doesn't await `observeProperty` listeners or hooks (`mpv_hook_continue` when they finish; mpv serves API calls while a hook waits);
   - it keeps awaiting `observeEvent` listeners, because they borrow the `mpv_event` pointer until the next `mpv_wait_event`.
4. **Use-after-free on late native calls.** Every native call must re-check "handle alive" synchronously, right before calling. Today the `disposed` check is followed by awaits, then by the mpv call. This also covers late timers, hooks and the bitrate handler.
5. **The Android helper never overwrites.** `MediaKitAndroidHelperCopyAssetToFilesDir` writes `<filesDir>/com.alexmercerind.media_kit/<asset path, '/'→'_'>` only when the file is missing. Hence the versioned name and the length check.
6. **One bad certificate breaks all HTTPS on Android.** FFmpeg's mbedTLS backend fails the whole TLS setup when `mbedtls_x509_crt_parse_file` returns non-zero, which includes one unparseable cert in the bundle. Android's Mbed TLS 3.4 must pass an on-device HTTPS check before verify-on ships there.
7. **The worker thread.** Predidit pre-creates one per player, and it sits idle for the player's whole life. The alternative is to spawn the thread at destroy time, including from the finalizer (pthread_create is legal there; no Dart API is touched), and fall back to `quit` if that fails. Proposed: spawn at destroy. Decide after the experiment.

## Needs a Windows build
The bridge built with MSVC through `native_toolchain_c`, the CA path under `data/flutter_assets`, the freeKC HTTPS check, and the Windows `dart test` job.

## Needs an on-device Android check
Bridge loading from jniLibs, the finalizer on engine detach, HTTPS with the bundle under Mbed TLS 3.4, and the `M_PURGE` effect.
