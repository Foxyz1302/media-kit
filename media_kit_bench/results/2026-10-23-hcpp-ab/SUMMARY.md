# HCPP A/B for better_native_video_player's platform view, 2026-10-23

**Question:** does Hybrid Composition++ (HCPP) make the platform-view mode (`androidTextureMode: false`) both play smoothly and move smoothly?

**Answer:** only partly.
- **Moving: yes.** With HCPP, the mini-player animation runs at 114 Flutter fps and 111 presented fps, with ~3 gaps of 3+ vsyncs per 6 s. Hybrid composition (HC): 80 / 64 fps and ~61 gaps.
- **The video while it moves: yes.** It keeps 60 fps, with 1.2 late frames/s (HC: 0.4/s).
- **Video alone: yes.** 59 fps, 1.1 late frames/s (HC: 0.6/s).
- **Flutter UI animating over the video: no.**
  - The video gets about 6 late frames per second (31 per 5 s window); HC gets 0.7/s.
  - Flutter raster p90 goes from 3.7 to 10.4 ms, and 132 frames per 5 s take over 8.3 ms.
  - Only 87 of the 105 Flutter fps reach the screen.
  - The bench's controls overlay animates on every frame (progress bar + spinning icon), so this is the worst case. Static controls were not measured.
- **Texture mode is the opposite.**
  - The UI holds ~119 fps in every phase, with raster p90 ≤ 5 ms, and overlays cost nothing.
  - But the video itself is uneven even when nothing else happens. With nativeTexture (the app's current settings), 36% of the frame intervals are 3 vsyncs (25 ms), in a repeating 2-3-1-vsync pattern, with or without HCPP.

## Setup

- **Device:** Xiaomi 2312DRA50G (Snapdragon 7s Gen 2), Android 16 / API 36, 1220×2712, 120 Hz. Portrait only.
  - The display drops to 60 Hz when only the platform-view video updates (most `native` plain windows).
- **Flutter:** 3.47.7 (engine `deb287481e`), profile builds for `android-arm64`. Impeller Vulkan in every build.
- **HCPP switch:** `flutter build apk -P benchHcpp=true` merges `android/app/src/hcpp/AndroidManifest.xml`, an application-level `io.flutter.embedding.android.EnableHcpp=true`.
  - FlutterLoader reads engine flags only from the application's meta-data.
  - Without the property, the meta-data is absent.
  - Each on/off pair differs only in `AndroidManifest.xml`: CRCs of all APK entries were compared, and `libapp.so` is byte-identical.
- **Configs:**
  - `native`: plugin defaults (Media3 PlayerView, SurfaceView, `initSurfaceAndroidView`).
  - `nativeTexture`: the app's settings (`androidTextureMode: true`, `feed()`, `lightweightInlineViews: true`).
  - `mkDefault`: media_kit's default texture.
- **Launches:** back to back with `install -r`, 04:02–04:16.

  | launch | configs | HCPP |
  |---|---|---|
  | A-off | native, mkDefault | off |
  | A-on | native, mkDefault | on |
  | B-off | nativeTexture | off |
  | B-on | nativeTexture | on |
  | A-on.2 | native, mkDefault (repeat) | on |
  | A-off.2 | native, mkDefault (repeat) | off |

  Battery went from 32.7 to 37.0 °C; thermal status stayed 0.
- **Clips:** 40 s stream-copied doubles of `h264_1440p60`, `vp9_1440p60` and `h264_2160p60` (`tool/loop_clips.sh`). The plain (9 s), overlay (5 s) and animated (6 s) windows all end before EOF.
- **Animated window:** the same as before. The video moves between full screen and a 30% corner mini-player, once per second. It now runs for every config.

## Was HCPP really active?

Yes, in every `on` launch, and in no `off` launch.
- **Our app's logcat (`--pid`):**
  - The bench logs `HybridAndroidViewController.checkIfSupported() = true` (on) or `false` (off). That API returns the engine's `IsSurfaceControlEnabled()`: EnableHcpp, API ≥ 34, Impeller, Vulkan and external-semaphore support.
  - With it true, every legacy `create` is routed to HCPP (`PlatformViewsChannel.create`), including the plugin's `initSurfaceAndroidView`.
  - All builds log `Using the Impeller rendering backend (Vulkan).`
  - The engine's own "Using HCPP platform view rendering strategy." is `io.flutter.Log.i`, which is compiled out of profile engines.
- **SurfaceFlinger agrees:**
  - In `on` launches, the FlutterSurfaceView's BLAST layer gets 0 frames: Impeller presents through the SurfaceControl swapchain into an unnamed child layer. Every Flutter frame then arrives with a window (HWUI) frame: 5.5k–8.8k per launch.
  - In `off` launches, the FlutterSurfaceView layer gets ~5.6k frames, and the window draws only while HC shows a platform view.

## Method

- **Flutter:** FrameTiming per window, as before. Each window now also records its CLOCK_MONOTONIC bounds (`fromUs`/`toUs`).
- **Video and UI presentation:** `dumpsys SurfaceFlinger --latency` for our app's own layers (`tool/sf_latency.py`), not gfxinfo.
  - **Polling and filtering:**
    - A device-side loop lists the layers and greps for `dev.foxyz.media_kit_bench` on the device, before anything is printed.
    - It strips Android 16's `RequestedLayerState{…}` wrapper and keeps the window surface and BLAST layers.
    - It dumps each one every ~0.45 s (each dump holds the last 128 frames). The host merges the dumps by desired-present time.
  - **Layers:**
    - `native` video: the run's own SurfaceView BLAST layer.
    - UI: the FlutterSurfaceView or window layer, whichever presented more frames.
  - **Late frame ("janky"):** a present-to-present interval over 20.8 ms. That is a 60 fps frame held for 3+ vsyncs at 120 Hz, or 2 at 60 Hz, instead of 16.7 ms.
  - **Video frames:**
    - While a SurfaceView resizes, its BLAST layer also logs ~31/s (HC) or ~53/s (HCPP) extra entries off ExoPlayer's 16.667 ms release cadence.
    - Decoder frames are counted as chains of ≥ 5 entries spaced 1–4 source frames apart (±20 µs).
  - **Tail of each run:** the last 0.0–0.5 s of each animated window is lost for the video layer, because the layer is destroyed before the next dump. Video stats stop at the last captured frame (5.6–6.0 s measured).
  - **Texture configs:** the video has no layer of its own.
    - In the plain window, Flutter draws only when a video frame arrives (60 fps), so the UI layer's intervals are the video cadence.
    - In the overlay and animated windows, Flutter runs at 120 Hz, and the video cadence is not visible to SurfaceFlinger.
- **Composition diagnostic:** a separate HCPP launch (`diag-hcpp-*`), not used in the tables. It took full `dumpsys SurfaceFlinger` snapshots and kept only the display HAL's rows for our layers. Those dumps are heavy.

## Results: means per config × HCPP × window (3 clips; `native` and `mkDefault` twice per build)

| config | HCPP | window | runs | Flutter fps | raster p90 / p99 ms | frames >8.3 / >16.7 ms | video fps | video janky per window (range; per s) | UI presented fps | UI 3+ vsync gaps (range) |
|---|---|---|---|---|---|---|---|---|---|---|
| native | off | plain | 6 | 0.1 | 3.69 / 3.69 | 0 / 0.0 | 59.3 | 5.7 (2–8; 0.6/s) | 0.1 | 0.0 (0–0) |
| native | off | overlay | 6 | 70.8 | 3.71 / 6.27 | 1 / 0.0 | 59.8 | 3.7 (2–6; 0.7/s) | 64.9 | 43.0 (16–90) |
| native | off | animated | 6 | 79.7 | 2.25 / 3.75 | 0 / 0.0 | 60.0 | 2.5 (0–5; 0.4/s) | 64.1 | 61.0 (49–81) |
| native | on | plain | 6 | 0.1 | 2.38 / 2.38 | 0 / 0.0 | 59.2 | 10.3 (6–20; 1.1/s) | 0.1 | 0.0 (0–0) |
| native | on | overlay | 6 | 104.6 | 10.35 / 16.38 | 132 / 5.2 | 59.6 | 31.0 (22–36; 6.2/s) | 87.4 | 12.3 (7–21) |
| native | on | animated | 6 | 114.2 | 2.91 / 10.37 | 18 / 0.5 | 60.1 | 7.2 (3–10; 1.2/s) | 110.7 | 2.8 (0–8) |
| nativeTexture | off | plain | 3 | 60.0 | 5.14 / 7.45 | 2 / 0.0 | – | – | 60.0 | 195.0 (193–197) |
| nativeTexture | off | overlay | 3 | 119.6 | 4.55 / 6.42 | 1 / 0.0 | – | – | 119.4 | 0.0 (0–0) |
| nativeTexture | off | animated | 3 | 119.7 | 4.73 / 7.04 | 1 / 0.0 | – | – | 119.6 | 0.0 (0–0) |
| nativeTexture | on | plain | 3 | 60.0 | 4.08 / 7.07 | 1 / 0.0 | – | – | 59.4 | 182.7 (179–187) |
| nativeTexture | on | overlay | 3 | 119.4 | 3.73 / 5.48 | 1 / 0.0 | – | – | 113.8 | 1.0 (0–2) |
| nativeTexture | on | animated | 3 | 119.7 | 3.75 / 5.63 | 1 / 0.0 | – | – | 115.4 | 0.0 (0–0) |
| mkDefault | off | plain | 6 | 59.9 | 2.87 / 4.12 | 0 / 0.0 | – | – | 60.0 | 100.8 (97–103) |
| mkDefault | off | overlay | 6 | 119.3 | 2.73 / 4.64 | 0 / 0.0 | – | – | 119.0 | 0.7 (0–1) |
| mkDefault | off | animated | 6 | 117.7 | 2.96 / 5.02 | 1 / 0.0 | – | – | 117.7 | 1.8 (0–4) |
| mkDefault | on | plain | 6 | 59.9 | 2.23 / 4.58 | 0 / 0.0 | – | – | 59.8 | 20.0 (12–24) |
| mkDefault | on | overlay | 6 | 119.3 | 2.49 / 4.25 | 0 / 0.0 | – | – | 115.7 | 0.5 (0–1) |
| mkDefault | on | animated | 6 | 116.9 | 2.30 / 3.92 | 0 / 0.0 | – | – | 113.7 | 3.8 (1–7) |

Reading the table:
- **Texture configs, plain window:** the "UI 3+ vsync gaps" are the video's own late frames.
  - nativeTexture: 36% of intervals are 3 vsyncs and 74% are not the ideal 2 (pattern 2-3-1-2-3-1).
  - mkDefault: 19% / 39% without HCPP, and 4% / 8% with it.
- **`native`, plain window:** Flutter is idle (one frame), so its raster numbers are a single frame.
- **Display rate:**
  - The display stays at 120 Hz in every overlay and animated window, and in every texture-config window.
  - In `native` plain windows it ran at 60 Hz for ~80% of the time, in both builds.
  - The one `native` plain window that stayed at 120 Hz (A-on.2, h264_2160p60) had the most late frames: 20.

Per-clip tables come from `tool/hcpp_report.py` without `--summary` (see "Files").

## What HCPP changes for the platform view

- **Movement (animated window):**
  - Flutter: 80 → 114 fps. Presented UI: 64 → 111 fps. 3+ vsync gaps: 61 → 3 per window.
  - Raster p99: 3.8 → 10.4 ms, with 18 frames over 8.3 ms per window.
  - Video: 60 fps in both. Late frames: 2.5 → 7.2 per window, and short (1-vsync) intervals 5 → 10.
- **Controls over the video (overlay window):**
  - Flutter: 71 → 105 fps, but raster p90/p99 goes from 3.7/6.3 to 10.4/16.4 ms, and presented UI only from 65 to 87 fps.
  - Video late frames: 3.7 → 31 per 5 s.
    - The video alternates between on time (~6 ms after its desired present) and one vsync late (~14 ms).
    - The video layer stayed on an HWC overlay plane (Device/Device, YUV UBWC) in every overlay snapshot, so GPU composition is not the cause.
  - Correlated, HCPP builds only, in our app's logcat:
    - HWUI `RenderInspector: QueueBuffer time out` (7–12 ms) on our window: 78–90 per A launch, ~83% of them inside the native overlay windows.
    - `SurfaceComposerClient: Could not call release buffer callback, buffer not found`: 650–746 per A launch.
    - HC builds log 0 of both.
  - The engine re-sends crop and alpha for the SurfaceView on every Flutter frame (`PlatformViewsController2.maybeApplyClipToSurfaceView`). This is a plausible cause, but it was not proven.
- **Video alone (plain window):** same fps; late frames 5.7 → 10.3 per 9 s. The display was at 60 Hz most of the time in both builds.
- **Composition (diagnostic):** the video sits on an HWC overlay plane in the plain and overlay windows. During the animation, 2 of 4 snapshots fell back to GPU composition (Device requested, Client used).

## Versus texture mode

- **Movement and overlays:** texture wins.
  - nativeTexture runs 119.6–119.7 fps with ~0 gaps in the overlay and animated windows, raster p90 ~4.7 ms. mkDefault: 117.7–119.3 fps.
  - Platform view with HCPP: 105 fps (overlay, 87 presented) and 114 fps (animated, 111 presented).
- **Video cadence at rest:** the platform view wins by far. Video frames with 3+ vsyncs:
  - platform view: 0.6/s (HC), 1.1/s (HCPP);
  - nativeTexture: 21.7/s (HC build), 20.3/s (HCPP build);
  - mkDefault: 11.2/s (HC build), 2.2/s (HCPP build).

  With texture mode, the decoder's frames reach Flutter through an ImageReader, which ignores their release timestamps. That probably explains nativeTexture's fixed 2-3-1 pattern, but it was not verified.
- **HCPP is app-wide.** It also changes texture rendering:
  - presented UI drops slightly: nativeTexture 119.4/119.6 → 113.8/115.4 fps (overlay/animated), mkDefault 119.0/117.7 → 115.7/113.7;
  - mkDefault's resting cadence gets much better: 19% → 4% of intervals with 3+ vsyncs. nativeTexture's barely changes (36% → 34%).

## Visual concerns

None of these could be judged without looking at the screen. Each needs an eye check.

1. **Rounded or path clips on the video under HCPP.**
   - For a SurfaceView, HCPP applies only each clip path's bounding rect (`setCrop`) and the opacity (`setAlpha`); see `PlatformViewsController2.maybeApplyClipToSurfaceView`.
   - The plugin's fullscreen-swipe `ClipRRect` (`_rounded()`) would then show square video corners.
   - The bench uses no clip. This comes from reading the engine source, not from a measurement.
2. **The mini-player under HCPP.**
   - While the video moves, the SurfaceView gets ~53 extra layer updates per second. Its layer sometimes falls back to GPU composition.
   - Check whether the video lags behind or overshoots its Flutter-drawn position, or shows stretched frames while it resizes.
3. **The semi-transparent controls bar over the video under HCPP.** Everything above a platform view is drawn into one overlay surface. Check the blending, and look for flicker or a black box.
4. **The overlay-window judder under HCPP.** About 6 late video frames per second while controls animate. Check whether it is visible on a smooth pan.
5. **nativeTexture's 2-3-1 cadence at rest.** Visible as uneven motion on the testsrc2 moving bar. mkDefault without HCPP shows it to a lesser degree.
6. **Black frames.**
   - The data shows none: the video layer presented ≥ 58 fps in every window.
   - With HCPP, the display HAL composites the video layer (alpha 255) in every phase, so it is on screen and not hidden.
   - The content itself (black, or wrong z-order) is not visible to SurfaceFlinger.

## Logcat (our PID only)

- No `Fatal signal`/SIGABRT/SIGSEGV/FATAL EXCEPTION lines in any launch.
- HCPP-only lines: see "What HCPP changes" above.
- In both builds: Qualcomm gralloc format probes at start, and `BufferQueueProducer … cancelBuffer: slot N is not owned` at codec release.

## Not done / caveats

- **Not tested:**
  - `native` with `lightweightInlineViews: true` (bare SurfaceView; this is what the app would use) under HCPP;
  - a static (non-animating) controls overlay;
  - landscape.
- **Measurement artefact:** the video layer misses the last 0.0–0.5 s of every animated window, which was destroyed before the next dump.
- **SurfaceFlinger load:** polling `--latency` costs SurfaceFlinger a little in every launch alike.
- **Diagnostic runs:** the `diag-hcpp` launch ran full SurfaceFlinger dumps and is excluded from the tables.
  - An HC diagnostic launch lost its adb reverse tunnel to a wireless-adb hiccup and produced nothing.
  - Earlier, one launch was not used: its sampler could not match Android 16's layer names.
- **Tooling changed after the launches:** the sampler's pidof miss tolerance and `run_launch.py`'s exit check were hardened. Both only affect failure handling.

## Files

- `A-off.jsonl` … `B-on.jsonl`: bench results, version 4. Windows carry `fromUs`/`toUs`, and `hello.hcppActive` is the runtime check.
- `*-sf.txt.xz`: SurfaceFlinger `--latency` samples of the bench package's own layers only (`tool/sf_latency.py`).
- `*-logcat.txt.xz`: `logcat --pid` of the bench app, filtered to engine, HCPP, codec, error and crash lines. The VM-service URL line is dropped.
- `diag-hcpp-hwc-layers.txt`, `diag-hcpp.jsonl`, `diag-hcpp-sf.txt.xz`: the composition diagnostic (`tool/hwc_layers.py`).
- To regenerate:
  - tables: `tool/hcpp_report.py off=A-off on=A-on 'on#2=A-on.2' 'off#2=A-off.2' off=B-off on=B-on [--summary]`, run in this directory;
  - launches: `tool/run_launch.py <apk> <prefix> <clips> --sf`;
  - builds: `flutter build apk --profile --target-platform android-arm64 [-P benchHcpp=true] --dart-define=BENCH_CLIPS=…`.
