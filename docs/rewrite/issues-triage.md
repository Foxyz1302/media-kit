# media_kit upstream issue triage for the Foxyz1302/media-kit fork

Date: 2026-10-23. Code references point to `ro-integration` at `9c0eef46` (upstream main `c533e446`, plus 14 merged PRs, plus the #1464 port). Paths are relative to that worktree.

**Inputs**
- All 341 open upstream issues.
- 43 issues closed since 2025-10-23. Only #260 is NOT_PLANNED; the rest are "completed".
- About 125 threads read in full, plus the open PRs, the recently closed PRs, and mpv's `player/client.c` and `audio/out/ao_wasapi.c` at master.
- The 2026-10-22 bench baseline (`results/2026-10-22-baseline/SUMMARY.md`).

**Scope.** Apple-only issues are dropped (listed at the end in one line). Ranking weighs platform first (Android, then Linux, then Windows), then category: crash, then playback, then leak/lifecycle, then rendering performance, then network, then audio, then controls, then API.

**Status keys**

| Key | Meaning |
|---|---|
| INT | Fixed on `integration` (the PR is named). |
| AP | Inside the stated scope of the `android-playback` branch. |
| AP-adj | Same code as `android-playback`. Coordinate before starting. |
| OPEN | Neither branch covers it. |
| PART | Partly fixed. |

**Effort keys**

| Key | Meaning |
|---|---|
| S | One day or less. |
| M | Two to five days. |
| L | More than a week, or native build-pipeline work. |

---

## Ranked table

| # | Issue(s) | Platform | Category | Status vs our branches | Effort |
|---|---|---|---|---|---|
| 1 | #1443 (+#1340 #1397 #1430 #1324) | Android, then all native | Crash: SIGABRT "Callback invoked after it has been deleted" | OPEN (closed PR #1424 had a partial fix) | S–M |
| 2 | #1420 | all native | Crash / UB: heap overflow on every `pause` write | OPEN | S |
| 3 | #1445 #1417 #997 #733 #648 #1120 #1215 (+#1298, the seek half of #1453) | Android | Playback: slow start, backward jumps, live black, lost `Media.start` | AP | – |
| 4 | #1289 (+#1198 #1378 #1090) | Android | Crash/lifecycle: Surface teardown on background or engine detach | OPEN, AP-adj | M |
| 5 | #700 (R17) (+#1395 Android ANR, #1276) | Android (+desktop) | Lifecycle/ANR: blocking libmpv calls on the platform thread | PART (#1454 INT) | M |
| 6 | #1437 #1331 #1269/#1426 #1093 #1312 | Android | Network/codecs: Android libmpv is from October 2023 | OPEN on Android; INT on Windows (#1436) | L (S–M if we adopt Predidit's build) |
| 7 | #1391 (+maybe #1309 #1019 #1053 #1141) | Android | Leak: about one sync_file FD per frame | OPEN | M to measure, L to fix |
| 8 | #1469 | Android build | Build: clean Android build fails with HTTP 406 | OPEN | S |
| 9 | #616 (+#1076 #1063) | all | Seek speed: `hr-seek` defaults are forced | OPEN | S |
| 10 | #1235 (+the `open()` half of closed PR #1453) | all | Playback/startup: `open()` goes through a temp-file `loadlist` | OPEN | S–M |
| 11 | No issue number (#700, #1099, #964 symptoms) | all | Lifecycle: one static `Lock` for every player | OPEN | M |
| 12 | #1421 (+#1217 #1319) | all | API gap: no FILE_LOADED / END_FILE(error) / PLAYBACK_RESTART | OPEN | S–M |
| 13 | No issue number (#1323 #1090 #1459 #1312 symptoms) | Android | Render perf: Surface is sized to the video, not the screen | OPEN, AP-adj | M |
| 14 | #1379 #1384 | Android | API: `waitUntilFirstFrameRendered` completes before any frame exists | OPEN, AP-adj | S |
| 15 | #1372 (+#1041) | all, worst on mobile | Network: HLS master probes every rendition, about 10 s TTFF | OPEN | M (mitigation) / L |
| 16 | #1295 | all | Network: truncated HLS segment is skipped, not retried | OPEN | M |
| 17 | #1061 (C22) (+#1019) | Android | Audio: `ao=opensles` forced (low volume, poor quality) | OPEN (needs #6) | S |
| 18 | #1390 | all | Playback: `jump()` resumes a paused player | OPEN | S |
| 19 | #1442 #1287 #672 | Linux | Crash: dispose races (S/W idle UAF, H/W populate vs free) | OPEN | M |
| 20 | #1438 | Linux | Render quality: GLES2 context, Anime4K colour shift | OPEN | M |
| 21 | No issue number (#838) | Linux + Windows | Render quality: texture = source size, `setSize` gets overwritten | OPEN | S + M |
| 22 | #1425 | Linux (+Windows) | Smoothness: no `report_swap`; `video-sync=audio` forced | OPEN | S–M |
| 23 | #1346 (skipped PR) | Linux | Render perf: mpv rendered on the raster thread, `glFinish` every frame | OPEN | S (fence) / M–L |
| 24 | #1427 | Linux | Correctness: S/W texture size uses integer division | OPEN (closed PR #1247 had a fix) | S |
| 25 | #1404 #1463 (+#1345 #957 #1016) | Linux | Render | INT (#1466, #1464 port); the others need re-testing | – |
| 26 | #1449 | Windows | Lifecycle: four disposals kill drag-and-drop (COM) | OPEN (mpv fix 4dfee616d0 is newer than the bundled 0.41.0) | S |
| 27 | #1465 | Windows debug | Crash (dev loop): stale pointer after PID reuse | OPEN | S |
| 28 | #1278 #296 | Windows | Perf/power: copy-back decoding through ANGLE | OPEN (unblocked by mpv#17764, merged 2026-10-15) | L |
| 29 | No issue number | Windows | Render perf: one shared render worker, renders block on target time | OPEN | S / M |
| 30 | #1441 #1366 #1437(Windows) #1383 #1232 #1431 | Windows | Mixed | INT (#1436, #1448, #1467) | – |
| 31 | #1257 #1253 | all (desktop focus) | Fullscreen: a separate route, a second `Video`, a reused FocusNode | OPEN | M |
| 32 | #1124 | all | Lifecycle: notifier written after dispose | OPEN | S |
| 33 | #386 | all | API/lifecycle: a reused Player returns the old platform controller | OPEN | S–M |
| 34 | #1252 #1374 | Android (mobile controls) | Controls: taps near the bottom are ignored | OPEN | S |

**Cross-cutting findings**
- **(a) The Android libmpv stack is about three years behind** the other platforms (#6). Several "media_kit bugs" are only that.
- **(b) The lifecycle is built on three fragile things:**
  - FFI callbacks from mpv's thread (#1);
  - blocking FFI calls on Android's main thread (#5);
  - a process-wide lock (#11).
- **(c) On desktop, mpv renders at the source resolution (#21).** Anime4K's upscale passes and mpv's scalers never run; Flutter's bilinear sampling does the scaling. This matters for the watch-together app.

---

## Per-issue sections

### 1. #1443: SIGABRT "Callback invoked after it has been deleted" in release builds
Same signature as #1340 (R13), #1397, #1430 and #1324.

**Symptom.** An Android release build aborts a few seconds after `Player.dispose()` or after leaving a screen. The SIGABRT is raised on the `mpv/mpv core` thread from `[anon:FfiCallbackMetadata::TrampolinePage]` (see the #1397 trace). Several reporters hit it; one ships a private fork carrying closed PR #1424 to avoid it. The hot-restart variant is fixed in base (#1416, #1352: debug mode uses the isolate loop). The release path is not.

**Cause.** mpv delivers wakeups through a `NativeCallable.listener` trampoline called from mpv's core thread:
- The trampoline is registered in `media_kit/lib/src/player/native/core/initializer_native_callable.dart:51-56`, and the drain loop is at `:72-81`.
- Release and profile builds always take this path (`core/initializer.dart:50-57`).
- On dispose, the callback is cleared and the callable closed at once (`initializer_native_callable.dart:61-70`), and the core is destroyed 5 s later (`native/player/real.dart:112-116`).

**Correction to the thread.** The "in-flight callback" theory in #1443 and #1424 is not correct for mpv itself. `mpv_set_wakeup_callback` and `wakeup_client` take the same `ctx->wakeup_lock` (`client.c:343-380`), so mpv cannot call the old trampoline after the clear returns. The abort is real, so the trampoline is still being invoked after deletion. The most plausible path is the isolate dying while handles are alive: back or swipe-away detaches the engine, or a background engine shuts down. That is the same trigger as #1289.

**Status:** OPEN.

**Fix**
- **(a)** Make the isolate event loop (`InitializerIsolate`, which already ships for debug builds) the default in every mode. It has no native-to-Dart callback, so neither dispose nor isolate death can trip the VM check.
- **(b)** Keep NativeCallable as an opt-in, with the ordering from #1424: clear the callback, then `mpv_terminate_destroy`, then close.
- **(c)** Best-effort: on `AppLifecycleState.detached`, clear the wakeup callbacks and `quit` every live handle. This is the same code as the hot-restart cleanup at `real.dart:42-71`.

**Effort / risk.** S for (a) and (b); M with (c). Risk: one isolate hop per event, roughly tens of µs. Measure it.

**Verify**
- Bench app: loop create, open, play 2 s, dispose ×200 in profile and release builds.
- Bench app: `SystemNavigator.pop()` while playing.
- Logcat: zero SIGABRT.
- A headless Dart stress test (100 create/dispose cycles) on Linux CI.

### 2. #1420: heap-buffer-overflow in `mpv_set_property_async` (reads 4 bytes from a 1-byte allocation)

**Cause.** `_setPropertyFlag` allocates `calloc<Bool>(1)` (`real.dart:2501-2505`), but `MPV_FORMAT_FLAG` is a C `int`. mpv copies 4 bytes in the async path and dereferences an `int` in the sync path. This runs on every `pause` change (`open`/`play`/`pause`, `real.dart:184, 210-218, 351-405`). Values come out right only because allocators zero the slack; under ASan it aborts (#1420, a Linux snap).

**Same class of bug.** `_screenshot` builds its argv with `calloc.allocate(args.join().length)` (`real.dart:2685`). That is a character count used as a byte size for a pointer array. Two args allocate 19 bytes where 24 are needed, so the NULL terminator is out of bounds.

**Fix**
- Use `calloc<Int32>()..value = v ? 1 : 0`.
- Use `calloc<Pointer<Utf8>>(args.length + 1)`.
- Grep for any other narrow writes.

**Effort / risk.** S, no risk.

**Verify.** The existing headless tests (`media_kit/test/src/player`) on Linux, optionally run under ASan (`LD_PRELOAD` libasan), plus a screenshot test.

### 3. AP block: widListener re-init and the stale seek
Covers #1445, #1417, #997 (R3), #733 (R5), #648 (R5), #1120, #1215, closed #1298, and the seek half of closed PR #1453.

**Symptoms**
- Live or non-seekable streams render once, then go black in a decoder re-init loop (#1445).
- Playback starts at the first keyframe instead of 0 (#1417).
- HLS starts 8–10 s in (#997, #733).
- Playback stutters or pauses right after it starts (#648, #1120).
- `Media.start` and resume seeks are lost on Android (#1215, #1298).
- A SIGABRT on a seek at end of file (#1453).

**Cause.** `widListener` (`media_kit_video/lib/src/video_controller/android_video_controller/real.dart:51-88`) runs on every Surface (re)attach. It sets `vo=null`, then `android-surface-size`, `wid` and `vo`, then `seek(player.state.position)`. On the first attach `position` can still be 0. That wipes the `start` value set in the `on_load` hook (`real.dart:2152-2190`) and any seek issued right after `open()`. On non-seekable streams the seek fails outright.

**Status:** AP.

**Regression cases to hand to android-playback**
1. `Media(start: 5 min)`, and a `seek` issued right after `open()` (#1215).
2. A clip whose first keyframe is at 8 s (#1417).
3. Apple's bipbop live variant playlist (#1445).
4. HLS VOD start position (#997).
5. End of file, then loop, then open the next item (#1453).

**Facts for android-playback**
- `VideoOutput.setSurfaceSize` fakes a new surface: `VideoOutput.kt:124-131` calls `onSurfaceAvailable()`, so every resize changes `wid`.
- Each call overwrites `wid` with a new JNI global ref without deleting the old one (`:142`), a small leak.
- The #1445 reporter found that gating `create()` on a real Surface deadlocks. Item #13 removes the re-attach instead.

### 4. #1289: crash on background or exit (+#1198, #1378, #1090)

**Symptoms**
- `FlutterJNI is not attached to native` from `ImageReaderSurfaceProducer.onImage` on Back, Home or swipe-away. "A lot in our Sentry", reported on Flutter 3.35.
- Audio only, no picture, after a quick background and foreground (#1198).
- ImageReader "maxImages" warnings, and a missing completion, when the widget is gone (#1378).
- 4K stutters after resume (#1090).

**Cause**
- **(a)** `MediaKitVideoPlugin.onDetachedFromEngine` (`media_kit_video/android/src/main/kotlin/com/alexmercerind/media_kit_video/MediaKitVideoPlugin.kt:71-73`) only clears the channel. SurfaceProducers survive, and mpv keeps feeding their ImageReaders after detach.
- **(b)** `onSurfaceCleanup` (`VideoOutput.kt:152-166`) only posts `wid=0` to Dart. mpv detaches later, asynchronously, but Flutter invalidates the Surface as soon as the callback returns.
- **(c)** `NativePlayer.dispose` sets `disposed = true` (`real.dart:108`) before the release hooks run (`:110`). So `AndroidVideoController._dispose` (`android_video_controller/real.dart:229-240`) cannot detach mpv before `VideoOutputManager.Dispose` releases the Surface.

**Status:** OPEN, AP-adj.

**Fix**
- Dispose every VideoOutput in `onDetachedFromEngine`.
- Detach mpv synchronously in `onSurfaceCleanup`, as mpv-android's `detachSurface` does. This needs a small NDK shim in the plugin that calls `mpv_set_property(handle, "vo", "null")` / `wid=0`.
- In `_dispose`, detach before releasing.
- Expose `VideoController.detach()` / `attach()` (the API #1378 asks for).

**Effort / risk.** M, medium risk (the Surface lifecycle is the fragile area).

**Verify.** Manual Android: Home then resume within 1 s ×20; back out of the root route while playing; screen off/on. Check logcat for FlutterJNI and EGL errors. Bench: count ImageReader warnings during background playback.

### 5. #700 (R17), #1395 (Android ANR part), #1276: blocking libmpv calls on the platform thread

**Symptom.** `dispose()` freezes the UI ("4 s hang on Android"). Feed swipes jank. An ANR 26 s after rotating (#1395).

**Cause.** Since Flutter 3.29, Dart runs on Android's main thread, so these blocking FFI calls become main-thread stalls:
- `mpv_terminate_destroy` (`real.dart:114-116`). It joins the core thread, which waits for demuxer/network, VO and AO, then runs `mp_destroy` on the calling thread (`client.c` `mp_destroy_client`).
- `mpv_create` / `mpv_initialize` (`initializer_native_callable.dart:42-50`).
- Sync `getProperty` (`real.dart:1222`).
- The `observeProperty(NONE)` handler's read (`real.dart:1507`).
- `queryDecoders` (`media_kit_video/lib/src/utils/query_decoders.dart:32`).

#1454 (INT) fixed the worst case, the sync `setProperty` used by widListener. Separately, the event drain loop runs entirely in microtasks (`initializer_native_callable.dart:74-79`). An event storm, such as VO re-init loops or verbose logs, can starve frames. That matches the `RunMicrotasks` stall in the #1395 trace.

**Status:** PART.

**Fix**
- Run terminate and create in a helper isolate (`Isolate.run`; the handle is a plain int).
- Move `getProperty` to `mpv_get_property_async`.
- Yield to the event loop (a Timer) every N events.

**Effort / risk.** M, low risk.

**Verify.** Bench: FrameTiming gaps around `dispose`; dispose-to-next-open latency; 30 rotations during playback without an ANR.

### 6. The Android libmpv is from October 2023
Covers #1437 (TLS 1.3), #1331 (R6, fMP4 HLS seek stuck), #1269 and closed #1426 (no PGS decoder), #1093 (`gpu-next` unavailable), #1312 (4K lag), and the mpv `stop_play` assert behind #1453.

**Evidence.** `libs/android/media_kit_libs_android_video/android/build.gradle.kts:75-96` downloads `media-kit/libmpv-android-video-build` v1.1.11. Its `depinfo.sh` pins:
- mpv `78d43740` (2023-10-14);
- FFmpeg 6.0;
- mbedTLS 3.4.0, built without the TLS 1.3 client (#1437 checked the strings);
- dav1d 1.2.0;
- no libplacebo.

Windows already moved to libmpv 0.41.0 in #1436 (INT), and Linux uses the system mpv, so Android is the outlier. The `stop_play` assert (mpv#13778) was fixed by mpv#14135 on 2024-05-16. The Android build predates it.

**Fix.** Rebuild, or first evaluate `Predidit/libmpv-android-video-build` v1.3.1 (2026-10-18). Predidit's media-kit fork already uses it. It has:
- mpv and FFmpeg heads from 2026-10-13;
- mbedTLS 3.6.7;
- dav1d 1.5.4;
- libplacebo;
- NDK 30.

Before adopting it, check:
- that its pinned `media_kit_android_helper` (`b768ce10`) is ABI-compatible with ours;
- the licence variant of the "default" jars.

Then move the jar checks from MD5 to SHA-256.

**Status:** OPEN for Android.

**Effort / risk.** L to own the build pipeline; S–M to adopt the jars. Medium risk (regressions from fresh FFmpeg).

**Verify**
- Bench: the full codec matrix (rate, drops, TTFF, `hwdec-current`).
- A TLS 1.3-only HTTPS endpoint: `bench_server.py` with `ssl.TLSVersion.TLSv1_3` as the minimum.
- An fMP4 HLS seek outside the cache.
- A PGS sample with `libass: true`.
- CI build.

### 7. #1391: sync_file FD leak, about one FD per frame (Android)

**Symptom.** The FD count climbs about 25 per second at 25 fps until "Too many open files".
- Predidit has identified two separate leaks:
  - one specific to Honor devices, independent of the VO;
  - one on the `gpu-next` GL path on all devices, patched in his branch.
- The reporter's results: `vo=gpu` still leaks on Honor. `gpu-next` does not leak, but renders black there.

**Hypothesis.** #1309 (freeze after about 30 min while audio continues), #1019 (audio track dies after about 25 min) and #1053/#1141 (loop stops after hours) may be the same leak. If the soft limit is 32768 FDs, 25 FDs per second exhausts it in about 22 minutes.

**Status:** OPEN.

**Fix.** Measure on the user's device first. If `vo=gpu` leaks there, the fix comes with #6, plus Predidit's libplacebo fence patch if we move to `gpu-next`.

**Effort.** M to measure, L to fix.

**Verify.** The bench app can measure this itself with no adb. Every 10 s for 10 min of playback, log `Directory('/proc/self/fd').listSync().length`. Do it for each hwdec/VO config.

### 8. #1469: clean Android build fails with HTTP 406 (reported 2026-10-22)

**Cause.** `URI.create(url).toURL().openStream()` sends Java's default `Accept` header. This is at:
- `libs/android/media_kit_libs_android_video/android/build.gradle.kts:107`;
- the same line in `media_kit_libs_android_audio`.

GitHub's release-asset redirect answers 406. curl works.

**Status:** OPEN.

**Fix.** Use `HttpURLConnection` with `Accept: application/octet-stream`, a User-Agent, redirects, timeouts and a retry. Use SHA-256 (as #1467 did for Windows).

**Effort.** S.

**Verify.** CI: `flutter clean && flutter build apk` on a runner with no Gradle cache.

### 9. #616 (R5), #1076, #1063 (R7): slow seeks, "buffering got worse after 1.0"

**Cause.** `hr-seek=yes` and `hr-seek-framedrop=no` are forced (`real.dart:2339-2340`). Every seek is exact, and every frame from the keyframe to the target is decoded and kept. With 4K HEVC and 2–10 s GOPs, that is seconds per seek.

**Status:** OPEN.

**Fix.**
- Return to mpv's defaults (`hr-seek=default`, `hr-seek-framedrop=yes`).
- Add `seek(d, {SeekMode mode})`:
  - `absolute+keyframes` while scrubbing;
  - `absolute+exact` on release and for watch-together resync.

**Effort / risk.** S. Low risk; the behaviour changes only when the caller doesn't ask for exact.

**Verify.** A new bench metric: `seek()` to PLAYBACK_RESTART latency on 1440p HEVC and H.264. A headless test that exact mode lands within ±1 frame.

### 10. #1235: `open()` goes through a temp-file `loadlist`

**Cause.** `open()` writes the playlist to a temp file, runs `loadlist <file> append`, then sets `playlist-pos` (`real.dart:193-221`). Three problems follow:
- Entries loaded from a playlist file pass mpv's playlist safety check. "Unsafe" URLs such as `tcp://` and `udp://` are refused ("Use --load-unsafe-playlists"). This is a regression from 1.1.11, with two reports.
- It costs a disk write on every `open()`, which adds to startup.
- The `stop` + `append` + `playlist-pos` sequence is the one #1453 tied to mpv's `stop_play` assert on old mpv (see #6).

**Status:** OPEN. android-playback takes only the widListener half of #1453.

**Fix.** Use `loadfile <uri> replace` for the first item and `append` for the rest, as the `fd://` branch already does (`real.dart:186-191`). Pause before loading. Skip `playlist-pos` when the index is 0. This is the `open()` half of #1453.

**Effort / risk.** S–M, low-to-medium risk (playlist index semantics).

**Verify.** The headless open/playlist/jump/index tests on Linux; a `tcp://` source from local `ffmpeg -listen 1`; the bench end-of-file/loop case on Android.

### 11. One static `NativePlayer.lock` for every player (no upstream issue)
It explains #700's "next video glitches a second or two" and the multi-player reports (#1099, #964).

**Cause.** `static final Lock lock` at `real.dart:2638`. Every `open`, `seek`, `play` and `dispose` of every player in the process serialises on it. `dispose` holds it across:
- `waitForVideoControllerInitializationIfAttached`;
- the `stop` command round trips;
- the release hooks (method-channel calls).

The web player uses an instance lock (`web/player/real.dart:1574`). If one VideoController never initialises, every player hangs: `NativeVideoController.create` waits for a texture ID with no timeout (`native_video_controller/real.dart:158-179`).

**Status:** OPEN.

**Fix.** A per-instance lock, timeouts on the controller-initialisation waits, and an audit of the other statics (`audioBitrateCache`, the Initializer singletons).

**Effort / risk.** M, medium risk.

**Verify.** A headless Dart test: player A's `open()` against a stalled URL (bench_server with a delay) must not block player B's `seek()`. Bench: feed-swipe latency.

### 12. #1421, #1217, #1319: missing lifecycle events

**Cause.** `_handler` (`real.dart:1377ff`) reacts only to START_FILE (`:1482`), property changes, logs and hooks. FILE_LOADED, END_FILE (with its error code), PLAYBACK_RESTART, SEEK and SHUTDOWN are ignored. That has three consequences:
- `open()` resolves as soon as the commands are queued (#1217).
- Load failures are known only by scraping log text (`real.dart:2042-2090`), and that depends on the log level.
- Chapters have no stream (#1319).

**Status:** OPEN.

**Fix.** Add these streams:
- `stream.loaded`;
- `stream.playbackRestart`, the "seek has settled" signal watch-together sync needs;
- a structured `stream.endFile{reason, error}`, which gives the ComfyUI client a real "failed to load" state;
- `stream.chapters`.

Optionally, let `open()` complete on FILE_LOADED and throw on an END_FILE error.

**Effort / risk.** S–M, additive.

**Verify.** Headless tests: a missing URL produces a coded error; a seek produces `playbackRestart`; a chaptered MKV produces chapters.

### 13. Android renders at the video's resolution, not the screen's (no upstream issue)
Related reports: #1323, #1090, #1459, #1312.

**Cause.** The video-params listener sizes the SurfaceProducer to dw×dh (`android_video_controller/real.dart:96-138`). widListener then passes the same size as `android-surface-size`. `setSize` throws on Android (`:222-226`).

A 4K stream on a 1080p-class phone renders and composites 3840×2160 RGBA every frame. The bench shows the cost: landscape with an overlay has a raster p90 of 12–15 ms, against an 8.3 ms budget at 120 Hz.

**Status:** OPEN, AP-adj.

**Fix**
- Create the surface once, at min(video size, display physical size).
- Set `keepaspect=no`, so mpv fills the surface and Flutter's `FittedBox` (driven by the video-params `rect`) restores the aspect ratio.
- With this, video-params no longer trigger a re-attach, which removes the VO-reinit-and-seek path behind #3.
- Expose `setSize` on Android.

**Effort / risk.** M, medium risk (aspect, rotation, SAR).

**Verify.** Bench: raster p90/p99 and drops in the landscape overlay window, at 1440p and 4K, current versus clamped.

### 14. #1379, #1384: `waitUntilFirstFrameRendered` completes before a frame exists (Android)

**Cause.** It completes in the video-params listener (`android_video_controller/real.dart:134-136`), before any Surface exists. Dart handles `VideoOutput.WaitUntilFirstFrameRenderedNotify` (`:270-281`), but the Kotlin side never sends it.

**Status:** OPEN, AP-adj.

**Fix.** Complete on the first PLAYBACK_RESTART after `vo-configured` is true with a non-zero `wid`. This depends on #12.

**Effort.** S.

**Verify.** Bench: log the completion time against the first `time-pos` advance, and check it on a frame-counter clip.

### 15. #1372 (R4) (+#1041, same symptom reported on iOS): about 10 s to first frame on HLS masters with renditions

**Cause.** FFmpeg's HLS demuxer opens and probes every variant and rendition before the first frame. `demuxer-lavf-analyzeduration=0` does not stop it. ExoPlayer and AVPlayer start on a single variant. FFmpeg's HLS also has no ABR, so #1184 and #982 (R10) can't be fully met.

**Status:** OPEN.

**Fix options**
- **(a)** In the app: parse the master playlist and open the chosen media playlist directly. In-player switching is lost.
- **(b)** Try `demuxer-lavf-o` probe limits and `hls-bitrate=min`, and measure.
- **(c)** The real fix is an FFmpeg patch for lazy rendition probing.

**Effort.** M for the measurement and mitigations; L for the patch.

**Verify.** bench_server serves a master with 5 audio and 6 video renditions; record TTFF for each option.

### 16. #1295: a truncated HLS segment is skipped, not retried

**Cause.** FFmpeg's HLS demuxer retries only failed opens (`seg_max_retry=5`, `real.dart:2362`). A short read ("Stream ends prematurely") simply ends the segment, and playback jumps ahead.

**Status:** OPEN.

**Fix.** Test the HTTP `reconnect*` options through `demuxer-lavf-o` / `stream-lavf-o`, and check whether the HLS demuxer passes them to segment I/O. If not, an FFmpeg patch. Expose a network-retry setting.

**Effort.** M.

**Verify.** bench_server fault injection: truncate segment N once, then assert there is no position jump.

### 17. #1061 (C22), #1019: weak audio on Android

**Cause.** `ao=opensles` is forced on Android (`real.dart:2345-2346`). In the thread, `ao=audiotrack` sounds correct, but it crashed on the old mpv. mpv#15213 fixed that, and the fix is in mpv 0.40 and later.

**Status:** OPEN; depends on #6.

**Fix.** After #6, default to `ao=audiotrack,opensles`.

**Effort.** S.

**Verify.** A manual A/B listening test, and the bench audio matrix with no errors.

### 18. #1390: `jump()` resumes playback and briefly plays the previous track

**Cause.** The native `jump()` calls `play()` before it sets `playlist-pos` (`real.dart:636-637`).

**Status:** OPEN.

**Fix.** Set `playlist-pos` first and keep the pause state, or add a `play` parameter.

**Effort.** S.

**Verify.** A headless test.

### 19. #1442, #1287, #672: Linux dispose races

**Cause**
- **S/W path.** The update callback queues `gdk_threads_add_idle` with a raw `self` (`media_kit_video/linux/video_output.cc:323-355`). Dispose never removes that source, and it calls `g_mutex_clear` on the mutex (`:97`). A queued idle then runs on freed memory: use-after-free or a permanent hang.
- **H/W path.** Dispose frees `mpv_render_context` on the platform thread (`:59-75`). Meanwhile, the raster thread can be inside `texture_gl_populate_texture` rendering with it (`texture_gl.cc:198-405`); populate never checks `destroyed`.
- `TextureGL` keeps a raw `VideoOutput*` that it can outlive (`texture_gl.cc:130-184`).

**Status:** OPEN.

**Fix**
- Ref the output for idle sources (`g_object_ref` plus a `GDestroyNotify`) and track source IDs.
- Add a per-output mutex taken by populate (which checks `destroyed`) and by dispose before it frees the render context.
- Clear `texture_gl->video_output` on dispose.

**Effort / risk.** M, low-to-medium risk.

**Verify.** Desktop stress: 50 create/open/dispose cycles on both the H/W and S/W paths, and an ASan build of the Linux runner.

### 20. #1438: Anime4K colour shift from the GLES2 context (Linux)

**Cause.** The isolated context is ES2:
- `EGL_OPENGL_ES2_BIT` (`media_kit_video/linux/isolated_egl.cc:82`);
- `eglBindAPI(EGL_OPENGL_ES_API)` with client version 2 (`:100-102`).

In ES mode, mpv declares `precision mediump sampler2D`. NVIDIA honours mediump, which shifts colours through multi-pass shaders such as Anime4K. Linux uses the system libmpv, so patching mpv the way Predidit/libmpv-linux-build#9 does is not an option for us.

**Status:** OPEN.

**Fix.** Prefer a desktop GL core context (`EGL_OPENGL_BIT` with `eglBindAPI(EGL_OPENGL_API)`) when the display offers one, and fall back to ES. Keep `isolated_egl_texture_sharing_problem` as the gate.

**Effort / risk.** M. Medium risk: EGLImage sharing from desktop GL into Flutter's GLES context on Mesa and NVIDIA.

**Verify.** Manual desktop: Anime4K Mode A on NVIDIA and Mesa, X11 and Wayland, compared with an mpv CLI screenshot.

### 21. Desktop textures are sized to the source, and `setSize` is overwritten (no upstream issue; #838 asks how to upscale)

**Cause.** The texture is sized from `video-out-params`:
- Linux: `video_output.cc:423-521`;
- Windows: `media_kit_video/windows/video_output.cc:421-517`.

So mpv's output equals its input. Anime4K's upscale passes, which are guarded by `//!WHEN OUTPUT.w MAIN.w / 1.2 > …`, never run, and the `scale=` setting is bypassed; Flutter's bilinear sampling does the upscaling.

`VideoController.setSize()` exists, but it doesn't stick. The video-params listener (`native_video_controller/real.dart:75-107`) re-sends `SetSize` with the video's dimensions on every new file and never checks for a fixed size, so it overwrites the caller's size.

**Status:** OPEN.

**Fix**
- **S:** skip that `SetSize` call when a fixed size is set.
- **M:** an opt-in "render at widget size" mode (layout × devicePixelRatio, debounced) for the watch-together app.

**Effort / risk.** S + M. Low risk for S; medium for M (resize churn).

**Verify.** Manual desktop: call `setSize(3840, 2160)`, open a second file, and check the `rect` logs. The `vo-passes` property should list the Anime4K upscale passes.

### 22. #1425: no `mpv_render_context_report_swap`, and `video-sync` forced to audio

**Cause**
- No swap is ever reported: not by the Linux `texture_gl.cc` (render at `:361`), nor by Windows `Render()` (`video_output.cc:190`).
- Both platforms force `video-sync=audio` when the output is created, which silently overwrites the app's own setting:
  - Linux: `linux/video_output.cc:153`;
  - Windows: `windows/video_output.cc:36-37`.

As a result, display-resample and vdrop cannot work, and `vsync-ratio` stays null.

**Status:** OPEN.

**Fix.** Report a swap after each populate/Render, as an approximation of presentation. Set `video-sync` only if the app hasn't, and expose the choice.

**Effort.** S–M.

**Verify.** Manual desktop: `vsync-ratio` and `display-fps` are non-null, and `mistimed-frame-count` stays flat with display-resample on a 24 fps clip at 60 Hz.

### 23. #1346 (skipped PR): Linux renders mpv on the raster thread and calls `glFinish` every frame

**Cause.** Populate renders synchronously on Flutter's raster thread. On the blit path it then calls `glFinish()` (`texture_gl.cc:361-381`), so the raster thread waits for all of mpv's GPU work, which is heavy with Anime4K at 4K. Each frame also costs two `eglMakeCurrent` switches.

**Status:** OPEN.

**Fix**
- **S:** replace `glFinish` with an EGL fence: `eglCreateSyncKHR` in mpv's context, `eglWaitSyncKHR` in Flutter's.
- **M–L:** port #1346's dedicated render thread with triple buffering. It touches the same files as #1466 and #1464, so port it rather than merge it. Its author also notes that one shared thread stutters with several players.

**Effort / risk.** S, or M–L for the port. Medium risk.

**Verify.** Desktop FrameTiming raster p90 with 4K + Anime4K, before and after.

### 24. #1427: Linux S/W texture size

**Cause.** Integer division: `width / height * MAX` (`linux/video_output.cc:466, 516`). A 1600×1200 video renders at 1080×1080. Closed PR #1247 fixed it.

**Status:** OPEN.

**Fix.** Use `width * MAX_H / height`, as Windows already does (`windows/video_output.cc:463, 512`), and compute both axes together.

**Effort.** S.

**Verify.** A C++ unit test next to `linux/test/isolated_egl_test.cc`.

### 25. Linux fixes already on integration, and what still needs a re-test

**Fixed on integration**
- #1404 (H/W rendering off since Flutter 3.38) by #1466.
- #1463 (black video on Mesa) by the #1464 port.

**Re-test on integration before spending time on them**
- #1345 (tearing since Flutter 3.38): no PR claims it, but it dates from the same rendering change.
- #957 and #1016 (black screen on reopen).

**Verify.** Manual desktop on X11 and Wayland, with Intel, AMD and NVIDIA.

### 26. #1449: four `Player` disposals break drag-and-drop (Windows)

**Cause**
- `mpv_terminate_destroy` runs `mp_destroy` on the calling thread, which here is the UI thread.
- The WASAPI hotplug instance comes from observing `audio-device-list` (`real.dart:2407`). It initialised and uninitialised COM on whatever thread it ran on.
- mpv fixed this in `4dfee616d0` on 2026-10-16 ("ao_wasapi: hold an MTA reference for the hotplug instance"). The libmpv 0.41.0 that integration ships (`LIBMPV_RELEASE 20260926`) predates that commit.

**Status:** OPEN.

**Fix.** Run teardown off the UI thread, which is the same change as #5 and fixes it whatever the libmpv. Bump the Windows libmpv once a build with that commit exists.

**Effort.** S.

**Verify.** Manual Windows, using the issue's `desktop_drop` repro.

### 27. #1465: stale pointer after PID reuse (Windows debug builds)

**Cause.** The address is stored in `%TEMP%/…NativeReferenceHolder.$pid` (`media_kit/lib/src/player/native/utils/native_reference_holder.dart:124-129`) and dereferenced unchecked at startup (`:59-60`). When Windows reuses a PID, the next process reads the old pointer and crashes.

**Status:** OPEN.

**Fix.** Keep the address in a process environment variable through FFI (`setenv` / `SetEnvironmentVariableW`). It survives hot restart and dies with the process.

**Effort.** S.

**Verify.** Plant a stale file for the next PID, then start a debug build.

### 28. #1278, #296: Windows CPU and power cost of copy-back decoding

**Cause.** The render path is OpenGL through ANGLE, so d3d11va output is copied back to the CPU. The maintainers confirmed this in the thread.

mpv merged a D3D11 render API (mpv#17764) on 2026-10-15. Predidit was waiting for exactly that before doing zero-copy.

**Status:** OPEN.

**Fix.** A D3D11 render path that shares the texture through `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` (already used for the ANGLE textures), with zero-copy d3d11va. It needs a libmpv built after that merge.

**Effort / risk.** L, high risk.

**Verify.** Manual Windows: CPU % and package power on 4K HEVC, and Anime4K under D3D11.

### 29. Windows: one shared render worker, and renders that block (no upstream issue)

**Cause**
- There is one `ThreadPool(1)` per manager (`windows/video_output_manager.h:77`), so every player renders on the same worker.
- `Render()` doesn't pass `BLOCK_FOR_TARGET_TIME=0` (`windows/video_output.cc:186-190`), so each render can wait for its frame's target time while other players queue behind it.
- Each frame posts two tasks, CheckAndResize and Render (`:159-165`).

**Status:** OPEN.

**Fix.** Pass `BLOCK_FOR_TARGET_TIME=0`, as #1440 did on Linux (S). Per-output workers are an M follow-up.

**Effort.** S, or M for per-output workers.

**Verify.** Manual Windows: frame pacing with two players, one at 24 fps and one at 60 fps.

### 30. Windows fixes already on integration

**What each PR covers**
- **#1436** (libmpv 0.41.0 for x64 and ARM64, plus fresh ANGLE) covers:
  - #1441 (black screen on HLS masters with subtitle renditions);
  - #1366 (H.264 10-bit crash on NVIDIA via Vulkan);
  - TLS 1.3 for the Windows video package (per a comment on #1437).
- **#1448** covers #1383 (multi-engine hang).
- **#1467** covers #1232 and #1431.

**Still open.** The Windows audio package still ships the old libmpv (libmpv-win32-audio-cmake#4 is pending).

**Verify.** CI Windows build. Manual checks:
- the akamaized ABC stream from #1441;
- an H.264 10-bit file on NVIDIA;
- a multi-engine window.

### 31. #1257, #1253: fullscreen is a new root route with a second `Video`

**Cause.** `enterFullscreen` pushes a route on the root navigator holding a fresh `Video`, and carries over only the `controls` builder (`media_kit_video/lib/media_kit_video_controls/src/controls/methods/fullscreen.dart:28-85`). The effects:
- Anything the app layered around `Video`, such as chat or overlays, is missing in fullscreen.
- Overlays opened from a nested navigator land underneath the fullscreen route.
- The same FocusNode is handed to the second `Video` while the first is still mounted (`:72-73`), so keyboard shortcuts die (#1253).
- Exit calls `maybePop()` without `rootNavigator` (`:97`).

**Status:** OPEN.

**Fix.** For the watch-together app, skip the route entirely: make the app's own layout fullscreen and call `Utils.EnterNativeFullscreen`. In the library, add an in-place fullscreen mode and stop reusing the FocusNode.

**Effort.** M.

**Verify.** Widget tests for focus and the route stack, plus a manual desktop check.

### 32. #1124: `ValueNotifier<VideoViewParameters>` used after dispose

**Cause.** `didUpdateWidget` sets the notifier in a post-frame callback with no `mounted` check (`media_kit_video/lib/src/video/video_texture.dart:272-276`).

**Status:** OPEN.

**Fix.** Check `mounted` first.

**Effort.** S.

**Verify.** A widget test that rebuilds and disposes in the same frame.

### 33. #386: a reused `Player` gets the old platform controller and its old config

**Cause**
- `create()` returns the cached controller keyed by handle, ignoring the new configuration:
  - Android: `android_video_controller/real.dart:165-169`;
  - native: `native_video_controller/real.dart:122-126`.
- `VideoController.dispose()` doesn't release the platform side (`video_controller.dart:139-143`).
- `Video` doesn't re-subscribe when its controller changes: `video_texture.dart:238-277` only handles view parameters, while the subscriptions are set once at `:308-342`.

**Status:** OPEN.

**Fix.** Re-apply `hwdec`/`vo` when the config differs. Make `dispose()` detach the platform side. Re-bind the subscriptions in `didUpdateWidget`.

**Effort.** S–M.

**Verify.** Widget tests with a mocked channel.

### 34. #1252, #1374: mobile controls ignore taps near the bottom

**Cause.** The gesture `Listener` sits in a `Positioned.fill` inset by 16 px plus the subtitle shift (`media_kit_video/lib/media_kit_video_controls/src/controls/material.dart:906-912`). The bottom-bar region intercepts the taps. The maintainers say the 16 px insets are deliberate, to stay clear of system gestures.

**Status:** OPEN.

**Fix.** Make the insets configurable, and route taps on the hidden bottom bar to the show/hide toggle.

**Effort.** S.

**Verify.** A widget test.

---

## Open upstream PRs not merged into integration

**Relevant**
- **#1346, Linux dedicated render thread.** Addresses #23. It overlaps the #1466 and #1464 files; port it selectively after measuring the fence fix.
- **#1410, declarative PiP (iOS 15+, Android 8+).** Addresses #157 (R6). Android PiP may matter for the mobile apps. Low priority.
- **#1381, Windows ARM64 CI and ANGLE.** Mostly superseded by #1436 (ARM64 libmpv and ANGLE). Only the CI part is left.
- **#1335 and #1347, Actions version bumps.** Take them when fixing CI (#1447).

**Out of scope:** #1326 (OHOS), #1462 (Darwin), #206 (iOS PiP).

**Closed without merging, but worth reviving**
- #1424 (see #1).
- #1453: the `open()` half goes to #10; the seek half is AP.
- #1247 (see #24).
- #1181: `Uri.parse` throws on `lavf://crypto:file:...`. Low priority.
- #1375: makes `keep-open` configurable. Low priority.

**External**
- `Predidit/libmpv-android-video-build` v1.3.1 (for #6).
- mpv `4dfee616d0` (for #26).
- mpv#17764, the D3D11 render API (for #28).
- Predidit's `upstream-better-linux-render` branch, which is #1346.

## Closed, not-planned or stale, last 12 months
Only #260 is NOT_PLANNED (log noise). Closed issues that are still real:

| Issue | Why it's still real |
|---|---|
| #1426 | Android PGS. Closed silently; the cause is the missing decoder, #1269 / #6. |
| #1298 | `Media.start` on Android. Still broken by the stale seek (AP). |
| #1444 | WASAPI crash on the first unpause. The reporter closed it as possibly app-caused. |

#1439 was fixed by #1440, which is already in base.

## Apple-only issues dropped
#1462 #1418 #1399 #1382 #1373 #1361 #1268 #1263 #1250 #1224 #1218 #1192 #1182 #1176 #1171 #1161 #1148 #1147 #1142 #1100 #1097 #1095 #1080 #961 #856 #843 #717 #712 #699 #665 #632 #627 #588 #1284 #1306
