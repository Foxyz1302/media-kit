# media_kit fork: architecture audit and phased rewrite plan

- Base: `integration` @ `9c0eef46` (upstream main + 14 merged PRs). This was a read-only audit of `ro-integration`. All line numbers refer to that tree.
- Targets: Android, Linux, Windows. Apple platforms are out of scope (§1.6). The public API must stay source-compatible.
- `android-playback` counts as Phase 1 in progress. Its work is not re-planned here; the findings that touch its files are in §2.7.
- Effort: **S** ≤ 1 agent-day, **M** = 2–5 days, **L** = 1–3 weeks. Risk: low, med or high, with the reason given.

---

## 0. Summary

Top findings, ranked by impact on the user's apps:

1. **The Linux teardown breaks mpv's render-API threading contract; this is the most likely cause of the NVIDIA SEGV.**
   - `video_output_dispose` frees the `mpv_render_context` on the platform thread (`linux/video_output.cc:42-99`).
   - The raster thread can be inside `texture_gl_populate_texture` at that moment, rendering with the same render context and the same isolated EGL context (`linux/texture_gl.cc:198-405`).
   - No lock prevents this, and no `eglMakeCurrent` return value is checked (`texture_gl.cc:228,307,346,384`).
2. **`NativePlayer.lock` is `static` (`real.dart:2638`).**
   - Every player in the process is serialized through one lock.
   - A VideoController that never finishes initializing, or a slow dispose, blocks every player. That's a feed blocker.
3. **Undefined behavior at the FFI boundary.**
   - `_setPropertyFlag` passes a 1-byte `Bool` where mpv reads a C `int` (`real.dart:2501-2505`).
   - The screenshot argv array is sized in characters, not pointers, and its NULL terminator falls outside the allocation (`real.dart:2685`).
4. **Per-event Dart cost after an event arrives** (coordinator's finding, confirmed):
   - up to 21 decodes of the property name per property event;
   - a new `PlayerState` per event (48 `copyWith` sites);
   - `time-pos` is unthrottled, so the seek bar and position label rebuild at the video frame rate. On 120 Hz displays this can double the composite rate.
   - The FFI transport (NativeCallable, `async=true`) is not the problem.
5. **The render paths load Flutter's raster thread.**
   - Linux renders mpv (including user shaders such as Anime4K), blits and calls `glFinish` on the raster thread, every frame.
   - On Windows the raster thread waits on a mutex that the worker holds across the whole mpv render plus `glFinish`.
6. **The output size is always the video's resolution.**
   - Fixed sizes are silently overwritten on desktop (`native_video_controller/real.dart:75-107`).
   - A 4K source gets a 3840×2160 surface on a 1220-px phone.
   - Anime4K upscale passes never run, because the output size equals the source size.
7. **The streaming defaults are weak for 1440p/4K over the web:**
   - 32 MiB forward and 32 MiB back cache;
   - `network-timeout=5` and no reconnect, so a network hiccup becomes EOF and `completed`;
   - `hr-seek-framedrop=no`;
   - TLS certificates are not verified.
8. **Signals are missing or wrong.**
   - Load errors are never events: `MPV_EVENT_END_FILE` is unhandled.
   - `waitUntilFirstFrameRendered` fires on the 1×1 placeholder on Linux and on video-params on Android, and it completes once per controller lifetime.
9. **Feed and animation blockers:**
   - On Android, every surface change rebuilds the VO and seeks. Each `onSurfaceAvailable` mints a new JNI global ref, so even a same-Surface resize counts as a new `wid`.
   - There is no pool, preload or poster API.
   - A pooled player costs up to 64 MiB of demuxer cache plus video-sized ImageReader buffers.

Proposed first 5 tasks, in parallel lanes (§4.6):
1. P1-L1 Linux render/teardown lock.
2. P0-1 + P0-2 headless lifecycle and leak suite.
3. P0-4 Linux teardown stress test that reproduces the SEGV.
4. P0-3 event-path micro-benchmark baseline.
5. P1-V1 + P1-V2 Dart video-controller fixes.

As soon as `android-playback` merges: P1-C1 (FFI undefined behavior) and P1-C2 (per-instance lock).

---

## 1. Architecture map

### 1.1 media_kit core (pure Dart + FFI)

**Initialization**
- `MediaKit.ensureInitialized` (`media_kit/lib/src/media_kit.dart:22-58`) calls `nativeEnsureInitialized` (`real.dart:42-73`), which does three things:
  - `AndroidHelper.ensureInitialized` (`native/utils/android_helper.dart:23-116`). It hands the JavaVM to ffmpeg, spinning with `sleep(20 ms)` on the UI thread until the VM is available, with no bound.
  - `NativeLibrary.ensureInitialized` (`native/core/native_library.dart`). It probes by name (`libmpv.so`, `libmpv-2.dll`, …) or uses `LIBMPV_LIBRARY_PATH`.
  - `NativeReferenceHolder` (debug only). It persists handle addresses in a temp file. After a hot restart it clears the old wakeup callbacks and sends `quit`.

**Facade**
- `Player` (`player/player.dart:101-333`) forwards to a nullable `PlatformPlayer platform`.
- Apps reach mpv through `(player.platform as NativePlayer).setProperty/command/observeProperty`. That surface must stay.

**`PlatformPlayer`** (`player/platform_player.dart:34-380`)
- A public mutable `state` field (an immutable snapshot, replaced on every change).
- 25 broadcast StreamControllers, each exposed through `.distinct()` (45-108). `audioParams`, `videoParams` and `error` are not distinct.
- Init completers: `completer`, `videoControllerCompleter`.
- `release` callbacks. They run *after* the streams close (139-146), although the docs say "before dispose" (378).

**`NativePlayer`** (`player/native/player/real.dart`, 2842 lines)

Creation, `_create()` (2261-2447), under the static lock:
- pre-init options: `vid=no`, plus the iOS-only audio session option;
- `Initializer.create`: `mpv_create`, `mpv_set_option_string`, then `mpv_initialize`, synchronously on the calling isolate (`initializer_native_callable.dart:38-58`);
- about 29 runtime properties through async set (2326-2381);
- 20 property observations with `reply_userdata = name.hashCode` (2393-2419). `speed` is observed but never handled;
- `on_load`/`on_unload` hooks, always registered (2437-2443).

Transport:
- `_setProperty`/`_command` (2467-2564) call `mpv_*_async` with a request id that maps to a Completer.
- The reply comes back as `MPV_EVENT_*_REPLY` through the event loop (1440-1460).

Public methods:
- Each one follows the same pattern:
  1. `lock.synchronized` (the static lock);
  2. the `disposed` check;
  3. `await waitForPlayerInitialization`;
  4. `await waitForVideoControllerInitializationIfAttached`;
  5. the commands.
- State and streams are updated optimistically, before mpv confirms (for example `play()`, 359-371).

`open()` (145-229):
- `stop()` (3 commands), `pause=yes`, then a temp m3u file is written and loaded with `loadlist` (194-207); `fd://` items use one `loadfile` each.
- Then `pause=no` and `playlist-pos`.
- That's 7 or more sequential round trips plus file I/O before mpv starts opening the stream.
- Headers, start and end are applied in the `on_load` hook (2091-2205). That needs a Dart round trip while mpv's loading is blocked.

Escape hatches:
- `setProperty` is async since #1454.
- `getProperty` is a synchronous `mpv_get_property_string` call on the UI isolate (1207-1234).
- `observeProperty` observes with `MPV_FORMAT_NONE`, then does a synchronous get on every change (1243-1270, 1500-1519).
- `observeEvent`, `command`.

`screenshot` (1117-1154): `screenshot-raw`, then a pure-Dart JPEG/PNG encode in a `compute` isolate, all while holding the static lock.

**Event loop** (`native/core/initializer.dart:40-58`)
- Debug mode on the main isolate uses `InitializerIsolate`:
  - one isolate per player;
  - it polls `mpv_wait_event(handle, 0.1)`;
  - each event costs 2 port hops (`initializer_isolate.dart:102-162`).
- Release mode and `dart test` use `InitializerNativeCallable`:
  - `mpv_set_wakeup_callback` is wired to `NativeCallable.listener`;
  - `_callback` drains `mpv_wait_event(ctx,0)` on the UI isolate, under a per-handle `Lock`, and awaits the handler for every event (72-81).
- Devices with execmem restrictions use the isolate path even in release.

**`_handler`** (1377-2259)
- An if-chain over event types and property names (§2.1).
- It updates `state` and the streams.
- It scrapes errors out of log lines by prefix (2042-2090).
- `END_FILE`, `FILE_LOADED` and `PLAYBACK_RESTART` are not handled.

**Dispose** (96-124), in order:
1. Takes the static lock.
2. Waits for player init and for VideoController init, with no timeout.
3. `NativeReferenceHolder.remove`.
4. `stop`.
5. `disposed = true`.
6. `super.dispose()`: closes the 25 controllers, then runs the `release` callbacks, which include the native video-output dispose.
7. `Initializer.dispose`: clears the wakeup callback and closes the NativeCallable.
8. `Future.delayed(5 s, mpv_terminate_destroy)` on the UI isolate.

**Models**
- `Media` (`models/media/media_native.dart`):
  - keeps a global URI-keyed cache of headers and extras, refcounted through a Finalizer;
  - runs `normalizeURI` 3 times per construction (125-128), each time including a synchronous stat for assets (`asset_loader.dart:74`);
  - compares equal by URI alone.
- `Track` compares equal by `id` alone (`models/track.dart:85-99`). The `tracks` stream's `distinct()` therefore drops metadata updates that keep the same ids (`platform_player.dart:95-97`).

### 1.2 media_kit_video (Dart)

**`VideoController`** (`lib/src/video_controller/video_controller.dart:55-161`)
- Marks the player as having a controller (77).
- Waits for a post-frame callback (79-82).
- Creates the platform controller: Native on Linux, Windows and Apple; Android; Web.
- Mirrors `id` and `rect`.
- Completes `videoControllerCompleter` (133-135).
- `dispose()` only disposes notifiers (139-143). The native output lives until `Player.dispose`, through `release`.

**`NativeVideoController`** (`native_video_controller/real.dart`), used on Linux and Windows
- `create` (111-183) runs:
  1. `queryDecoders`, a synchronous `decoder-list` read on the UI isolate (`utils/query_decoders.dart:20-66`);
  2. `vo=libmpv`, `hwdec=auto`, `vid=auto` (150-154);
  3. `VideoOutputManager.Create` (169-176);
  4. a wait for the first texture id (178), with no timeout.
- A `videoParams` listener (75-107) pushes the video's dw×dh to native SetSize on every change.
- A static channel handler (234-273) calls `debugPrint` on every native→Dart call.

**`AndroidVideoController`** (`android_video_controller/real.dart`, the file `android-playback` is editing)
- `create` (142-213): an IsEmulator channel call, then `Create`, then 10 property sets one after another.
- `widListener` (51-88): any `wid` change runs `vo=null`, `android-surface-size`, `wid`, `vo=gpu`, then `seek(player.state.position)`.
- A `videoParams` listener (96-138): `SetSurfaceSize(dw,dh)`, sets `rect`, completes "first frame".

**`Video` widget** (`lib/src/video/video_texture.dart:67-463`)
- The tree, from the outside in:
  - `Container(color: fill)`;
  - `Stack[ClipRect → FittedBox → ValueListenableBuilder×3 (notifier → id → rect) → SizedBox(rect) → Texture(filterQuality: low)]`;
  - `SubtitleView` (Flutter text);
  - the controls builder.
- It listens to `width`/`height` to decide visibility, and to `playing` for the wakelock.
- It pauses when the app goes to the background (279-299).

**Controls**
- `AdaptiveVideoControls` picks Material on Android, MaterialDesktop on Linux and Windows, Cupertino on Apple only.
- The seek bar and time label call `setState` on every position event.
- The seek bar seeks on every pointer move.
- The whole overlay sits in one `AnimatedOpacity` with a full-size 40% scrim (§3.6).

**Fullscreen** (`controls/methods/fullscreen.dart`): pushes a route with a second `Video` for the same controller.

### 1.3 Native code

**Android** (Kotlin, not Java)
- `MediaKitVideoPlugin.kt`: the channel.
- `VideoOutputManager.kt`: handle → `VideoOutput`.
- `VideoOutput.kt`:
  - `TextureRegistry.SurfaceProducer` (97);
  - `setSurfaceSize` calls `setSize` and then a synthetic `onSurfaceAvailable` (124-136);
  - every call mints a new JNI global ref of `surface` (142), which goes to Dart as `VideoOutput.Resize{id,wid,rect}`;
  - `onSurfaceCleanup` sends wid=0 and deletes the global ref 5 s later (152-166);
  - `dispose` releases the Surface and the producer (104-118).
- mpv renders by itself (`vo=gpu`, `gpu-context=android`, `wid`=global ref) on its own VO thread.
- Helper library: `libs/android/*/MediaKitAndroidHelper.kt` (JNI refs, content:// fds, files dir).
- libmpv comes from prebuilt jars v1.1.11 with MD5 checks (`libs/android/media_kit_libs_android_video/android/build.gradle.kts:75-96`).

**Linux** (C, GObject)
- `media_kit_video_plugin.cc`: the channel. It leaks one callback struct per Create (67-71).
- `video_output_manager.cc`.
- `video_output.cc`:
  - an isolated EGL context on GDK's EGLDisplay;
  - an OpenGL `mpv_render_context`;
  - the update callback calls `mark_texture_frame_available` (254-264).
- `texture_gl.cc`: populate runs on the raster thread and does the mpv render, the blit, `glFinish`, and the EGLImage hand-over into Flutter's context.
- `texture_sw.cc`, `isolated_egl.cc` (switching contexts around GDK).
- System libmpv through pkg-config (`linux/CMakeLists.txt:31`).

**Windows** (C++)
- `media_kit_video_plugin.cc`: the channel. It subclasses the root HWND with `SetWindowLongPtr` (32, 53) so it can post work to the main thread.
- `video_output_manager.cc`: every operation runs on a detached `std::thread` under a process-wide mutex (17-50).
- `video_output.cc`: ANGLE on D3D11, with one single-worker `ThreadPool` shared by all outputs (`video_output_manager.h:77`).
- `angle_surface_manager.cc`: two shared D3D11 textures and a pbuffer from a share handle; `Draw` and `Read` take one Win32 mutex.
- libmpv 0.41.0 and ANGLE are downloaded by the libs package's CMake (`libs/windows/media_kit_libs_windows_video/windows/CMakeLists.txt:72+`).

### 1.4 Threads and data flow

```
UI isolate (Dart)                                  mpv threads
Player.x() ─► NativePlayer [static Lock] ─ mpv_*_async ─► core thread ─► VO / decoder / demuxer threads
    ▲ 25 broadcast streams (.distinct)                    │ replies, property and log events
    │                                                      ▼
_handler ◄─ drain mpv_wait_event(ctx,0) ◄─ NativeCallable.listener ◄─ wakeup callback (mpv thread)
            (debug + main isolate: per-player isolate, 2 port hops/event)

VideoController ─ MethodChannel ─► plugin (platform thread) ─► VideoOutput
  Linux:   mpv update cb ─► mark_texture_frame_available ─► RASTER THREAD populate():
           [mpv_get_property×2 if size unset] makeCurrent(mpv) → mpv_render → blit → glFinish → makeCurrent(Flutter)
  Windows: mpv update cb ─► ThreadPool(1): CheckAndResize + Render (holds mutex_ incl. glFinish)
           RASTER THREAD Read(): same mutex_ → CopyResource(internal→external)
  Android: mpv VO thread renders vo=gpu into the SurfaceProducer Surface (wid) ─► Flutter imports the image
```

### 1.5 Packaging and tests today

**Packages**
- `media_kit`: pure Dart FFI. It vendors a copy of `package:ffi` in `lib/ffi/**` (~1150 lines) and has ffigen bindings (2410 lines).
- `media_kit_video`: the Flutter plugin.
- `media_kit_libs_*`: their only job is to fetch and bundle libmpv.
  - Android: Gradle jars with MD5.
  - Windows: CMake 7z archives with SHA-256.
  - Linux: system libmpv, plus an optional static mimalloc override (`libs/linux/media_kit_libs_linux/linux/CMakeLists.txt:13`, `README.md:1677-1699`).
- The universal meta-packages depend on all five platform packages.

**Tests**
- `media_kit/test/src/player/player_test.dart`: 3237 lines, 77 tests against real mpv.
  - Media is downloaded from GitHub (`test/common/sources_native.dart`).
  - The tests rely on long sleeps.
- `media_kit_test`: a manual demo app.
- `media_kit_video/linux/test/isolated_egl_test.cc`.
- CI: `.github/workflows/ci.yml`, which includes macOS and iOS jobs.

### 1.6 Apple-only code in shared Dart (must not constrain the rewrite)

**Shared Dart branches**
- `PlayerConfiguration.iosManageAudioSession` (`platform_player.dart:467-482, 509`) and its option (`real.dart:2268-2270`).
- Apple branches in `player.dart:113-116`, `media_kit.dart:30-33`, `native_library.dart:52-53,73-76`, `asset_loader.dart:43-66`, `temp_file.dart:29-32`, `video_texture.dart:472-506` (iOS/macOS fullscreen), `adaptive.dart:19-21`.
- `CupertinoVideoControls` is the default only on Apple; it stays as public API and gets no work.

**The one real constraint**
- `NativeVideoController` (`native_video_controller/real.dart:32-36`) is shared by Linux, Windows and Apple.
- Its method-channel protocol is also implemented by `media_kit_video/common/darwin/**/*.swift`.
- Plan: introduce a "protocol v2" for Linux, Windows and Android (§4.0). Darwin stays on v1; Dart sends no `protocol` key on Apple.

**Packaging and CI**
- Keep `media_kit_libs_ios_*` and `media_kit_libs_macos_*` in the universal meta-packages for pubspec compatibility. They only build for Apple targets.
- Set CI jobs `media_kit-tests-macos`, `macos` and `ios` to `continue-on-error: true`. `media_kit/test/ci/macos/**` stays untouched.

---

## 2. Findings

### 2.1 Per-event cost (Dart side, after an event arrives)

The transport is fine:
- release mode uses `NativeCallable.listener` (`initializer.dart:53-57`);
- `PlayerConfiguration.async` defaults to `true` (`platform_player.dart:492`).

An event isolate is therefore **not** proposed. The cost is what `_handler` and the drain loop do.

| ID | Where | Mechanism | Effect |
|---|---|---|---|
| E-1 | `real.dart:1383-1969` | `prop.ref.name.cast<Utf8>().toDartString()` is called up to **21×** per property event: 3 before the init gate (1383, 1391, 1403), the `observedProperties` lookup (1501), then 17 compares. 23 call sites including the hook names. | strlen + UTF-8 decode + a new String each time; about 1260 Strings/s just for `time-pos` at 60 fps. |
| E-2 | 48 `state = state.copyWith` (25 in `_handler`) | Every event allocates a 23-field `PlayerState`. `copyWith` can't reset nullable fields; for example `audioBitrate: null` at 1713 is a no-op. | Allocation and GC churn on the UI isolate. |
| E-3 | `real.dart:1477-1480`, `2485`, `2549` | `_logError(code, 'event:${…} ${…}')` builds an interpolated string for every event even when `code == 0`. `_command`/`_setProperty` build debug text on every call. | 2 or more Strings per event or command. |
| E-4 | `initializer_native_callable.dart:72-81` | Each wakeup goes through `Lock.synchronized`, and each event through `await callback(event)`, even though the common path has no await. | One Future and one closure per event. |
| E-5 | `real.dart:2395`, `material.dart:1593-1599, 2025-2029`, `material_desktop.dart:964-967, 1624-1626` | `time-pos` is unthrottled. It fires about once per video frame and calls `positionController.add`. The seek bar `setState`s and rebuilds a LayoutBuilder/GestureDetector/Stack; the label rebuilds although its text changes once a second. | A UI frame request at the video frame rate. These are separate from the texture's raster-only frames, so on 120 Hz a 60 fps video with visible controls can composite about 120×/s (texture frame and UI frame land in different vsyncs). |
| E-6 | `real.dart:1500-1519` | User-observed properties use `MPV_FORMAT_NONE` plus a **synchronous** `mpv_get_property_string` per change. | A blocking FFI round trip per event, and the value can race. |
| E-7 | `real.dart:2042-2090` | Log events are decoded (3 Strings) and pushed even when nobody listens. | Grows with `logLevel`. |
| E-8 | `real.dart:1260, 1295-1297, 2415` | `reply_userdata` already carries a per-property id (`name.hashCode`) but only replies use it (1442-1458). User `observeProperty` reuses the **same id**, so `unobserveProperty('time-pos')` also removes the internal observer (mpv removes every observer with that id) and `stream.position` stops. | A bug as well as a missed dispatch key. |

Other synchronous FFI work on the UI isolate:
- `mpv_initialize` per Player (`initializer_native_callable.dart:50`);
- `queryDecoders` (the whole `decoder-list` node, `query_decoders.dart:20-66`);
- `getProperty`;
- the AndroidHelper JavaVM spin loop (`android_helper.dart:94-113`);
- asset stat calls in `Media` (`asset_loader.dart:74`).

Debug runs use the isolate transport, so timings from the user's Linux debug loop are not representative of release.

### 2.2 Lifecycle, dispose, crash risks

**L-1: Linux NVIDIA SEGV (most likely mechanism)**

mpv's `render.h` threading rules require three things:
- render functions must never run concurrently on one render context;
- the GL context must be current in the calling thread;
- the render thread must not call non-render libmpv APIs.

The Linux code breaks all three:

1. `video_output_dispose` (platform thread, `video_output.cc:42-99`) does the following in order:
   - sets `destroyed`;
   - clears the update callback (a proper barrier, but only for the callback);
   - unregisters the texture (`fl_texture_registrar_unregister_texture`, 53). That only stops *new* lookups; a populate already running keeps the raw pointer, because Flutter's registrar lookup takes no ref;
   - calls `isolated_egl_enter` (63) and then `mpv_render_context_free` (70) **even if `eglMakeCurrent` failed**. It fails with `EGL_BAD_ACCESS` when the raster thread has the same context current mid-populate;
   - destroys the context (79) and unrefs the TextureGL (83).
2. `texture_gl_populate_texture` (raster thread) does not check `alive` or `render_context`. It also doesn't check any `eglMakeCurrent` result (228, 346, 384). A failed switch therefore makes mpv render with Flutter's context current.
3. `mpv_render_context_free` tears down the decoder and hwdec interop (CUDA–GL on NVIDIA). It needs the GL context current for the entire call.

The window is the full mpv render time on the raster thread, which can be milliseconds to tens of milliseconds with Anime4K. That's consistent with the user's workaround: a sequenced dispose stops video before freeing.

How to confirm: run P0-4 (§4.1) and look at the backtraces with `coredumpctl`. The expected picture is the raster thread in `mpv_render_context_render` or `texture_gl_populate_texture`, and the platform thread in `mpv_render_context_free`.

Secondary suspect, only if the app links `MIMALLOC_LIB`: bisect with mimalloc off.

**L-2: Linux, `mpv_get_property` on the render thread**
- `texture_gl.cc:209-210` calls `video_output_get_width/height` (`video_output.cc:423-521`), which calls `mpv_get_property(video-out-params)`.
- This happens whenever no size is set: at startup, and after `setSize(null)`.
- `render.h` names this as a deadlock hazard ("not a libmpv bug").
- `set_size` (385-401) writes the width and height without synchronization while the raster thread reads them.

**L-3: Windows teardown**
- The destructor (`windows/video_output.cc:111-157`) never clears the update callback. mpv can call `NotifyRender` on a freed `this` until the render context is freed, and that free is posted *last* (154-156).
- `surface_manager_.reset` (129) destroys the EGL context **before** `mpv_render_context_free`, so mpv's GL and hwdec resources are freed with no context current.
- `Dispose` is fire-and-forget on a detached thread (`video_output_manager.cc:43-50`), so Dart can't sequence anything after it.

**L-4: Android teardown**
- `VideoOutput.kt:104-118` releases the Surface and the producer while `vo=gpu` still holds an EGL window surface on it (`force-window=yes`).
- Dart's `_dispose` sets `_disposed` first, so the wid=0 listener can't set `vo=null` (`android_video_controller/real.dart:229-240`).

**L-5: Global hangs from the static lock plus unbounded waits**

Every Player method awaits VideoController init inside the static lock. Three ways that never completes:
- A `VideoController` created when no frame is scheduled (the app is in the background, or the UI is idle) waits forever in `addPostFrameCallback` (`video_controller.dart:79-82`). Every method of every player then waits.
- `NativeVideoController.create` waits for a texture id with no timeout (178).
- If `_create` fails, `waitForPlayerInitialization` never completes, and dispose hangs while holding the global lock.

**L-6: Dispose leftovers**
- `mpv_terminate_destroy` runs 5 s later, synchronously on the UI isolate (`real.dart:114-116`).
  - That's a random hitch 5 s after every dispose.
  - Its order relative to the native render-context free is not guaranteed, because Windows frees asynchronously.
- Pending `_commandRequests` and `_setPropertyRequests` are never completed once the wakeup callback is removed. Callers awaiting `setProperty` or `command` hang.

**L-7: Undefined behavior at the FFI boundary**
- `_setPropertyFlag` allocates `calloc<Bool>(1)` (`real.dart:2501-2505`), but `MPV_FORMAT_FLAG` is a C `int` (see the bindings doc).
  - mpv reads 3 bytes past the allocation.
  - `pause=false` comes out right only if the allocator zeroed the block tail. glibc does; Scudo and the Windows heap don't guarantee it.
- `_screenshot` allocates `args.join().length` bytes, 19 or 23, for 3 pointers, which need 24 (2685). The terminator is out of bounds.
- `_command` uses a fixed 128-slot argv with no bounds check (2539).

**L-8: Late VideoController attach**
- `vo`/`vid` are set **before** the render context exists (`native_video_controller/real.dart:150-154` versus 169-176).
- If a file is already loaded, vo_libmpv fails with "No render context set" and video stays off for that file.

**L-9: Small Linux bugs**
- `get_height` checks `self->width` (`video_output.cc:475`).
- The S/W path's aspect math uses integer division (466, 516).
- `video_output_get_texture_id` calls `g_assert_not_reached()` and aborts when neither texture exists.

**L-10: Windows `SetWindowLongPtr` subclassing** (`media_kit_video_plugin.cc:32,53`)
- It can fight `window_manager`-style plugins over teardown order.
- The supported API is `registrar->RegisterTopLevelWindowProcDelegate`.

**L-11: Linux, a hidden `Video` stalls mpv**
- When the `Video` isn't painted (another opaque route, or not mounted), populate is never called.
- vo_libmpv's `flip_page` then waits up to 200 ms per frame for a render, so video timing breaks while it's hidden.
- Windows and Android are unaffected: they render regardless.

### 2.3 Render paths per platform

| | Linux | Windows | Android (default `vo=gpu`) |
|---|---|---|---|
| Who renders mpv | **Flutter raster thread**, inside populate (`texture_gl.cc:361`) | shared single worker | mpv's VO thread |
| Copies per video frame | mpv FBO, then `glBlitFramebuffer` into the export texture (364-370). This runs whenever GLES ≥ 3, i.e. always, not only on Mesa, which the blit (PR #1464) was added for. | internal → external `CopyResource` on the raster thread (`angle_surface_manager.cc:72-80`) | MediaCodec → (`mediacodec-copy` today: GPU→CPU→GPU, being changed by android-playback) → mpv GLES pass (YUV→RGB, scaling) → SurfaceProducer buffer → Flutter samples it |
| Sync points | `glFinish` per frame on the raster thread (378). The CPU waits for mpv's GPU work, shaders included. Two more on first frame and resize (283, 301). 2 context switches per frame. No fence. | `Draw` holds `mutex_` across the mpv render and `glFinish` (63-70); the raster thread's `Read()` waits on the same mutex, up to one full mpv render | BufferQueue/ImageReader fences (platform) |
| Per-frame mpv queries | `mpv_get_property` × 2 while the size is unset | `GetVideoWidth/Height` (`video_output.cc:421-517`) while the size is unset | — |
| Resize | Same texture id. Realloc on the raster thread. | **New texture id** (285-407): `texture_id_=0`, unregister, register. Blank frame(s) in between. | New Surface (ImageReader backend), new global ref, then the `widListener` VO rebuild + seek (§3.1) |
| Default output size | video dw×dh (the Dart listener); **fixed sizes overwritten** | same | video dw×dh (`SetSurfaceSize`); `setSize` throws (`android_video_controller/real.dart:222-226`) |

Re-composites:
- Every mpv update marks a frame. The engine always schedules a raster frame for it, even when no `Video` is mounted. Hidden or offscreen players keep the raster thread busy.
- Position-driven `setState`s add UI frames that aren't aligned with texture frames (E-5).

Output size consequences:
- The texture size is the video size. 4K in a mini player still renders 4K, shaders included.
- 480p/720p anime in a fullscreen 1440p window renders at 480p/720p, and Flutter bilinear-upscales it.
- Anime4K's upscale passes are gated on output > source (`//!WHEN OUTPUT.w MAIN.w …`), so they never run. An app-side `setSize` gets reset whenever a file of a different resolution loads (L-8 file, lines 75-107).
- On a 2712×1220 phone, a 4K surface is about 2.5× the texels that are actually displayed, and `FilterQuality.low` minifies it with bilinear filtering and no mipmaps, which aliases.

Levers on the landscape overlay cost, which the benchmark measured at 12–15 ms raster p90. Flutter has to composite the texture, and platform views are excluded by the app requirements. What the fork controls:
1. A display-fit surface size: fewer texels and less bandwidth for both the mpv pass and Flutter's sampling.
2. The `Video` widget paints a full-size opaque `Container(color: fill)` under the texture (`video_texture.dart:372-377`). That's one extra full-screen pass per composite.
3. The controls use a full-size scrim (`material.dart:901-903`, `0x66000000` at 307) inside one whole-overlay `AnimatedOpacity` (886). During fades that's a full-size saveLayer; while visible, a full-screen blend.
4. Remove the UI frames that aren't aligned with texture frames (E-5).
5. Use `FilterQuality.none` when the texture maps 1:1.

The fork can't make Flutter's compositor itself cheaper. Measure each lever with the bench (P0-5).

### 2.4 mpv defaults for web streaming

| Option | Today (where) | mpv default | Proposal | Why |
|---|---|---|---|---|
| `demuxer-max-bytes` | 32 MiB (`bufferSize`, `platform_player.dart:497` → `real.dart:2358`) | 150 MiB | desktop 150 MiB; Android standard 64 MiB; feed 48 MiB | 32 MiB holds about 6–10 s of 1440p/4K at 25–40 Mbps. Any dip longer than that is a stall. Keep `bufferSize` as an alias. |
| `demuxer-max-back-bytes` | 32 MiB (2359) | 50 MiB | desktop/watch 64 MiB; Android 16 MiB; feed 8 MiB | Instant backward seeks (watch-together resync). RAM per pooled player. |
| `cache-on-disk` | yes (2338) | no | desktop: **no** | At these sizes the disk file only adds I/O; disk only makes sense for multi-GiB caches with an explicit `demuxer-cache-dir`. Android belongs to android-playback. |
| `cache-secs` / `demuxer-readahead-secs` | unset (1000 h / 1 s) | same | feed: 30 / 30 | Feed max-buffer (§3.5). |
| `demuxer-hysteresis-secs` | unset (0) | 0 | mobile/feed 15 | Min-buffer: reading stops at max and resumes below 15 s, so the radio can sleep. |
| `cache-pause-wait` | unset (1 s) | 1 | mobile 2, feed 1.5 | After a stall, 1 s of 4K is gone in 1 s, which gives stall/resume loops. |
| `cache-pause-initial` | unset (no) | no | feed: yes, only for items that weren't preloaded | Start threshold; trades against TTFF. |
| `network-timeout` | **5** (2331) | 60 | 20 | ffmpeg's rw timeout. A 5 s Wi-Fi/LTE handover becomes a read error, then demuxer EOF, then `completed=true` mid-video. |
| `stream-lavf-o` | unset | — | `reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5` | Progressive HTTP reconnects at the current offset instead of ending. Never `reconnect_at_eof`. HLS keeps `seg_max_retry=5` (2362). |
| `demuxer-lavf-probesize` / `-analyzeduration` | unset (lavf: 5 MB / 5 s) | 0 | bench-gated; candidate HLS/TS `analyzeduration=1` | TS-based HLS can read more than one segment in find_stream_info. Measure before changing. |
| `hr-seek-framedrop` | **no** (2340) | yes | yes | `no` forces a full decode of every frame up to the target, up to ~240 frames per seek on 2–4 s GOP 4K HEVC. |
| `hr-seek` | yes (2339) | default | keep; add a keyframe mode for scrubbing (P4-6) | All API seeks are absolute anyway. |
| `tls-verify` / `tls-ca-file` | unset (= no) | no | desktop yes + system bundle; Android opt-in with a bundled CA PEM | Certificates aren't checked today. No TTFF effect. |
| `scale`/`dscale`=bilinear, `dither`=no, `correct-`/`linear-downscaling`=no, `sigmoid-upscaling`=no, `hdr-compute-peak`=no (2334-2344) | all platforms | mpv defaults | Android: keep (fast). Desktop: mpv defaults. | An 8-bit RGBA target with dither off bands on 10-bit and anime gradients; the GTX 1080 has the headroom. |
| `hwdec` (desktop) | auto (`native_video_controller/real.dart:118`) | no | auto-safe | mpv's recommended value. |
| `video-timing-offset` | 0 on Windows (`video_output.cc:37`), default on Linux | 0.05 | measure | How early mpv hands frames to the renderer. |
| `ao` (Android) | opensles (2345-2350) | — | test `audiotrack,opensles` | A/V-sync timing affects drops and repeats (P2-A3). |
| `prefetch-playlist` | unset | no | yes, for single-player playlists | The next entry opens early. |
| `hls-bitrate` | unset (max) | max | expose it; choose by network | mpv has no ABR; the initial variant choice is the only lever. |
| HTTP persistent connections | ffmpeg default | — | no change | On HTTP/1.1 a mid-body seek must reconnect anyway; HLS already uses `http_persistent`. |

The bigger TTFF levers are not options:
- the open() round trips (P2-E4);
- the `on_load` hook round trip (P2-E4);
- VideoController init gating every call (P1-V2);
- cross-player lock contention (P1-C2).

### 2.5 Duplication and dead code

**Duplication**
- The rotate + dw/dh → width/height logic exists in 7 copies:
  - `real.dart:2018-2039`;
  - `native_video_controller/real.dart:83-92`;
  - `android_video_controller/real.dart:101-110`;
  - Linux `get_width`/`get_height`, 2 copies;
  - Windows `GetVideoWidth`/`GetVideoHeight`, 2 copies.
- The Native and Android controllers duplicate:
  - `setProperty`/`setProperties`;
  - the static `_controllers` map;
  - a static `MethodChannel` on the **same channel name**, each with a `VideoOutput.Resize` handler (whichever initializes last wins);
  - the decoder gate;
  - `_dispose`.
- The `synchronized` / disposed / init-wait boilerplate is repeated in about 25 NativePlayer methods.
- Track construction is repeated 3× (`real.dart:1832-1904`).
- The screenshot JPEG and PNG loops are duplicated (2729-2757).
- Emulator detection exists twice: FFI `AndroidHelper.isEmulator` and the Kotlin `Utils.isEmulator` channel call (`android_video_controller/real.dart:149`).
- `lib/ffi/**` is a vendored copy of `package:ffi`.

**Dead code**
- `VideoControllerConfiguration.androidAttachSurfaceAfterVideoParameters` (`platform_video_controller.dart:116`) is never read.
- The Android `VideoOutput.WaitUntilFirstFrameRenderedNotify` handler (`android_video_controller/real.dart:270-281`) handles a message Kotlin never sends.
- On Linux:
  - `egl_surface` is never created;
  - `video_output_get_gdk_gl_context` is declared but never defined;
  - the `view` parameter of `video_output_new` is unused.
- `VideoState.refreshView() {}` is empty.
- The `speed` observation has no handler.
- The resets in `stop()` are commented out (288-323).
- Keep the `legacy.dart` typedefs for compatibility.

### 2.6 API gaps for real apps

- **Multiple players**
  - The static lock.
  - Windows renders every player on one worker.
  - The Linux plugin leaks one struct per output.
  - No decoder budget (§3.3).
- **Preload / warm start**
  - None.
  - VideoController creation waits for a frame and gates every Player call.
- **PiP (Android)**: none. The lifecycle handling only pauses on `paused`/`detached`.
- **Shaders and filters**
  - Only raw properties.
  - Output size = video size starves upscalers.
- **Tracks**
  - The selected track is optimistic Dart state, not synced from mpv's `current-tracks/*`.
  - The equality and `distinct` bug.
  - No secondary sid.
  - No control over HLS variants.
- **Stats**: none (`hwdec-current`, `frame-drop-count`, `decoder-frame-drop-count`, `vo-delayed-frame-count`, `cache-speed`, `demuxer-cache-state`, `avsync`, `vo-passes`).
- **Errors**
  - Scraped from strings (`real.dart:2052-2087`).
  - No END_FILE reason or code.
- **First frame per load**: none (§3.4).
- **Fast seek or scrub mode**: none.
- **Async exact getters**: `getProperty` is synchronous.
- **Android audio focus / becoming-noisy**: none. Optional.

### 2.7 Notes for the `android-playback` branch (found in its files; not re-planned)

1. `widListener` (51-88) reacts to *value* changes of `wid`. `VideoOutput.kt:142` mints a new global ref on every `onSurfaceAvailable`/`setSurfaceSize`, so even a resize that keeps the same Surface object looks like a new wid, and gets a full VO rebuild plus a seek. Old refs are only deleted on cleanup, so they leak.
2. The `create()` property batch (197-209: `vo=null`, `gpu-context`, `opengl-es`, `force-window`, …) is not under the same lock as `widListener`. Both await one item at a time and interleave. `vo=gpu` can initialize before `gpu-context`/`opengl-es` are set, or create's `vo=null` can land after the listener's `vo=gpu`.
3. "First frame" completes on video-params (134-136), not on a frame. The native notify path is dead (270-281).
4. Teardown order is L-4.
5. The `_setPropertyFlag` undefined behavior (L-7) can make `pause=false` read as `true` on Android's allocator. Keep it in mind when interpreting startup-rate measurements.
6. The hwdec default needs an extra channel call (149). `AndroidHelper.isEmulator` already exists through FFI.

---

## 3. Feed and animation (PageView swipe or dismiss, inline ListView, mini-player)

These apps animate the video itself, so everything stays on **textures**; platform views are out.

### 3.1 Resize policy during size animations

**Today**
- Desktop never resizes with the widget. The output size is the video size, so animations are free, but the resolution is wrong.
- Android sets the surface to video dw×dh on video-params (96-138). Any `wid` change runs `widListener`: `vo=null` → `android-surface-size` → `wid` → `vo=gpu` → `seek(state.position)`. Because of 2.7.1, every resize becomes a VO rebuild plus a seek to a possibly stale position. A surface that followed a size animation would run that rebuild once per frame.

**Proposed policy**
- **Decouple render size from layout size.** During an animation, Flutter scales the existing texture (`FittedBox` already does this). Nothing native happens per frame.
- **Settle, then resize.**
  - `Video` reports its physical size (layout × DPR) only after it has been stable for about 200 ms.
  - Or the app gives an explicit hint: `controller.setSizeHint(animating: true/false)`, for mini-player or PageView-driven animations.
  - **Grow early, shrink late:** jump to the end size as soon as it's known (mini → full), and shrink only after the size settles.
- **Buckets.** Snap the longer edge to {360, 540, 720, 1080, 1440, 2160}, capped at the video size. Small scale changes, such as a 2% swipe zoom, never resize.
- **Android: one size per media.**
  - The size is the video size fitted into the display's *landscape* physical size, computed once at load.
  - No resize on rotation, swipe or mini-player.
  - An explicit `setSize` is honoured only between media or while paused.
  - When a resize is unavoidable:
    - if the Surface object is unchanged (SurfaceTexture backend), set only `android-surface-size`;
    - if it changed (ImageReader backend under Impeller), re-attach **without** a seek. That's a requirement on android-playback's fix.
- **Desktop.**
  - A Linux resize reallocates the FBO and EGLImage and keeps the texture id.
  - A Windows resize currently changes the texture id and shows a blank frame (fix: P2-W2).
  - Both resize only on settle.
- Tasks: P2-U3 (widget policy), P2-A1, P2-L3, P2-W2.

### 3.2 One Player/texture across subtrees (mini-player)

**What works today**
- The texture and native output belong to the Player: the platform part is disposed only through `Player.dispose` → `release`.
- `Video` is a view. Mounting `Video(controller: c)` elsewhere reuses the texture id, with no re-open.
- Two simultaneous views (a Hero flight, the fullscreen route) composite the same texture twice. That's acceptable for a transition.

**Pitfalls**
1. `VideoController.dispose()` disposes `id`/`rect`/`notifier` (139-143) while another `Video` may still listen. The controller must be owned above both subtrees.
2. Lifecycle handling is per widget (`video_texture.dart:279-299`). Two views mean duplicated pause/resume.
3. With no view mounted, mpv still renders and marks frames. On Linux that also stalls mpv's VO (L-11).
4. Android background/foreground causes a surface cleanup and then a rebuild + seek. That's android-playback's area.

**Proposal**
- `Video` attaches to and detaches from its `VideoController` (refcounted).
- When the count reaches 0, native skips rendering and stops marking frames (P2-U2 via `SetVisible`; Linux keeps calling render with `SKIP_RENDERING=1` so mpv's timing holds).
- Background policy moves to the controller, deduplicated (P1-V2).
- Documented pattern: Player and VideoController are owned by an app-level object, and `Video(key: GlobalObjectKey(controller))` reparents with its state.

### 3.3 Player pool / reuse for feeds and PageViews

**What a fresh player costs today**
- `mpv_initialize` (synchronous, on the UI isolate).
- VideoController creation: a post-frame wait, the `decoder-list` query, `Create`, and about 10 property round trips on Android.
- The first `open()`, with its temp file and `loadlist`.

Reuse saves all of it.

**The static lock** means preloading a neighbour (its `open()` waiting on its own VideoController) blocks play/pause/seek on the *current* item. P1-C2 is a prerequisite.

**Decoder budget**
- This phone supports **6 concurrent VP9** hardware decoders and **16 H.264/HEVC**.
- Every player with a loaded video track (`vid≠no`) and `hwdec=mediacodec*` holds a MediaCodec instance, even while paused.
- Past the limit, mpv falls back to software. On this SoC, 1440p VP9 in software drops frames.
- Budget per codec = limit − 1. Query `MediaCodecInfo.CodecCapabilities.getMaxSupportedInstances()` per MIME type through a new Kotlin call, with conservative fallbacks.

**Memory per pooled Android player at today's defaults**
- Up to 32 + 32 MiB of demuxer cache.
- 3–4 ImageReader buffers at video size (4K RGBA ≈ 33 MB each).
- MediaCodec buffers on top.
- With display-fit size (§3.1) and the feed preset (§3.5), that drops to roughly a third.

**Pool design** (P4-5)
- N fixed Player + VideoController pairs; default 3: previous, current, next.
- `acquire(index)` recycles the farthest slot with `loadfile … replace` (the P2-E4 fast path). Nothing is disposed while scrolling.
- Slot states:
  - current: `vid=auto`, playing;
  - next (and optionally previous): **preroll**, paused on the first frame, if the decoder budget allows; otherwise network preload (cache only) plus a poster;
  - everything else: `stop`, which keeps the player and frees the decoder and cache.

### 3.4 Poster, first frame, preload

**Today `waitUntilFirstFrameRendered` is unusable for feeds:**
- it completes once per controller lifetime (`platform_video_controller.dart:49-55`, never reset);
- on Linux it completes on the 1×1 placeholder;
- on Android it completes on video-params.

**Proposal** (P4-2): a per-load `firstFrame` signal.
- Linux and Windows: native reports the first render that has valid `video-out-params` after `FILE_LOADED`, tagged with a generation counter.
- Android: `vo=gpu` renders without a client callback, so the signal is `PLAYBACK_RESTART` after the load, plus `vo-configured`.
- `Video(placeholder: …)` shows the poster until the signal arrives. That also covers today's 1×1 and black phase.

**Preload levels**
| Level | What it holds | Cost when the item becomes current |
|---|---|---|
| Preroll | decoder + surface | instant swipe |
| Network preload | cache only | decoder init, roughly 100–300 ms |
| None | poster only | full open |

`prefetch-playlist` only helps single-player playlists.

### 3.5 Feed buffer presets

The user's native player uses min 15 s, max 30 s, start at 1.5 s. Mapping to mpv:

| Native setting | mpv equivalent |
|---|---|
| max 30 s | `cache-secs=30` + `demuxer-readahead-secs=30`, plus a byte cap `demuxer-max-bytes` (e.g. 48 MiB per pooled player) |
| min 15 s | `demuxer-hysteresis-secs=15`: reading stops at 30 s and resumes below 15 s |
| start 1.5 s | `cache-pause-initial=yes` + `cache-pause-wait=1.5`. mpv uses this one value for both start and resume-after-stall; ExoPlayer has two. |
| back buffer | `demuxer-max-back-bytes=8 MiB`; feeds rarely seek back |

- All of these are runtime properties, so the preset can change per slot. A neighbour can sit at max 5 s until it becomes current.
- Presets: `standard` (fixed defaults), `feed`, `longform/watch` (desktop, large back buffer for sync seeks). API: P2-N1.

### 3.6 Controls that are cheap to composite

Each rule below names today's offender in the bundled controls:

| Rule | Today | Change |
|---|---|---|
| Position at UI rate | `setState` per frame (`material.dart:1593-1599, 2025-2029`; `material_desktop.dart:964-967, 1624-1626`) | The label updates on second boundaries. The seek bar repaints only when the thumb moves ≥ 1 physical px (interval = duration / bar width px, capped at 30 Hz). No Ticker at display rate (P2-E3, P2-U1). |
| No full-overlay Opacity saveLayer | one `AnimatedOpacity` around the whole overlay plus the scrim (886-903) | `FadeTransition` on small groups (top bar, bottom bar); animate the scrim's alpha inside its colour, which is a single draw with no layer. |
| No BackdropFilter over video | none in the bundled controls | Flag it for custom controls: a blur re-reads and blurs the video every composite. |
| Small gradients, not full-screen scrims | full-size `0x66000000` (307, 901-903) | Top and bottom gradient bands, about 20% of the height. |
| RepaintBoundary placement | none | Around the seek bar + time label, and around the static button bars. **Not** around the Texture, which is already its own layer. Impeller has no raster cache, so boundaries save UI-thread paint work, not compositing. |
| No continuous animation while idle | the spinner is mounted only while buffering (1120-1147) | Keep it that way. No Ticker-driven bar. Hidden controls unmount (already `mount`). |
| Drag seeking | `seek` on every pointer move (1631; desktop 999) | Keyframe seeks throttled to ≤ 10/s while dragging, one precise seek on release. |

### 3.7 Textures composited during a swipe; keeping neighbours cheap

**How many textures are composited**
- PageView (`viewportFraction` 1): 2 pages are visible mid-swipe, so 2 textures. Together that's about one screen of texels.
- `viewportFraction` < 1: 3 textures.
- Inline ListView: one per visible item.
- A mini-player adds one.

**Extra raster frames**
- Every *playing* texture adds raster frames at its own frame rate, unsynchronized with the others.
- Two 30 fps videos give about 60 extra composites/s at random phases, on top of the 120 Hz swipe.

**Keeping neighbours cheap**
- A neighbour is either a paused preroll or a poster `Image`. A paused texture produces no new frames: it is sampled, never re-imported.
- Items at ±2 and beyond are posters.
- In lists, only one video plays: the most visible one.
- Overlays per item stay minimal (no per-page scrims).
- Surfaces use bucketed sizes: an inline item that is 1220 px wide gets ≤ 720p.
- Items within `cacheExtent` are laid out but not painted, so they're not composited. Their players still render, so pause or stop them; visibility reporting is P2-U2.

### 3.8 The mpv render pass versus direct decoder output

- `better_native_video_player`'s texture mode has ExoPlayer/MediaCodec write straight into a SurfaceProducer.
- media_kit's default goes MediaCodec → **mpv GLES pass** (YUV→RGB and scaling, into the SurfaceProducer) → Flutter composite. That pass costs GPU time and bandwidth per video frame. It isn't raster-thread time, which is why the bench's raster numbers didn't move with `mediacodec_embed`. It matters for battery, thermals, and multi-player feeds.
- `vo=mediacodec_embed` is mpv's direct path, with limits:
  - it fails on AV1 and any software decode (the bench saw one frame, then a stall);
  - there are no mpv subtitles, OSD, shaders or screenshots.
- P2-A2 (experiment): in feed mode, choose per media. Hardware-decodable codecs (H.264, HEVC, VP9 on this phone) get `mediacodec_embed`; everything else gets `vo=gpu`. Decide before the load. Adopt it only if the bench shows a GPU-time, PSS or battery win.

---

## 4. Phased plan

### 4.0 Lanes, file locks, cross-lane contract

| Lane | Owns | Notes |
|---|---|---|
| TEST | `media_kit/test/**`, `media_kit/benchmark/**` (new), `media_kit/tool/**` (new), `media_kit_test/integration_test/**` (new), `media_kit_video/test/**` (new), `.github/workflows/**` | Plus a one-line test hook in `native/core/initializer.dart` (P0-2). |
| LNX | `media_kit_video/linux/**` | |
| WIN | `media_kit_video/windows/**` | |
| VCTL | `media_kit_video/lib/src/video_controller/{video_controller.dart, platform_video_controller.dart, native_video_controller/**}`, `media_kit_video/lib/src/utils/**`, `media_kit/lib/src/player/platform_player.dart` (P1-T1 only) | |
| CORE | `media_kit/lib/src/**` (`player/native/**`, `platform_player.dart`, `models/**`) | One agent at a time until the P1-C0 split. |
| AND | `media_kit_video/android/**`, `android_video_controller/real.dart`, `libs/android/**` | After android-playback merges; coordinate. |
| UI | `media_kit_video/lib/media_kit_video_controls/**`, `media_kit_video/lib/src/video/**`, `media_kit_video/lib/src/subtitle/**` | |
| PKG | `libs/**`, `media_kit/hook/**` (new), pubspecs | Phase 3. |

**Locked until `android-playback` merges:**
- `media_kit/lib/src/player/native/player/real.dart`;
- `media_kit_video/lib/src/video_controller/android_video_controller/real.dart`;
- probably also `native/utils/android_helper.dart`, `temp_file.dart` and the Kotlin `VideoOutput.kt`, if the cache-dir or surface fixes touch them. Check with that agent.

**Video-output protocol v2** (Linux, Windows, Android; Darwin stays on v1). Natives implement it; VCTL and CORE consume it.

| Message | Direction | Semantics |
|---|---|---|
| `VideoOutputManager.Create {handle, protocol: 2, width?, height?, enableHardwareAcceleration}` | Dart → native | Returns `{id, width, height}` only once the texture is registered. Windows currently returns before the output exists. |
| `VideoOutputManager.SetSize {handle, width?, height?}` | Dart → native | Dart supplies the size; native never queries mpv for it on a render thread. |
| `VideoOutputManager.SetVisible {handle, visible}` (new) | Dart → native | Skip rendering and stop marking frames while nothing is attached. |
| `VideoOutputManager.Dispose {handle}` | Dart → native | Returns only after the render context is freed and the texture unregistered; on Android, after the Surface is released with mpv detached. |
| `VideoOutput.Resize {handle, id, rect}` | native → Dart | Unchanged. |
| `VideoOutput.FirstFrame {handle, generation}` (new) | native → Dart | §3.4. |
| `VideoOutput.DeviceLost {handle}` (new) | native → Dart | Replaces Windows' `id=0` convention. |

### 4.1 Phase 0: test and measurement infrastructure (all lane TEST unless noted; can start now)

**P0-1 — Deterministic media and a local HTTP server** (M, risk low)
- Files (new):
  - `media_kit/tool/gen_test_media.sh` (ffmpeg lavfi);
  - `media_kit/test/common/media_server.dart`;
  - a rewrite of `media_kit/test/common/sources_native.dart` (no more GitHub downloads).
- Media: 720p60 H.264/AAC (faststart and non-faststart), 1440p60 HEVC, VP9 webm, an mkv with 2 audio tracks + srt, audio-only m4a, HLS with 2 s segments, a truncated mp4.
- Server (`dart:io`):
  - Range and HEAD support;
  - injected latency and a bandwidth cap;
  - a dropped connection after N bytes;
  - a 10 s stall;
  - 403 and 404 responses;
  - a header-echo endpoint.
- Verify: the existing `player_test.dart` passes against the fixtures on Linux.

**P0-2 — Headless lifecycle and leak suite** (M, risk low)
- Files (new):
  - `media_kit/test/src/player/lifecycle_test.dart`;
  - `media_kit/test/common/leak_probe.dart` (thread count from `/proc/self/task`, fd count from `/proc/self/fd`, VmRSS);
  - `media_kit/test/common/waits.dart` (event-driven waits with timeouts, replacing the sleeps);
  - one `@visibleForTesting` transport override in `initializer.dart`, so both NativeCallable and the isolate are tested.
- Cases:
  - create → dispose ×200;
  - open → dispose immediately;
  - dispose during open, during a seek, during the `on_load` hook;
  - double dispose;
  - every method after dispose throws and never hangs;
  - 8 players opening, seeking and disposing interleaved, asserting that player B's `play()` latency is not bounded by player A's `open()` (static lock);
  - headers reach the server;
  - 404 and corrupt files raise exactly one error and no `completed`;
  - `observeProperty('time-pos')` then `unobserveProperty` keeps `stream.position` alive.
- Cases that fail today are marked skip-with-reason and point at their fix: P1-C2, P1-C3, P1-C4, P1-C5.
- Verify: runs in under 5 minutes, deterministic over 20 runs, `vo=null`/`ao=null`, no display.

**P0-3 — Event-path micro-benchmark** (S/M, risk low)
- Files (new): `media_kit/benchmark/event_path_bench.dart`; results in `media_kit/benchmark/results/<sha>.json`.
- Black-box design: it needs no source change, so it runs unchanged on every branch.
- Workload: a local 720p60 clip, `NativePlayer.test=true` (`vo=null`, `ao=null`), `loop-file=inf`.
  - Throughput mode: `untimed=yes`, so mpv emits events as fast as the Dart side drains them.
  - Real-time mode: 60 fps for 20 s, with one `stream.position` listener plus a counting fake seek-bar listener.
- Event count: an `observeEvent(MPV_EVENT_PROPERTY_CHANGE)` counter. It adds a constant overhead to both runs.
- Allocations: run JIT with `--enable-vm-service` and connect to its own VM service.
  - `getAllocationProfile(reset: true, gc: true)` after a warm-up, then again after N seconds.
  - Report `instancesAccumulated` and `accumulatedSize` per event for `_OneByteString`/String, `PlayerState`, `Duration`, `_Future`, closures, and the total.
- Time: `getCpuSamples` over the window.
  - Inclusive samples in `NativePlayer._handler` and `InitializerNativeCallable._callback` → µs per event.
  - Plus events/s in throughput mode.
  - A second AOT build (`dart compile exe`) gives wall-clock throughput without the VM service.
- Runs:
  - (A) on `integration` now;
  - (B) on the android-playback-merged base;
  - (C) after P2-E1–E3. The Phase 2 targets in §4.3 are checked here.
- Plus a synthetic dispatcher bench (P2-E1b) once the dispatcher is a pure function.

**P0-4 — Linux Flutter teardown stress** (M, risk low)
- Files (new): `media_kit_test/integration_test/video_lifecycle_test.dart`, plus the `integration_test` dev dependency.
- Loop ×100:
  1. Create Player + VideoController + `Video`.
  2. Open the 1440p60 HEVC clip. Optionally add a `glsl-shaders` Anime4K path from an environment variable.
  3. Wait a random 0–2 s, so the dispose lands before the first frame, mid-play, mid-seek or mid-`setSize`.
  4. Dispose *unsequenced*.
- Variants: `Video` still mounted versus unmounted first.
- Run with `flutter test integration_test -d linux` on the NVIDIA box (manual), Wayland and X11, and under Xvfb + llvmpipe in CI.
- Capture the exit code and `coredumpctl` backtraces.
- Verify: it reproduces the SEGV on `integration`, and passes after P1-L1 + P1-C3.

**P0-5 — Android bench as a regression tool** (M, risk low; the bench repo, not read in this audit)
- Dependency switch to a path or git ref of the fork, chosen by a define, so A/B runs are trivial.
- Metrics:
  - TTFF, open → first frame (PLAYBACK_RESTART through `observeEvent` until P4-2);
  - seek latency;
  - stalls (`paused-for-cache` count and time);
  - `hwdec-current`;
  - `frame-drop-count` and `decoder-frame-drop-count`;
  - FrameTiming build and raster p50/p90/p99;
  - PSS.
- Scenarios:
  - LAN HTTP streaming with throttling;
  - PageView feed with 3 players and automatic swipes;
  - mini-player resize animation;
  - inline list with 3 visible items;
  - surface-size variants;
  - overlay variants (bundled controls, gradient bands, no fill).
- A compare script with thresholds that fails the run on regression: raster p90 +10%, TTFF +15%, drops +2 per run.

**P0-6 — Controls rebuild-rate test** (S, risk low)
- File (new): `media_kit_video/test/controls_rate_test.dart` (flutter_test).
- A fake `PlatformPlayer` is injected through `Player(platformPlayer:)` and emits 60 Hz positions.
- Count rebuilds per widget type with `debugOnRebuildDirtyWidget`, and count scheduled frames.
- Baseline today: about 60/s for the seek bar and the label. Target after P2-U1: label ≤ 1/s, seek bar 0 rebuilds.

**P0-7 — CI** (S, risk low)
- Linux headless suites and the Windows build are gating.
- macOS and iOS jobs get `continue-on-error: true`.

### 4.2 Phase 1: correctness (beyond android-playback)

Startable now:

**P1-L1 — Linux render/teardown synchronization** (M, risk med, lane LNX)
- Files: `linux/video_output.cc`, `linux/texture_gl.cc`, `include/media_kit_video/{video_output,texture_gl}.h`.
- Shared state: a `GMutex render_mutex` and an atomic `alive` flag on `VideoOutput`.
- populate:
  1. Lock.
  2. If `!alive` or there's no render context, return the last name or 1×1 and do no GL.
  3. `eglMakeCurrent`, checked; bail out on failure.
  4. Render.
  5. Restore Flutter's context.
  6. Unlock.
- dispose:
  1. Clear the update callback (a barrier).
  2. Lock.
  3. `alive = FALSE`.
  4. Unregister the texture.
  5. Make the isolated context current on the platform thread. Nobody else can have it current now, because populate always restores Flutter's context before unlocking.
  6. `mpv_render_context_free`, then the GL deletes.
  7. Leave the context, unlock.
  8. **Defer** the final unref of `TextureGL`/`VideoOutput` (about 1 s, or until the next populate), so a populate that already holds the raw pointer can still lock and see `alive = FALSE`.
- The width and height move under the same mutex. populate stops calling `mpv_get_property`: the size comes from Dart, with 1×1 until then (fixes L-2).
- Verify: P0-4 ×100 on NVIDIA Wayland and X11, and on llvmpipe. No SEGV, no GL errors, a correct picture after resize.

**P1-L2 — Linux small fixes** (S, risk low, lane LNX, after L1)
- The `get_height` typo (`video_output.cc:475`).
- The S/W integer division (466, 516).
- The callback-data leak (`media_kit_video_plugin.cc:67-71`): free it on Dispose.
- Remove the dead `egl_surface`/`view`.
- Graceful failure instead of `g_assert_not_reached`.

**P1-W1 — Windows teardown order and awaitable dispose** (M, risk med, lane WIN)
- Files: `windows/video_output.{cc,h}`, `video_output_manager.{cc,h}`, `media_kit_video_plugin.cc`.
- New order:
  1. Clear the update callback first (synchronous inside mpv).
  2. Drain the tasks already queued.
  3. Free the render context on the worker with the ANGLE context current.
  4. Reset the surface manager.
  5. Only then answer the Dart call: the `result` moves into the task (protocol v2).
- Replace the `SetWindowLongPtr` subclassing with `RegisterTopLevelWindowProcDelegate`.
- Verify: P0-4 ported to Windows (manual) ×100. Optionally PageHeap.

**P1-V1 — NativeVideoController correctness** (S, risk low, lane VCTL)
- File: `native_video_controller/real.dart`.
1. The videoParams listener must not override a fixed size: skip when `width`/`height` are set (75-107).
2. Create the native output first, then set `vo`/`hwdec`/`vid` (fixes L-8).
3. Ignore rects ≤ 1×1 for the first-frame signal (255-261).
4. A 10 s timeout on the texture id (178).
5. Await the native Dispose result (protocol v2, with a fallback for v1).

**P1-V2 — VideoController init never blocks the Player** (S, risk low, lane VCTL)
- Files: `video_controller.dart`, `platform_video_controller.dart`.
- Replace the per-controller `addPostFrameCallback` (79-82) with `WidgetsBinding.instance.waitUntilFirstFrameRasterized`, which completes once per app.
- Bound the total wait.
- Always complete `videoControllerCompleter`, with an error on failure.
- Make the first-frame completer resettable per load (preparation for P4-2).
- Deduplicate background handling at the controller.
- Verify: a P0-2 case that creates a VideoController with no frame scheduled.

**P1-Q1 — `queryDecoders` off the UI isolate** (S, risk low, lane VCTL)
- `utils/query_decoders.dart`: move the work into `Isolate.run`.

**P1-T1 — Track updates no longer dropped** (S, risk low, lane VCTL; one-off edit)
- `platform_player.dart:95-97`: the tracks `distinct` compares full content.
- Keep `Track.==` by id, for dropdown compatibility.

After android-playback merges (lane CORE, one owner):

**P1-C0 — Split `real.dart` into `part` files** (S/M, risk low, needs the user's OK: it's a structural change)
- Files: `real.dart` (API) plus `real_events.dart` (`_handler`), `real_create.dart` (options and observers), `real_ffi.dart` (set/command/log), `real_isolate_tasks.dart` (screenshot, playlist).
- `part` files keep library privacy, so the split is mechanical. No behavior change.
- It unlocks parallel agents for events versus options versus dispose.

**P1-C1 — FFI memory safety** (S, risk low)
- Flags as `Int32` (2501-2505).
- Screenshot argv `calloc<Pointer<Utf8>>(n+1)` (2685).
- `_command` argv sized `n+1` (2539).
- Verify: a round-trip test (`pause` set, then read back as a string, 10k times on a dirtied heap), plus review.

**P1-C2 — Per-instance lock, bounded waits, failed pending calls** (S/M, risk med: the static `lock` is technically public)
- The lock becomes an instance field.
- The waits for player init and VC init get timeouts. A failed `_create` makes calls throw, and dispose still works.
- Dispose completes every pending completer with an error.
- Verify: the P0-2 multi-player latency and hang cases.

**P1-C4 — Observer id namespaces** (S, risk low)
- Internal observers get dense ids 1..N. User observers get ids from a separate counter (≥ 2^40).
- User observers use `MPV_FORMAT_STRING`, so there's no synchronous get (fixes E-6 and E-8).

**P1-C5 — Load signals and errors** (M, risk med: changes `completed`/`error` semantics)
- Handle `MPV_EVENT_END_FILE`:
  - reason ERROR: emit `mpv_error_string(error)` on `stream.error`, set buffering to false, never set `completed`;
  - EOF, STOP and REDIRECT get their own correct semantics.
- `FILE_LOADED` bumps a load-generation counter.
- `PLAYBACK_RESTART` marks seek done and first frame ready.
- Log-scraped errors stay, deduplicated against these.
- Verify: P0-1 server 404, 403, corrupt file and timeout each give exactly one error.

**P1-N1 — Network resilience** (S, risk low)
- `network-timeout` 5 → 20, configurable.
- The `stream-lavf-o` reconnect flags (§2.4).
- Verify: with the P0-1 server's mid-stream drop and 10 s stall, playback resumes with no `completed`.

**P1-A1 — Android teardown and global-ref hygiene** (M, risk med, lane AND; coordinate with the android-playback owner)
- Files: `VideoOutput.kt`, `android_video_controller/real.dart`.
- Reuse one global ref while the Surface object is unchanged. Delete the previous ref when it changes.
- `_dispose` first sets `vo=null` and awaits it, then calls `Dispose`; the producer is released after mpv detaches.
- Verify: 50 open/dispose cycles with logcat free of BufferQueue-abandoned and EGL errors; TTFF unchanged.

**P1-C3 — Deterministic dispose** (M, risk med; CORE, after C2, L1, W1, V1 and A1)
1. Reject new calls.
2. Pipelined `stop`.
3. On Android, `vo=null`.
4. Await the native output's Dispose (v2).
5. Remove the wakeup callback.
6. Fail any pending requests.
7. `mpv_terminate_destroy` in `Isolate.run`; drop the 5 s timer.
8. Close the streams last.
- Verify: in the P0-2 leak probe, threads and fds return to baseline within 1 s; P0-4 ×100 passes.

**P1-A2 — Bound the AndroidHelper JavaVM spin loop** (S, risk low, low priority)
- `android_helper.dart:94-113`.

### 4.3 Phase 2: performance

**Lane CORE.** The `E*` and `N*` tasks touch the file `android-playback` is editing, so they **wait for that branch**. After P1-C0, `E*` (the events part) and `N1` (the create part) can run as separate agents.

**P2-E1 — Dispatch on `reply_userdata`; emit only changed fields** (M, risk med)
- Files: `real_events.dart`, `real_create.dart`, `initializer_native_callable.dart`.
- A const table `[(id, name, format, handler)]`, observed with `id = index + 1`.
- PROPERTY_CHANGE does `table[reply_userdata](prop)`, with no name decode on the hot path. User ids go through a HashMap.
- Handlers compare against the current field and return early when the value is unchanged.
- Handlers return a Future only when they really await (hooks, user callbacks). The drain loop awaits only then.
- `_logError` takes a closure for its text.
- Logs are decoded only when `logController.hasListener`.
- **P2-E1b:** a synthetic dispatcher bench. Fake `mpv_event` structs are fed straight to the dispatcher: 1M time-pos events, plus video-params and track-list. It reports ns/event and allocations per event.
- Targets, checked with P0-3 (C) against (B):
  - time-pos events: 0 String allocations, ≤ 1 small object (or 0 if position is stored as int microseconds);
  - CPU per event at least 3× lower;
  - `player_test.dart` green.

**P2-E2 — Lazy `PlayerState`** (M, risk med)
- Files: `platform_player.dart` (the `state` field becomes a getter/setter), `real_events.dart`, `web/player/real.dart` (must keep compiling).
- Mutable internal fields. The immutable snapshot is built on read and cached until the next change.
- Target: no `PlayerState` allocation per event unless `state` is read.

**P2-E3 — UI-rate position** (M, risk low/med)
- Files: `models/position_clock.dart` (new), `platform_player.dart`, `real_events.dart`, `media_kit_video/lib/src/utils/position_listenable.dart` (new).
- Core:
  - `stream.positionClock` emits only on discontinuities: seek, pause or play, rate, buffering, new file, drift > 50 ms;
  - `PositionClock.positionAt(monotonicMicros)` interpolates;
  - optional `PlayerConfiguration.positionUpdateInterval` throttles `stream.position`; the default (`null`) keeps today's behavior.
- Exact position on demand:
  - `state.position` (last event, at most one frame old);
  - `Future<Duration> queryPosition()` (async `time-pos`).
- media_kit_video: a listenable that ticks only when the displayed value changes (a pixel step or a second boundary). This also suits watch-together sync.

**P2-E4 — TTFF fast path** (M, risk med: mpv versions differ)
- Files: `real.dart` (`open`/`stop`), `real_ffi.dart` (a batch that issues N async requests, then awaits them all), the controllers' create batches.
- A single Media becomes `loadfile <url> replace` with per-file options (`start`, `end`, `http-header-fields`) on mpv ≥ 0.38, which has the `index` argument. Detect the version at runtime. Older mpv keeps today's path.
- A playlist becomes N pipelined `loadfile … append`. No temp file, no `loadlist`.
- Hooks are registered only when they're needed.
- Verify: P0-5 TTFF (local and LAN); the P0-2 header test.

**P2-N1 — Buffer defaults and presets** (S code + M validation, risk med: memory)
- Implement §2.4 and §3.5, with `PlayerConfiguration(buffer: BufferPreset.standard|feed|watch | BufferConfiguration(...))`. `bufferSize` stays as an alias.
- Verify: P0-5 network scenarios (stalls, TTFF, PSS).

**P2-Q1 — Split quality defaults** (S, risk med: visible change, opt-out provided)
- Desktop gets mpv's render defaults and `hwdec=auto-safe`; Android stays fast.
- `hr-seek-framedrop=yes` everywhere.
- Verify: bench seek latency; desktop `vo-passes` timings.

**P2-S1 — Screenshot through `screenshot-to-file`** (S/M, risk low)
- mpv's native encoder and an async command. The lock is not held during encoding.

**Lane LNX**

**P2-L1 — Fences instead of `glFinish`; blit only where needed** (S/M, risk med)
- Files: `texture_gl.cc`, `isolated_egl.cc`.
- `eglCreateSyncKHR(EGL_SYNC_FENCE_KHR)` after the render, then `eglWaitSyncKHR` in Flutter's context. The GPU waits; the CPU doesn't.
- Keep the export blit for Mesa only (match on GL_VENDOR/GL_RENDERER).
- Verify: raster time with an Anime4K preset at 1440p and 4K on the GTX 1080 drops to Flutter's own cost; no tearing.

**P2-L3 — Native size from Dart; video/fixed/widget modes** (S, risk low)
- The native side never queries mpv for the size.

**P2-L2 — Dedicated render thread** (L, risk high)
- A 3-texture ring with fences.
- `mpv_render_context_report_swap`.
- `SKIP_RENDERING` while not visible (fixes L-11).
- Optional `ADVANCED_CONTROL` for direct rendering of software-decoded AV1.
- populate becomes O(1).
- Teardown is a thread join, so there's no raster race at all.

**Lane WIN**

**P2-W1 — Raster no longer waits on mpv** (M, risk med)
- Double-buffered internal textures. Publish the latest one under a short lock. Coalesce `NotifyRender` with a pending flag. No per-frame size queries.
- Verify: `Read()` p99 < 0.5 ms while mpv renders with shaders.

**P2-W2 — Stable texture id across resize** (M, risk med)
- Swap the share handle inside the same `GpuSurfaceTexture`. No blank frame.

**P2-W3 — Per-output worker** (M, optional; for multiple players)

**Lane AND** (after android-playback)

**P2-A1 — Surface size policy** (M, risk med)
- One size per media (§3.1): video fitted into the display's landscape size.
- Implement `setSize` without a VO rebuild when the Surface is unchanged.
- Verify: bench landscape-overlay raster p90, mpv GPU time and PSS; no rebuild logs on rotation.

**P2-A2 — `mediacodec_embed` per media in feed mode** (S/M, experiment, §3.8)

**P2-A3 — `ao=audiotrack` versus `opensles`** (S, experiment)
- Measure `avsync` jitter and drops.

**Lane UI**

**P2-U1 — Controls compositing** (M, risk med: visual parity)
- Files: `material.dart`, `material_desktop.dart`. Cupertino is untouched.
- Apply §3.6 in full.
- The seek bar's repaint-only path needs the P2-E3 API. The label throttle and drag-seek parts can start earlier.
- Verify: P0-6; the bench overlay scenario.

**P2-U2 — `Video` widget** (M, risk med)
- Files: `video_texture.dart`, `video_controller.dart`, the native controllers.
- Drop the full-size fill when the texture covers the box; paint only the letterbox bars.
- `FilterQuality.none` when the texture maps 1:1.
- Attach/detach refcounting → `SetVisible`.

**P2-U3 — Widget resize policy** (M, risk med)
- Settle, buckets, grow early and shrink late; this calls `setSize` on desktop. Android keeps one fixed size per media.
- Needs L3, W2 and A1.

### 4.4 Phase 3: packaging

**P3-1 — Native assets for libmpv** (L, risk high)
- `media_kit/hook/build.dart` declares code assets per OS and architecture.
- Bindings use ffigen `@Native` with an assetId.
- Linux uses the system library (`DynamicLoadingSystem('libmpv.so.2')`). Windows and Android bundle it, sha256-verified.
- `media_kit_libs_*` become no-op shims, so pubspecs keep working. Apple is untouched.
- Risks:
  - it requires raising the minimum Dart/Flutter SDK (build hooks);
  - Android jniLibs packaging and ABI splits;
  - the JNI_OnLoad JavaVM hand-off still needs `MediaKitAndroidHelper` (or `package:jni`).
- Win: `dart test` runs headless without path hacks.
- Verify: the app switches to the fork through a git dependency with no pubspec edits; the APK holds one libmpv per ABI.

**P3-2 — Fork-owned libmpv/ffmpeg builds** (L, risk med)
- Android: current mpv, ffmpeg 7.x, dav1d, TLS with CA support, `ao=aaudio` if it's available.
- Reproducible CI and checksums.
- The Android build's mpv version is unknown today (prebuilt v1.1.11).

**P3-3 — Replace the vendored `lib/ffi/**` with `package:ffi`** (S, risk low)
- Do it in a window when the CORE lane is idle.

**P3-4 — CI matrix** (S/M)
- Gating: Linux headless + integration under Xvfb, Windows build + unit tests, Android build.
- Apple non-blocking.

**P3-5 — Optional C shim through native assets** (M/L)
- An event pump and render helpers, only if P0-3 (C) still shows a Dart-side cost.

### 4.5 Phase 4: API improvements (additive, backward-compatible)

| ID | Task | Effort |
|---|---|---|
| P4-1 | `Player.stats()` / `stream.stats`, read through async property gets (§2.6 list) | M |
| P4-2 | `firstFrame` per load + TTFF (§3.4; native `FirstFrame` on Linux/Windows, PLAYBACK_RESTART on Android) | M |
| P4-3 | `setShaders(List<String>)`, `setVideoFilters`/`setAudioFilters` (documented together with output sizing) | S |
| P4-4 | `VideoControllerConfiguration.outputSize: video \| widget \| fixed`, on top of P2-U3 | S |
| P4-5 | Feed toolkit: `PlayerPool`/`FeedController` (acquire and recycle, neighbour policy, decoder budget from MediaCodecInfo) + `Video(placeholder:)` | L |
| P4-6 | `seek(d, mode: precise \| keyframe)` | S |
| P4-7 | Tracks: selection synced from mpv, secondary subtitles, `hls-bitrate` | M |
| P4-8 | Structured errors (END_FILE reason, HTTP status where available) | S/M |
| P4-9 | Android PiP helper (ActivityAware: auto-enter, aspect ratio, `isInPip` stream; no pause on PiP) | M |
| P4-10 | `Media(uri, options: {...})` → per-file options for `loadfile` | S |
| P4-11 | `getPropertyAsync` | S |
| P4-12 | Android audio focus / becoming-noisy (optional) | M |

### 4.6 Order of work and parallelism

**Wave 1: now, while android-playback is in progress**

Lanes run in parallel; tasks within a lane run in order.
- TEST:
  - P0-1 → P0-2;
  - P0-3, run (A) on integration;
  - P0-4;
  - P0-6, P0-7.
  - P0-1/2 (`media_kit/test`), P0-3 (`benchmark/`) and P0-4 (`media_kit_test/`) are separate directories, so they can be separate agents.
- LNX: P1-L1 → P1-L2.
- WIN: P1-W1.
- VCTL: P1-V1 → P1-V2 → P1-Q1 → P1-T1.
- Bench repo: P0-5.

**Wave 2: once android-playback merges**
- CORE: P1-C0 (if approved) → P1-C1 → P1-C2 → P1-C4 → P1-C5 → P1-N1.
- P0-3 run (B).
- AND: P1-A1.
- Then P1-C3, which needs C2, L1, W1, V1 and A1.

**Wave 3: Phase 2**
- CORE: E1 → E2 → E3 → E4; N1 → Q1 → S1. After the split, E and N run in parallel.
- LNX: L1 → L3 → L2.
- WIN: W1 → W2 (→ W3).
- AND: A1 → A2/A3 (bench experiments).
- UI: U1 (after E3; the label and drag parts can start in wave 2), U2, then U3 (after L3, W2, A1).
- P0-3 run (C) checks the E targets.

**Wave 4**
- P3-3 whenever CORE is idle.
- P3-1 and P3-2 in lane PKG.
- P4 in priority order for the apps: P4-2 → P4-5 → P4-1 → P4-6 → P4-3 → P4-7 → P4-9 → the rest.

---

## 5. Assumptions and open questions

**Assumptions I acted on (correct them cheaply):**
- **Android rendering backend.** Flutter 3.47 on the phone runs Impeller Vulkan, so the SurfaceProducer is backed by an ImageReader and `setSize` replaces the Surface. On GLES/SurfaceTexture the Surface would survive a resize.
- **Linux decoding path.** The Linux box uses the NVIDIA proprietary driver over EGL on Wayland, and hwdec resolves to nvdec with CUDA–GL interop. `hwdec-current` would confirm this; it's not verified.
- **How the apps reach mpv.** The apps use `(player.platform as NativePlayer).setProperty/command` for shaders. They don't use `NativePlayer.lock` and they don't assign `PlatformPlayer.state`.
- **Android mpv version.** The mpv inside the Android prebuilt is unknown, so per-file `loadfile` options need runtime detection.
- **Bench app.** The bench can switch dependencies and gain scenarios. I didn't read its code.
- **Unverified mechanisms.** None of the cost claims were measured here; P0-3 and P0-5 produce the numbers. The NVIDIA SEGV mechanism (L-1) and the effect of the allocator on the flag bug (L-7) are reasoned from the code and mpv's contracts.

**Questions for the user (in one place):**
1. Do the mobile apps use the bundled controls or custom ones? This sets P2-U1's priority.
2. Should improved defaults (buffer sizes, `network-timeout`, `hr-seek-framedrop`, desktop render quality, `tls-verify` on desktop) become the new defaults, or stay behind opt-in presets?
3. OK to split `real.dart` into `part` files (P1-C0)? It's structural, but it's what lets several agents work on the core at once.
4. Native assets (P3-1) mean raising the minimum Dart/Flutter SDK. Acceptable?
5. For TLS verification on Android, OK to bundle a CA PEM?
6. Does the desktop app call `setSize` for Anime4K? If not, Anime4K's upscale passes never run today. If it does, the size gets reset whenever a file with a different resolution loads (P1-V1 fixes that).
