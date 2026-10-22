# Predidit's fork and the shipped libmpv binaries

Scope: our `integration` @ `9c0eef46` (ro-integration) against `predidit/main` @ `83b7ca63` (ro-predidit, 2026-10-18).
Merge-base `436735bd` (2024-11-28). Of Predidit's 140 non-merge commits, 11 are already in integration as patch-equivalent
upstream commits (`git log --cherry-mark`): fb67322c, 54fd8754, 931ef6fc, f0d22569, bb17d68c, d4e5935b, c2c13936,
811e62da, 29bd0e52, c608db51, 066a2ea3. Everything below concerns the other 129.

The coordinator narrowed the scope to Android, Linux and Windows. Apple and OHOS get one line each (section 2.9).

Evidence: I read the build recipes through `gh`. I downloaded the binaries into `tmp/_research-bin/` and only inspected
them with `strings`, `readelf` and `7z l`/`x`; nothing was executed. The downloaded archives match the pins: the media-kit
Android jar MD5 `540af35c…` (build.gradle.kts:78), the Carapacik x64 SHA-256 `e0cdd037…` (CMakeLists.txt:81), the ANGLE
x64 SHA-256 `81005450…` (CMakeLists.txt:182), and Predidit's Windows x64 `8adceab3…` and Linux `45922100…` entries in
`hook/native_bundles.json`.

Effort scale: S = up to a day, M = a few days, L = one to two weeks or more.

---

## 1. Top findings

1. **A release-mode crash is still open on integration.** Upstream #1348 is still open: apps abort with "Callback invoked
   after it has been deleted", and the reports come from the Play Console (Flutter ≥ 3.38 / Dart 3.10). Integration still
   registers a `NativeCallable` as mpv's wakeup callback in release builds (`initializer.dart:50-57`,
   `initializer_native_callable.dart:51-56`). Upstream's fix (#1350, b425e585) was reverted by Predidit himself
   (d46b2239, cf541176). The real fix is the lifecycle part of Predidit's a1b34d37: a C wakeup that posts through
   `Dart_PostCObject`, plus a `NativeFinalizer` that destroys mpv on a native worker thread. **Port now.**
2. **On Windows, Flutter's raster thread stalls on every frame.** The mpv render runs under a mutex and ends in
   `glFinish()` (`angle_surface_manager.cc:63-70, 97-99`). `Read()` on Flutter's raster thread takes the same mutex
   before `CopyResource` + `Flush` (`:72-80`). Neither #1436 nor #1468 changes this. Predidit's mailbox / no-stall
   pipeline (d19286c1, 21aacaf9) removes the stall, but it depends on a private libmpv patch.
   **New fact:** upstream mpv merged an official D3D11 render API on 2026-10-15 (`MPV_RENDER_API_TYPE_D3D11`, PR
   #17764, `4255130d`). A native D3D11 renderer is now possible on unpatched mpv master.
3. **On Windows, hardware decoding is copy-back only today.** mpv 0.41.0's `hwdec_d3d11egl` looks for
   `EGL_EXT_device_query` among the *display* extensions (`video/out/opengl/hwdec_d3d11egl.c:108` @ v0.41.0). The ANGLE
   that #1436 ships (d10b3bd2324e, M155) lists that extension only among the *client* extensions
   (`src/libANGLE/Caps.cpp:1297`, `ClientExtensions::getStrings`). The native d3d11va interop therefore never
   initialises, and `hwdec=auto` ends on `d3d11va-copy`. mpv fixed this in 1d156861 (2026-07-31), but only on master.
   The fix is in freeKC's 20261021-1 build and on Carapacik's unreleased `fix/angle-hwdec` branch (b9ca0a60). It is not
   in the 20260926 build we pin.
4. **Android builds fail on a clean checkout right now.** GitHub answers HTTP 406 to Java's default `Accept` header.
   I reproduced it with curl: 406 with Java's header, 206 with `Accept: */*`. Both
   `libs/android/*/android/build.gradle.kts:107` use `URI.create(url).toURL().openStream()`; this is upstream #1469
   (2026-10-22). A two-line fix: open the connection and set `Accept: */*`.
5. **The Android binary is 2023 vintage.** media-kit v1.1.11 contains:
   - mpv `v0.36.0-549-g78d43740f5` (2023-10-14) and FFmpeg `n6.0` (without even the 6.0.1 point release);
   - Mbed TLS 3.4.0 with **no TLS 1.3 client**: 0 `TLS1-3-` ciphersuites in the .so (upstream #1437);
   - dav1d 1.2.0, and no libplacebo, so `vo=gpu-next` is unavailable (upstream #1093).

   It does have zero-copy MediaCodec through AImageReader (`android-media-ndk` is in its feature list). Predidit's v1.3.1
   is mpv and FFmpeg master of 2026-10-13, Mbed TLS 3.6.7 (TLS 1.3) and libplacebo + Vulkan + shaderc. It costs
   +10.4 MB per ABI uncompressed, needs minSdk 26 and carries Kazumi-specific FFmpeg HLS patches.
6. **Vulkan does not help these use cases.**
   - Desktop media_kit uses the libmpv render API, which only drives `vo_gpu`: the only backends are
     `video/out/gpu/libmpv_gpu.c` and `libmpv_sw.c`, with no gpu-next backend even on master. Anime4K runs as
     `glsl-shaders` on vo_gpu/OpenGL.
   - On Android, zero-copy MediaCodec is GL-only (`hwdec_aimagereader.c:132`:
     `if (!ra_is_gl(hw->ra_ctx->ra)) return -1;`). gpu-next on Vulkan therefore drops 4K playback to copy-back.
7. **Licences.**
   - Every current Android and Windows build is LGPLv3+: FFmpeg `--disable-gpl --enable-version3` (Mbed TLS or OpenSSL
     forces version 3) and mpv `-Dgpl=false`. Fine for the Play Store and for closed desktop apps, with obligations
     (section 3.6).
   - Predidit's Linux bundle is **GPL** (mpv `gpl` and `rubberband` in its feature list) and needs glibc 2.38, so it is
     no candidate for us.
   - Only freeKC's Windows releases ship the complete corresponding source, the licence texts and the build manifest
     (compare upstream #1460).
8. **A TLS trap waits when we move to newer mpv.**
   - mpv master enables `tls-verify` by default when lavf ≥ 63 (ee3d72ce02, 2026-05-28; `stream/network.c:54-56`).
   - FFmpeg's OpenSSL backend then falls back to `SSL_CTX_set_default_verify_paths` (`tls_openssl.c:702-706`).
     Mbed TLS only accepts a CA file (`tls_mbedtls.c:553-555`).
   - Without a CA bundle supplied by the app, HTTPS will very likely fail on Windows and Android.
   - Predidit hides this by patching the default back to *off* (`mpv-0002-restore-tls-verify-default.patch`; same patch
     on Android).
   - Our current builds (mpv ≤ 0.41.0) default to off as well. The fork must decide this deliberately.

---

## 2. Task A: Predidit's changes

### 2.1 Summary

| Change | Problem solved | State on integration | Effort | Risk | Recommendation |
|---|---|---|---|---|---|
| a1b34d37, lifecycle half (native event loop, finaliser, deterministic dispose) | NativeCallable outlives its isolate (abort); mpv leaks or keeps playing when the engine dies; dispose by 5 s timer; pending requests never complete | **Unsolved**; upstream fix reverted | M–L | Medium (event-dispatch core) | **Port now** (stopgap S: use the isolate initializer in release) |
| a1b34d37, packaging half (native assets replace `media_kit_libs_*`) | 9 binary packages with duplicated Gradle/CMake/Podspec download code; no system/local override | Still `media_kit_libs_*`; the Android download is broken (#1469) | L | Medium (breaking for consumers) | **Port later**, once the fork publishes its own binaries |
| 803c4a27 safe property handling | Uninitialised `mpv_node` read when `video-out-params` is unavailable; unchecked node formats in handlers; FLAG read as Int8/Bool | **Present** | S–M | Low | **Port now** |
| a7d4a070 safe screenshot | Heap overflow and missing NULL terminator in the command argv; leaks on error paths | **Present** (`real.dart:2685`) | S | Low | **Port now** (allocation and try/finally part) |
| 9c94fabd → d19286c1 → 21aacaf9 Windows native D3D11 + mailbox + no-stall | Per-frame glFinish; raster thread blocked on the producer mutex; extra copy per frame; adapter mismatch on multi-GPU | **Unsolved** (#1436/#1468 don't touch it) | L | High | **Port later**, as a rewrite on mpv's new D3D11 render API, after an own Windows build. Adapter part: S–M, port now |
| df5a969e x11 H/W | No H/W rendering on X11 with Flutter ≥ 3.38 | **Solved** by #1466 (+ #1464 port) | – | – | Skip |
| Linux render thread + mailbox (1e70872a, 6bb4b5df, 480c1e18; = upstream PR #1346) | mpv renders inside `populate` on the raster thread and ends with `glFinish` | **Unsolved** (`texture_gl.cc:361-380`) | M–L (conflicts with #1466/#1464) | Medium | **Port next** for Linux + Anime4K |
| d1ac737b Linux epoxy-only | Overwrites libepoxy's process-wide dispatch pointers | **Present** (`texture_gl.cc:15-38, 192`) | S | Low | Port now, or fold into the render-thread port |
| 87cdfef7 Android SurfaceTexture fallback | SurfaceProducer drops the last frame on memory trim, giving a black paused frame on resume (Impeller) | Integration always uses SurfaceProducer (`VideoOutput.kt:97`) | S–M | Medium (Skia-only path) | **Hand to the `android-playback` agent**; at most an opt-in later |
| 90ea5598 mpv 0.41, c04ddeea shaderc patch, b08e0744 API 26, 4cd7c295 GLES shader fix | Binary bumps; mostly in Predidit/libmpv-android-video-build | n/a (our binary is v1.1.11) | – | – | Covered by Task B |
| e3732e30 gpu-next on Vulkan 1.1 devices | `gpu-api=vulkan,opengl` fallback | n/a (no libplacebo in our binary) | S | – | Skip; if gpu-next is enabled, default to `gpu-api=opengl` (zero-copy) |
| 11f72195 video bitrate | No `video-bitrate` in the state; `copyWith` can't reset fields to null | Absent | S | Low | Port later (useful for a 4K stats overlay) |
| b11ec805 suppress OSC noise | `osc=no` set as a runtime property errors on Lua-less builds | **Present** (`real.dart:2356`; our Android and Windows builds have `-Dlua=disabled`) | S | Low | Port now |
| 11d02cb8 Windows arm64 | arm64 libmpv | **Solved** by #1436 | – | – | Skip |
| 66d46c3d ad blocker, 037fbf8f HTTP proxy, HLS disguised-segment patches | Kazumi's piracy-site streams | n/a | – | – | Skip (app-specific) |

### 2.2 Windows render pipeline (9c94fabd, d19286c1, 21aacaf9) vs #1436 / #1468

**What integration does** (`media_kit_video/windows/`):

- The producer runs on the thread pool. `Draw()` takes `mutex_`, makes the context current, calls
  `mpv_render_context_render` and then `glFinish()` (`angle_surface_manager.cc:63-70, 97-99`). The GPU is fully drained
  on every frame.
- The consumer is Flutter's raster thread. The `GpuSurfaceTexture` callback calls `Read()`, which takes **the same
  mutex**, copies the internal texture to the external one and flushes (`:72-80`; callback at
  `video_output.cc:349-357`). The raster thread therefore waits for the whole mpv render plus `glFinish`. With Anime4K at
  1440p or 4K that is a full shader chain per Flutter frame, and the copy adds a full-frame copy on top.
- The D3D11 device uses the default adapter (`angle_surface_manager.cc:173-194`), not Flutter's. On multi-GPU laptops,
  Flutter, media_kit's device and media_kit's ANGLE display can sit on different adapters.
- What #1436 changed: new ANGLE (chromium/8059, `18995cfa`), libmpv 0.41.0, rendering straight into the pbuffer, no
  D3D9 fallback.
- What #1468 changed: device-lost detection, texture ID 0 reported to Dart, no destructor hang without a texture, and the
  `SetSize`/`Read` mutex plus ordered `texture_id_` publication.
- Neither PR touches the stall.

**What Predidit does:**

- 9c94fabd (2025-10-14) drops ANGLE. mpv renders with its own `ra_d3d11` through a **private render API** (`MPV_RENDER_API_TYPE_DXGI`)
  that comes from Predidit/libmpv-win32-video-cmake `packages/mpv-0001-dxd11-render-api.patch` (215 lines, f162d85d).
- d19286c1 adds `MailboxSwapChain`, a fake `IDXGISwapChain` with lock-free slots backed by shared BGRA textures and
  `ID3D11Fence`s. It also uses Flutter's adapter: `registrar_->GetView()->GetGraphicsAdapter()`, `video_output.cc:43`,
  `d3d11_renderer.cc:70-104`.
- 21aacaf9 moves to 4 slots:
  - the producer signals a fence and, without blocking, promotes the previous frame once it is GPU-complete
    (`mailbox_swap_chain.cc:113-182`);
  - the consumer does a single acquire load (`ConsumerAcquire`, `:184`);
  - there is no copy, no mutex, no flush and no keyed mutex.
- Zero-copy d3d11va comes for free: it decodes on the same device as the renderer.

**Gaps in Predidit's version, if ported as is:**

- It needs Predidit's patched libmpv. freeKC explicitly leaves that patch out, and it also ships the TLS-verify-off patch.
- It has no device-lost handling: nothing calls `GetDeviceRemovedReason`. That is a regression against #1468.
- `Resize` publishes `texture_id_` before inserting into `textures_` (`video_output.cc:329-334`). That is exactly the
  `textures_.at` crash #1468 fixed.
- It needs `ID3D11Device5`/`ID3D11DeviceContext4` (Windows 10 1703+), falling back only to S/W.
- `Resize` releases all slots while Flutter may still hold the old handle.
- Cross-device safety relies on slot rotation. A slot is reused about 2 frames after it stops being the newest
  completed frame, with no fence on the Flutter side. Flutter's shared-handle consumer can't take a keyed mutex, so this
  is inherent to the design, not a mistake.

**Upstream changed the picture on 2026-10-15.** mpv `4255130de4` "libmpv: add D3D11 render API backend"
(`include/mpv/render_d3d11.h`, client API 2.6):

- the embedder passes its `ID3D11Device` once and an `ID3D11Texture2D` per `mpv_render_context_render` call;
- d3d11va decodes on that device (zero-copy);
- no fake swapchain is needed: the mailbox simply hands mpv the next slot's texture.

No binary contains it yet: Carapacik is on 0.41.0, and Predidit and freeKC are on `0b7ed670` (2026-09-14).

**Recommendation:**

- Now (S–M): put the D3D11 device and media_kit's ANGLE display on Flutter's adapter. Use `GetGraphicsAdapter()`, and
  ANGLE's `EGL_PLATFORM_ANGLE_D3D_LUID_HIGH/LOW_ANGLE` display attributes for the display.
- Later (L), after an own Windows libmpv ≥ `4255130d` (section 3.6):
  - write a native D3D11 `VideoOutput` on the upstream API, using Predidit's mailbox and no-stall logic as the
    reference;
  - keep #1468's device-lost semantics and texture publication order;
  - drop ANGLE from `media_kit_libs_windows_video`, which saves about 21 MB (section 3.1).

  Don't invest in a mailbox on the ANGLE path unless the own Windows build slips.

### 2.3 Lifecycle and robustness (a1b34d37, 803c4a27, a7d4a070)

**Problems that are still present on integration:**

- **Abort when the isolate dies before `Player.dispose`.** Typical triggers are engine detach, "Don't keep activities"
  or state restoration (#1348).
  - In release, mpv holds a `NativeCallable.listener` trampoline (`initializer_native_callable.dart:51-56`).
  - The debug-only workaround (`initializer.dart:40-57`) uses the isolate initializer in debug builds only.
  - Upstream's attempt (#1350) was reverted.
- **mpv survives its owner.** `dispose()` defers `mpv_terminate_destroy` by a 5 s `Future.delayed` (`real.dart:114-115`).
  If the isolate dies first, the core keeps running, audio included. `NativeReferenceHolder` cleans up only in debug
  builds.
- **Dispose is not deterministic.** Pending `setProperty`/`command` completers never complete, and a second `dispose()`
  throws `AssertionError` (`real.dart:99-101`).
- **Screenshots.**
  - `compute(_screenshot, …)` runs FFI on the raw handle in another isolate (`real.dart:1138-1146`); disposing during a
    capture is a use-after-free.
  - `calloc.allocate(args.join().length)` (`real.dart:2685`) allocates 19 or 23 bytes for an argv of 3 pointers
    (24 bytes) and never writes `arr[2] = NULL`. mpv reads past the allocation.
- **Uninitialised node reads.** `mpv_node params;` followed by an unchecked `mpv_get_property("video-out-params")` reads
  stack garbage whenever the property is unavailable, which happens before the first frame and after EOF:
  `windows/video_output.cc:430-431, 479-480` and `linux/video_output.cc:433-434, 483-484`. `params.format` may then
  match `MPV_FORMAT_NODE_MAP` and `u.list` gets dereferenced.
- **Dart handler checks.**
  - The handlers read `MPV_FORMAT_FLAG` (a C `int`) as `Int8`/`Bool` (`real.dart:1522, 1533, 1551, 1941`). That is
    harmless on little-endian but wrong.
  - Node handlers walk `u.list` and read `u.string` without checking formats.

**What Predidit did:**

- `src/native_event_loop.c` (170 lines) is the wakeup: plain C that posts an int with `Dart_PostCObject`. No Dart
  function pointer is ever registered with mpv.
- A `NativeFinalizer` (`native_event_loop.dart:13`) stops the wakeup and signals a pre-created worker thread that calls
  `mpv_terminate_destroy`, without touching any Dart API. Reference counting covers the finaliser and the worker
  (`native_event_loop.c:56-170`).
- `dispose()` (Predidit `real.dart:77-108`) is idempotent and ordered:
  1. release the video render contexts;
  2. stop the wakeup and drain the in-flight handler;
  3. destroy mpv on the worker;
  4. reject outstanding requests.
- Screenshots move to an async command in the owning isolate. The pixels are copied before the event buffer is reused.
- 803c4a27 adds `native_property.dart` (typed, status-checked reads), `NativeNodeMap` (copies nodes with format checks)
  and `common/video_dimensions.h` (checks the status of `mpv_get_property` and always calls `mpv_free_node_contents`).
- The tests kill 150 isolates while callbacks and disposals are in flight (`tool/lifecycle_test/`). This code ships in
  Kazumi.

**Porting notes:**

- The C bridge needs a native build for every target. Predidit compiles it through the build hook (`CBuilder`,
  `hook/build.dart:119-132`). Without the packaging migration it can go into the existing per-platform plugin builds,
  but `media_kit` itself is pure Dart on integration, so a build hook just for the bridge is the cleanest option. We
  already require Flutter 3.44+ (#1435).
- Integration's Windows `~VideoOutput` posts `mpv_render_context_free` **without waiting** (`video_output.cc:154-156`).
  Once terminate becomes immediate, that post must be awaited, as Predidit does with `.wait()`. Otherwise the render
  context outlives its core.
- Conflicts: `real.dart` collides with #1356 and #1454 as merged. The port is by hand, roughly 1.2k lines of diff in
  Predidit.
- Stopgap (S): route release builds through `InitializerIsolate` as well; upstream already does this in debug for the
  same crash. That removes the trampoline but not the leak or ordering issues.

### 2.4 Native assets migration (packaging part of a1b34d37, plus d13fc22b and 6fd002aa)

**How it replaces `media_kit_libs_*`:**

- All nine `libs/*` packages are deleted. The audio/video split is gone too: audio-only apps get the video binary.
- `media_kit/hook/build.dart` reads a single manifest, `hook/native_bundles.json`, with an https URL, a SHA-256, the
  format, the root and the primary library per target (`android_arm64`, `windows_x64`, `linux_x64`, …).
- It downloads and verifies only the target's bundle into a content-addressed cache with a file lock, a `.partial`
  download, stamped extraction hashes and a path-traversal check (`hook/src/bundles.dart`).
- It emits `CodeAsset(DynamicLoadingBundled)`. On Android it also bundles `libmediakitandroidhelper.so`, and the JNI
  bootstrap moves into a core `media_kit` Android plugin (`media_kit/android/.../MediaKitPlugin.java`).
- The user-define `source: bundled | system | local` (plus `library-directory`, `cache-directory`) lets an app use the
  distro libmpv on Linux/Windows or its own build.
- Video plugins stop linking libmpv. `media_kit_video/common/mpv/media_kit_mpv.c` `dlopen`s the module that the Dart
  player resolved, and resolves all symbols atomically. Vendored headers replace import libraries and pkg-config.
- `NativeLibrary` resolves the bundled path through `dladdr`/`GetModuleHandleEx` on `mpv_client_api_version`
  (`native_library.dart:44-79`).

**Is it a good base for our packaging?** Yes for the mechanism; no as configured.

- Good:
  - one source of truth, SHA-256 everywhere, per-target downloads;
  - no Gradle download (so no #1469);
  - `source: system` for distro packaging and `source: local` for our own builds and for GPL/LGPL choices per app;
  - no link-time dependency of the Linux plugin on `libmpv.so.2`. Integration links `PkgConfig::mpv`
    (`media_kit_video/linux/CMakeLists.txt:29-58`), so a binary built on a libmpv2 distro won't start where only libmpv1
    exists.
- Not as configured:
  - The Linux default `bundled` points at Predidit's GPL, glibc ≥ 2.38 build (section 3.2).
  - Windows bundles only `libmpv-2.dll` because Predidit doesn't use ANGLE. Staying on ANGLE needs a second bundle.
  - The Android minSdk declared in the plugin is 21, while the bundled .so is built for API 26.
  - Every target now needs a C compiler. We have one everywhere Flutter builds.
  - It is a breaking change: apps must drop their `media_kit_libs_*` dependencies.
- Recommendation: adopt it **after** the fork publishes its own binaries, so that the manifest points at the fork's
  releases. Keep the `system`/`local` semantics, and ship the C event-loop bridge (section 2.3) through the same hook.

### 2.5 Android SurfaceTexture fallback (87cdfef7)

- **Motivation.** Kazumi #1921 (Huawei Mate 30/40/60 Pro, HarmonyOS 4.2): pause, go home or lock the screen, return, and
  the video is black until playback resumes. Predidit's explanation in that thread: Flutter's engine reclaims the
  `SurfaceProducer`'s retained texture on a memory-trim signal, and the Flutter team considers that expected. Related
  black screens after switching apps under Impeller: Kazumi #371/#652, flutter/flutter#154602.
- **What the commit does.** `VideoControllerConfiguration.enableAndroidSurfaceProducer` (default true). When false,
  `VideoOutput.java` uses `createSurfaceTexture()` and wraps it in a `Surface` for `--wid`. The doc comment says it is
  "only effective with Android's Skia backend".
- **How Kazumi uses it.** It ships with Impeller disabled (Kazumi 63b08a20, `EnableImpeller=false`) and
  `enableAndroidSurfaceProducer: false` (060c6e67). Since 14f8cb0f it also defaults `hwdec` to `mediacodec` on Android.
- **On integration.** `VideoOutput.kt:97` always uses `createSurfaceProducer()`.
- **Recommendation.** Not ours to port now; this is the `android-playback` agent's area. Its value depends on keeping
  Skia, and Impeller is the default on Android. A sturdier fix is to redraw on `onSurfaceAvailable` after a trim while
  paused.

### 2.6 Linux: df5a969e (x11 H/W), the render thread, d1ac737b (epoxy)

- df5a969e builds the EGL display from GDK's X11/Wayland display through `eglGetPlatformDisplayEXT` (Predidit
  `video_output.cc:142-150`). #1466 does the same, plus GLX-context juggling and an EGLImage self-test, and our #1464
  port adds the Mesa export-texture blit. **Superseded.**
- The real Linux differentiator is the dedicated GL render thread plus a mailbox triple buffer with EGL fence syncs
  (Predidit `texture_gl.cc`: `eglCreateSyncKHR` at :347, `eglWaitSyncKHR` on the consumer at :434). Upstream it is
  Predidit's PR #1346 (open, mergeable on upstream main). On integration, mpv renders inside
  `texture_gl_populate_texture` on Flutter's raster thread and finishes with `glFinish` on the blit path
  (`texture_gl.cc:198-380`). That is the Linux counterpart of the Windows stall. Port it onto #1466/#1464, keeping a
  per-buffer export blit, because Predidit's EGLImage-from-FBO-texture is exactly what goes black on Mesa (#1463).
  Effort M–L; both touch `texture_gl.cc` and `video_output.cc` heavily.
- d1ac737b: integration declares static extension pointers behind `#ifndef eglCreateImageKHR`. With `<epoxy/egl.h>`
  included, those names are epoxy macros, so the statics are skipped and `init_egl_image_extensions()`
  (`texture_gl.cc:31-38`, called at :192) **writes libepoxy's global dispatch pointers**, which GTK shares. Use epoxy
  only. S.
- Anime4K on Linux GLES (upstream #1438): mpv's vo_gpu emits `precision mediump sampler2D;` on GLES. On NVIDIA that
  gives a global colour shift with multi-pass shaders. It is not fixed upstream: master's `video/out/gpu/shader_cache.c:791`
  still emits it. Predidit's Linux build patches mpv (Predidit/libmpv-linux-build ac817eaa). With the system libmpv that
  patch is unavailable. Untested idea: create the isolated context as desktop GL (`EGL_OPENGL_API`) instead of GLES 2
  (`isolated_egl.cc:82-102`); desktop GLSL has no precision qualifiers, and EGLImages are API-agnostic.

### 2.7 Android binary-tied commits

- 90ea5598 bumps the binary to mpv 0.41 and replaces `opengl-es`/`gpu-context=android` with `gpu-api`.
- e3732e30 changes `gpu-api` to `vulkan,opengl` when `vo=gpu-next`. Vulkan needs libplacebo's 1.2+ minimum, so on a
  1.1-only device the "fix" is a fallback to GLES. As finding 6 shows, Vulkan also loses zero-copy MediaCodec. Skip; if
  we enable gpu-next, use `gpu-api=opengl`.
- c04ddeea (libplacebo clamps SPIR-V to Vulkan 1.3 for the NDK's shaderc, later dropped with NDK r30 in 87eb5ad3) and
  4cd7c295 (libplacebo `custom_mpv.c` makes `HOOKED_tex`/`texOff`/`gather` function-like macros so user shaders compile
  on GLES under gpu-next) are binary bumps only. Keep 4cd7c295's patch in mind if our own Android build enables
  gpu-next with user shaders.
- b08e0744 sets the build API level to 26. It had been 29, which broke API 26–28 devices.

### 2.8 Small ones

- 11f72195 (video bitrate) adds the `video-bitrate` observer and `PlayerState.videoBitrate`, and switches `copyWith` to
  sentinels so `audioBitrate`, `width` and `height` can be reset to null. S, port later.
- b11ec805 passes `osc=no` as an init option instead of a property. S, port now.
- 11d02cb8 (Windows arm64) is covered by #1436.

### 2.9 Out of scope

- Apple: 13b332ad (SPM) and the darwin binary bumps; Predidit's darwin 0.6.8 is the same mpv 0.36.0 / FFmpeg 6.0 as
  media-kit's v0.7.x. Skipped.
- OHOS: 7d1e3f81, 652cfc76, 99c7358b, 9c31fe57. Skipped.

---

## 3. Task B: libmpv binaries

### 3.1 What integration ships

| Package | Source and pin | mpv / FFmpeg | Build | Size |
|---|---|---|---|---|
| `libs/android/media_kit_libs_android_video` (`build.gradle.kts:75-96`, MD5 pins) | media-kit/libmpv-android-video-build **v1.1.11** (release 2026-01-27), `default-*.jar` ×4 ABIs | mpv `v0.36.0-549-g78d43740f5` (2023-10-14, `depinfo.sh:17`); FFmpeg **n6.0** tarball (Lavc 60.3.100) | See details below | Jars: arm64 5.73 MB, armv7 5.50, x86 5.84, x86_64 6.52. arm64 `libmpv.so` 12.37 MB uncompressed |
| `libs/android/media_kit_libs_android_audio` | libmpv-android-audio-build v1.1.9 | not inspected (video is the target) | – | – |
| `libs/windows/media_kit_libs_windows_video` (`CMakeLists.txt:72-104, 174-202`, SHA-256) | **Carapacik**/libmpv-win32-video-cmake release `20260926` (built from a233c22d), plus Carapacik/flutter-windows-ANGLE-OpenGL-ES **v1.1.0** (ANGLE `d10b3bd2324e`, M155) | mpv **v0.41.0** (`41f6a64506`) plus a D3D9-ANGLE-removal patch; FFmpeg **n9.0.2** (Lavc 63.1.102) | See details below | x64 `.7z` 9.57 MB, giving `libmpv-2.dll` 31.26 MB; arm64 `.7z` 8.91 MB. ANGLE x64 DLLs 20.97 MB in total |
| `libs/windows/media_kit_libs_windows_audio` | media-kit/libmpv-win32-audio-cmake `20251213` (git-140ec21) | not inspected | – | – |
| `libs/linux/media_kit_libs_linux` | **no libmpv**; builds mimalloc 2.1.2 only | system libmpv: `pkg_check_modules(mpv)` + link (`media_kit_video/linux/CMakeLists.txt:29-58`); runtime `dlopen` of `libmpv.so`, `.so.2`, `.so.1` (`native_library.dart:50-56`) | Whatever the distro ships. Our dev box (Arch): mpv 0.41.0 **GPL** with cuda-interop, vaapi, vulkan, libplacebo; FFmpeg 9.0.2 | `libmpv.so.2.5.0` 3.59 MB plus the shared FFmpeg/libplacebo libraries |
| macOS / iOS | media-kit/libmpv-darwin-build v0.7.2 (mpv 0.36.0, FFmpeg 6.0, LGPLv3) | – | – | Out of scope |

Build details for the Android v1.1.11 `default` flavor:

- Licence: LGPLv3+. FFmpeg `--disable-gpl --enable-version3` (`flavors/default.sh:31-33`); mpv `-Dgpl=false`; the .so
  reports "libavcodec license: LGPL version 3 or later".
- Hardware decoding: MediaCodec (`--enable-jni --enable-mediacodec`). The .so contains h264/hevc/vp8/vp9/av1/mpeg4
  `*_mediacodec` decoders. mpv features include `android-media-ndk`, the AImageReader zero-copy path.
- Codecs and formats: libdav1d 1.2.0; FFmpeg's native VP9 (no libvpx); whitelisted decoders and demuxers
  (hls/dash/mov/matroska/mpegts…).
- GPU stack: `--disable-vulkan`; mpv `-Dvulkan=disabled -Dlibplacebo=disabled` (`scripts/mpv.sh:27-28`), so there is no
  gpu-next.
- Subtitles: libass 0.17.1 (harfbuzz 7.2.0, freetype 2.13.0, fribidi 1.0.12).
- TLS: Mbed TLS 3.4.0, TLS 1.2 only.
- Toolchain: NDK 25.2, API 21.
- Linked libraries (`NEEDED`): libm, libandroid, libOpenSLES, libEGL, libdl, libc. LOAD segments are 16 KB-aligned.
- Other flavors exist: `full` enables all decoders, demuxers and parsers (still LGPL, arm64 jar 7.84 MB; it would cover
  upstream #1269's PGS subtitles). `encoders-gpl` is GPL.

Build details for the Windows Carapacik `20260926` build:

- Licence: LGPLv3+. FFmpeg `--disable-gpl --disable-nonfree --enable-version3`; mpv `-Dgpl=false`.
- Hardware decoding: FFmpeg `--enable-d3d11va --enable-dxva2`; cuda, nvdec, amf and libmfx are disabled; `--enable-libvpl`.
- Codecs: dav1d, libjxl, libwebp, zimg.
- TLS: OpenSSL; also libssh and libsrt.
- GPU stack: FFmpeg `--disable-vulkan`. mpv `-Dvulkan=disabled -Dspirv-cross=disabled`, so mpv has no `d3d11` gpu-api.
  Its feature list has `egl-angle d3d-hwaccel libplacebo shaderc lcms2 libass libarchive`. Lua and JavaScript are off.
- Zero-copy is broken; see finding 3.
- The archive ships neither licence texts nor a build manifest.

### 3.2 Predidit's binaries

| Target | Source | mpv / FFmpeg | Build | Size |
|---|---|---|---|---|
| Android | Predidit/libmpv-android-video-build **v1.3.1** (2026-10-18) | mpv `v0.41.0-1153-gc3ac7f395` (master 2026-10-13); FFmpeg `git-2026-10-13-24e860f` (after n9.1-dev, Lavc 63.20.100) | See details below | Jars: arm64 9.61 MB, armv7 8.62, x86 9.99, x86_64 10.37. arm64 `libmpv.so` **22.81 MB** (+10.4 MB against v1.1.11) |
| Windows | Predidit/libmpv-win32-video-cmake `202609151348` | mpv `v0.41.0-1049-g0b7ed670f-dirty` (master 2026-09-14) + **DXGI render-API patch** + **TLS-verify-off patch**; FFmpeg N-126568-g5b9a3ad71 (Lavc 63.13.100) | LGPLv3+. FFmpeg d3d11va, dxva2, **amf**, cuda/nvdec, libvpl, OpenSSL. mpv `d3d11 spirv-cross shaderc libplacebo cuda-interop egl-angle`, no Vulkan | x64 `.7z` 11.03 MB, giving `libmpv-2.dll` 38.72 MB; no ANGLE needed |
| Linux | Predidit/libmpv-linux-build `20260810` | mpv `v0.41.0-11-gf011d73d5-dirty`; FFmpeg **n7.1.5** | See details below | zip 8.87 MB, giving `libmpv.so.2` 22.22 MB |

Build details for the Android v1.3.1 build:

- Licence: LGPLv3+, the same FFmpeg flags as media-kit's (FFmpeg still `--disable-vulkan`).
- mpv features: `vulkan libplacebo lcms2 aaudio audiotrack android-media-ndk`.
- Libraries: libplacebo 1dd02268 + shaderc (from the NDK) + lcms2 2.19.1; dav1d 1.5.4; Mbed TLS **3.6.7** (TLS 1.3);
  libass 0.17.5.
- Toolchain: NDK r30, API 26.
- Extra linked libraries: libmediandk, libvulkan. 16 KB-aligned.
- Patches:
  - `mpv_restore_tls_verify_default`;
  - Kazumi HLS (`hls_ad_filter`, default 0; `seg_allow_img`, default 0, which means it probes past segments disguised
    as PNG/GIF by default);
  - the libplacebo GLES macro fix;
  - Mbed TLS entropy from `/dev/urandom`.

Build details for the Linux `20260810` build:

- Licence: **GPL**. mpv runs with its default `gpl=true` (`gpl` and `rubberband` are in the feature list), although
  libav* itself is LGPL 2.1+.
- Features: vaapi (drm/x11/wayland), vdpau, dmabuf-interop-gl, egl-x11/wayland; no vulkan, no cuda.
- TLS: GnuTLS.
- Portability: needs **GLIBC_2.38 / GLIBCXX_3.4.32** (built on ubuntu-latest) and 34 distro `.so` dependencies
  (`libgnutls.so.30`, `libunwind.so.8`, `libarchive.so.13`, libva, libpulse, wayland…).
- Patches: GLES highp sampler, fd leak, HLS probing.

**A third candidate** (not Predidit's): **freeKC/libmpv-builds `20261021-1`** (repository created 2026-10-21; freeKC
authored #1466/#1467/#1468).

- Windows x64 and arm64 `libmpv-2.dll` from mpv `0b7ed670` **unpatched** (`v0.41.0-1049-g0b7ed670f`, no `-dirty`) and
  FFmpeg `5b9a3ad7`.
- It uses Predidit's recipe (fdf75129) minus Predidit's mpv patches; LLVM 22.1.8.
- Licence: LGPLv3+.
- Features: the same as Predidit's (`d3d11 spirv-cross shaderc cuda-interop amf egl-angle`), without libarchive.
- Includes mpv 1d156861 (the ANGLE interop fix; `0b7ed670` is 131 commits after it), but **not** 40c998a1
  (device-reference release) or 4255130d (the D3D11 render API).
- tls-verify is **on** by default (mpv master, unpatched).
- Each archive carries `licenses/` (51 entries) and `BUILDINFO.txt`. The release adds a 266 MB corresponding-source
  tarball and SHA256SUMS.
- Size: x64 `.7z` 11.05 MB, giving a 38.64 MB DLL.

### 3.3 Capability matrix (only what decides our cases)

| | Android: media-kit v1.1.11 | Android: Predidit v1.3.1 | Windows: Carapacik 0.41.0 + ANGLE | Windows: freeKC 0b7ed670 + ANGLE | Linux: system (Arch) | Linux: Predidit |
|---|---|---|---|---|---|---|
| Zero-copy hwdec into media_kit's renderer | Yes (mediacodec via AImageReader, GL) | Yes (GL); no on Vulkan | **No**: d3d11va-copy only | Yes (d3d11egl fixed) | vaapi via dmabuf; nvdec via cuda-interop (with GLES contexts unverified) | vaapi via dmabuf |
| gpu-next | No (no libplacebo) | Yes (GL or Vulkan) | Irrelevant: render API = vo_gpu | Irrelevant | Irrelevant | Irrelevant |
| User shaders (Anime4K) | vo_gpu GLES | vo_gpu, or gpu-next with the GLES patch | vo_gpu on ANGLE GLES | Same | vo_gpu on GLES (NVIDIA colour shift, #1438) | Same, with the highp patch |
| AV1 | dav1d 1.2.0 + av1_mediacodec | dav1d 1.5.4 + av1_mediacodec | dav1d + d3d11va av1 | Same | Distro | dav1d 1.5.4 + vaapi |
| TLS | Mbed TLS 3.4.0, **TLS 1.2 only**, verify off | Mbed TLS 3.6.7, TLS 1.3, verify **forced off** | OpenSSL, TLS 1.3, verify off (0.41 default) | OpenSSL, TLS 1.3, verify **on** (needs CAs) | Distro | GnuTLS |
| Licence | LGPLv3+ | LGPLv3+ | LGPLv3+ | LGPLv3+, sources published | GPL (distro) | **GPL** |

### 3.4 What newer mpv brings for us

- **Android.**
  - In 0.41: an AAudio audio output (`ao_aaudio`; master adds an out-of-bounds read fix, 3b276cef9b, 2026-10-22) and
    "vo/context_android: fix surface tearing on resize".
  - On master: AImageReader `maxImages` lowered from 5 to 3 (c8d3f6884d). It fixes `hevc_mediacodec` start failures on
    MediaTek (OMX.MTK.VIDEO.DECODER.HEVC, Fire TV Stick 4K Max, mpv-android#540), which matters at 4K. Also better
    release-buffer error handling with lavc ≥ 63.11.101 (14f2d48cbc).
  - Since 0.37, libplacebo (and so gpu-next) is mandatory.
  - **Constraints:** mpv ≥ 0.39 needs FFmpeg ≥ 6.1, so the 6.0 stack can't simply take a newer mpv. Zero-copy stays
    GL-only, so Vulkan brings nothing for 4K streaming.
- **Windows** (master only):
  - the d3d11egl `EGL_EXT_device_query` fix (1d15686142) and the hwdevice-reference release (40c998a1ca);
  - the D3D11 render API (4255130de4);
  - d3d11va zero-copy for 4:4:4 and high-bit-depth formats (0d68a842a0), which only matters on the native D3D11 path.
- **gpu-next fixes** on master (69e63f425a, 7c25b3e47c, …) only matter where gpu-next is used, so Android only.
- **TLS:** see finding 8. It applies to every build made from mpv master after 2026-05-28.

### 3.5 Facts that change the decisions

1. libmpv render API means vo_gpu only. Vulkan, shaderc and SPIRV-Cross buy nothing on the desktop, except SPIRV-Cross
   for the future D3D11 render path, where mpv's `d3d11` feature needs `spirv-cross` and `shaderc`.
2. Zero-copy MediaCodec is GL-only (`hwdec_aimagereader.c:132`). Don't ship Vulkan on Android for 4K. It also costs
   about 10 MB per ABI; libplacebo can be built GL-only.
3. ANGLE M155 plus mpv 0.41.0 means copy-back on Windows (finding 3).
4. Mbed TLS 3.4 has no TLS 1.3; 3.6 does. A CloudFront TLS1.3-only policy breaks the current Android build (#1437).
5. Build-time defaults decide TLS behaviour (finding 8). FFmpeg's `schannel` backend would use the Windows certificate
   store natively, which is an option for our own Windows build; on Android, ship a CA PEM and set `tls-ca-file`.
   `MediaKitAndroidHelper.copyAssetToFilesDir` already exists.
6. The Gradle download is broken (#1469). Fix it now regardless of the binary choice.

### 3.6 Recommendations

**What to ship now:**

- **Android:**
  - During development, keep v1.1.11 and fix the 406 (`build.gradle.kts:107`, video and audio). It is the baseline
    `android-playback` benchmarks against.
  - **Don't release on it.** TLS 1.2-only, FFmpeg 6.0 (Feb 2023, parsing untrusted web media) and mpv 2023 are release
    blockers for web streaming.
  - Before the first mobile release, ship an own build (below).
  - If that slips, Predidit v1.3.1 is the fallback: LGPL and battle-tested in Kazumi. It costs minSdk 26 and +3.9 MB
    per ABI in the APK, and brings a nonstandard default HLS behaviour (`seg_allow_img=0`) and forced `tls-verify=no`.
    TLS verification is off in v1.1.11 as well, so that part is no regression.
- **Windows:**
  - Move to **freeKC 20261021-1** (x64 + arm64) after two checks on a real machine:
    - `hwdec-current` reports `d3d11va`, not `d3d11va-copy`;
    - HTTPS opens. If it doesn't, set `tls-ca-file` to a bundled CA PEM, or set `tls-verify=no` explicitly as a
      conscious choice.
  - What it gives: zero-copy under ANGLE, and the corresponding source, licences and manifest that we need anyway
    because we already distribute desktop releases.
  - If the checks fail, stay on Carapacik 20260926 and watch its `fix/angle-hwdec` branch.
- **Linux:**
  - Keep the system libmpv for development and for distro packages (`.deb`/`.rpm`/AUR depending on libmpv2).
  - Don't adopt Predidit's bundle: GPL and glibc 2.38.
  - When we package an AppImage or Flatpak, bundle an **LGPL** build made on an old glibc baseline.

**Licence implications:**

- For **LGPLv3+ builds** (every Android and Windows option above), a Play Store app or a closed desktop app must:
  - keep libmpv a separate shared library (it already is);
  - ship the licence texts and notices: FFmpeg/mpv/libplacebo under LGPL; Mbed TLS/OpenSSL/shaderc under Apache-2.0
    (with NOTICE); FreeType FTL with its credit line; MIT/BSD/ISC for harfbuzz, dav1d, libxml2 and libass;
  - provide the **complete corresponding source of the LGPL libraries as built**, including patches, or a written offer.
    A pipeline that publishes source tarballs (freeKC's model) makes this trivial; recipe-only repositories don't
    (#1460);
  - not forbid reverse engineering of those parts in the app's terms.
- LGPLv3's "Installation Information" clause applies to hardware "User Products", not to app-store distribution onto the
  user's own device.
- **GPL builds** (Predidit's Linux bundle, the media-kit `encoders-gpl` flavor, or a distro libmpv bundled into an
  AppImage or Flatpak) make the distributed app subject to GPL obligations; under the FSF's reading, dynamic linking
  counts. That is unacceptable for a closed app.
- Codec patents (H.264, HEVC, AAC software decoders) are a separate question from copyright licences. MediaCodec
  hardware decoders are covered by the device vendor.

**Should the fork own its build pipeline, and when?** Yes, in this order:

1. **Windows, next.**
   - Needed for the D3D11 render API (mpv ≥ 4255130d), for a deliberate TLS default (schannel, or OpenSSL plus a CA
     bundle) and for compliance.
   - Start from freeKC/libmpv-builds: pinned sources, a container toolchain, source tarballs.
   - Pin mpv ≥ 4255130d (ideally a later commit that also has 40c998a1) and an FFmpeg release (n9.0.x, or 9.1 once
     released).
   - Host the releases under the fork. SHA-256 pins stop tampering, not disappearance of third-party personal
     repositories.
   - Effort M: the CI exists.
2. **Android, before the first mobile release.**
   - Fork Predidit/libmpv-android-video-build: it already pins every dependency by SHA (`depinfo.sh:16-37`), uses NDK
     r30, produces 16 KB pages and has reproducible-build flags.
   - Pin mpv v0.41.0 plus the two AImageReader commits, or a vetted master commit, and FFmpeg n8.1.x or n9.0.x.
   - Build libplacebo GL-only (no Vulkan, no shaderc).
   - Keep Mbed TLS 3.6.x with the `/dev/urandom` fix, and ship a CA bundle with verify on.
   - Drop the Kazumi HLS and TLS-off patches. Consider the `full` decoder set.
   - Effort M; CI time is one to two hours per run.
3. **Linux, when we bundle.** An mpv-build-style LGPL recipe in an old-glibc container; optionally carry the GLES highp
   sampler patch for Anime4K on NVIDIA. Effort M.

---

## 4. Proposed order of work

1. S: fix the Gradle 406 (not Predidit's, but it blocks every clean Android build).
2. S: a7d4a070 argv fix (allocate `args.length + 1` pointers and NULL-terminate; try/finally).
3. S: b11ec805 (`osc` as an init option).
4. S: d1ac737b (epoxy only).
5. S–M: 803c4a27 (native `video-out-params` status checks, `NativeNodeMap`, FLAG as int32).
6. M–L: lifecycle from a1b34d37 (C event loop, `NativeFinalizer`, idempotent ordered dispose, request rejection,
   screenshot ownership) through a build hook. Make the Windows `~VideoOutput` wait for `mpv_render_context_free`. Ship
   the release-mode `InitializerIsolate` stopgap first if this takes longer.
7. S–M: Windows, use Flutter's adapter for the D3D11 device and the ANGLE display.
8. Windows binary: freeKC after verification; then our own pipeline; then the native D3D11 renderer on the upstream
   render API with Predidit's mailbox as the reference (L).
9. M–L: Linux dedicated render thread plus mailbox (from #1346) onto #1466/#1464.
10. M: our own Android build, before the first mobile release.
11. L: native-assets packaging, with the manifest pointing at the fork's releases.
12. Later: 11f72195 (video bitrate).

Skip: df5a969e, 11d02cb8, the gpu-next/Vulkan defaults (e3732e30), the Kazumi HLS, ad-blocker and proxy changes, Apple,
OHOS. Hand off: 87cdfef7 to the `android-playback` agent.

---

## 5. Assumptions and points not verified at runtime

- No Windows or Android device was used. The broken Windows zero-copy follows from source: mpv 0.41.0's check plus the
  extension lists of ANGLE M155, and mpv's own commit message for 1d156861 says so. Confirm with `hwdec-current` or
  `--msg-level=vo=v,vd=v`.
- That HTTPS fails with `tls-verify=yes` is inferred from FFmpeg's TLS backends. I assume the cross-built OpenSSL's
  `OPENSSLDIR` points at a path that doesn't exist on users' machines.
- The NativeCallable crash comes from upstream #1348's reports and Predidit's documentation; I did not reproduce it.
- The ANGLE context requests ES 2 (`angle_surface_manager.h:105-109`); I assume ANGLE upgrades it to 3.x by default.
  This matters for Anime4K's FP16 FBOs and is unverified.
- freeKC's builds are two days old and come from a single maintainer.
- Predidit's Windows cross-device slot-reuse window is from reading the code; there is no reproduction.
- The size growth of Predidit's Android build (libplacebo, shaderc, Vulkan and the newer FFmpeg) was not broken down per
  component.
- Downloaded binaries and recipes for reuse: `tmp/_research-bin/` (219 MB) and `tmp/_research-src/`.
