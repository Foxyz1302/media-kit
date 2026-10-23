# Android playback fixes, 2026-10-23

**Setup**
- Device and 1080p/1440p clips: same as `../2026-10-22-baseline`. Portrait only.
- New clips:
  - 4K, from `tool/encode_clips_4k.sh`: H.264 4K60 46 Mbps, H.264 4K30 30 Mbps, HEVC 4K60 25 Mbps (hvc1), VP9 4K60 25 Mbps (webm), AV1 4K30 ~12 Mbps.
  - Check clips, from `tool/encode_check_clips.sh` and `tool/live_hls.sh`.
- Code: branch `android-playback` = integration `9c0eef46` + bench + the fixes below. Flutter profile builds.
- Configs:
  - `mkDefault`: the new default (`vo=gpu`, `hwdec=mediacodec,mediacodec-copy`).
  - `mkCopy`: `hwdec=mediacodec-copy`, which is what the old `auto-safe` default resolved to.
  - `native`: better_native_video_player 1.7.5 with its default hybrid composition.
  - `nativeTexture`: the app's real settings (`androidTextureMode: true`, `feed()` buffering, `lightweightInlineViews: true`). It needs its own app launch because the plugin config is global.
- Link: clips are served from the PC over `adb reverse`. A full GET of the 115 MB H.264 4K60 clip took 3.0 s, i.e. **37.9 MB/s (303 Mbit/s)**. That is 6.6× the heaviest clip's 46 Mbit/s, so no result below is link-limited.

## What was wrong

Mechanism, confirmed with an instrumented build (`trace/mech-before-fix1*`):
1. Flutter's SurfaceProducer starts at 1×1. When the first video params arrive, media_kit calls `setSize`, and the next `getSurface()` creates a new Surface. ~470 ms after the first params, the Resize callback runs `widListener`.
2. `widListener` set `vo=null`, then `android-surface-size` and `wid`, then `vo=gpu`, and then called `seek(player.state.position)`.
3. Re-creating the VO already makes mpv queue its own refresh seek to the current position (`refresh seek to 0.083333`, then a stream-level seek back to byte 11377).
4. media_kit's second seek landed while that one was in flight. The demuxer served it from its cache and appended the re-read packets after its read-ahead. 5–7 s in, mpv logged `Invalid video timestamp 6.38 -> 0.000000` and playback replayed from ~0. This caused the baseline's low and negative rates.

Before the fix, the trace runs played at 0.29 (copy) and 0.44 (zero-copy). After it: 1.0/1.0, one mpv refresh seek and no Dart seek (`trace/after-fix1.jsonl`).

The seek target was never stale; the second seek is the bug. PR #1453 says the VO re-init queues a seek to 0, which the trace contradicts. Its EOF SIGABRT trigger is this same Dart seek, which no longer exists. Its `open()` rewrite (`loadfile replace`) was not taken.

## Fixes (one commit each)

| commit | file(s) | cause | change |
|---|---|---|---|
| `02bb5cb4` | `media_kit_video/…/android_video_controller/real.dart` | the extra seek after the VO re-init (above) | dropped the seek; kept the `vo=null` guard for `wid=0` (SIGSEGV) |
| `6447e0c1` | same + `platform_video_controller.dart` doc | `auto-safe` → `mediacodec-copy` copies every frame to RAM and uploads it again | default `mediacodec,mediacodec-copy`: zero-copy first, copy as fallback; AV1 still falls back to software |
| `97579444` | `media_kit/…/native/player/real.dart` | no writable cache dir on Android, so every open logged `Failed to create file cache` | `cache-on-disk=no` on Android only |
| `0051666c` | same | the Android libmpv has no OSC, so setting `osc` logs an error per player | set `osc` only when `option-info/osc/name` exists |
| `935f1cec` | same + `platform_player.dart` + `test/…/audio_client_name_test.dart` | mpv tells the audio server it is "mpv", so per-app capture (e.g. Discord) can't attribute the sound | `audio-client-name` defaults to the executable name on desktop; `PlayerConfiguration.audioClientName` overrides; empty = mpv's default. Headless test: 3/3 |
| `6e7dadba` | `android_video_controller/real.dart` | `mediacodec_embed` silently fails on software-decoded codecs (AV1: one frame, then nothing) | stays opt-in; warns when embed ends up with `hwdec-current` empty or `no` |
| `e7224766` | `media_kit_video/android/…/VideoOutput.kt` | every resize made a new JNI global ref for the Surface and never freed the old one | delete the previous ref after a 5 s delay (time for mpv to detach); clear `wid` on cleanup |
| `0f3ac06f` | `android_video_controller/real.dart` | a 4K surface on a 1220 px-wide screen renders 3.1× the pixels the display can show | scale uniformly to fit the display (even sizes): 1440p and 4K → 2168×1220; 1080p unchanged |
| `b7ac8fd6` | `media_kit/…/native/player/real.dart` | #1215: mpv rejects `seek` before the file is loaded, so a seek right after `open()` was lost | keep it pending until `MPV_EVENT_FILE_LOADED`; cleared by `stop()` and load errors |
| `69667575` | same + `android_video_controller/real.dart` | the Surface was sized and attached only after the first decoded frame, so every start re-created the VO (and refresh-seeked) | an `on_preloaded` hook reads the demuxer's video size, sizes the Surface, waits ≤ 2 s for it, and attaches it with synchronous property sets before the decoders exist. The old path stays as the fallback (e.g. no codec parameters at preload). `create()` is never gated on a real Surface (#1445) |

Result: one `setSurfaceSize` per media_kit run (20 of 20 runs), and no VO re-init or refresh seek at start (`trace/late-keyframe-attach-before-decode.jsonl`: GPU context at 142 ms, `h264_mediacodec` opened on the surface at 147–150 ms).

## Functional regression checks (`checks.jsonl`, default VideoController, local streams)

| check | issue | result | evidence |
|---|---|---|---|
| `Media(start: 5 min)` | #1215 | **pass** | position 300.0 → 307.2 s over 8 s, `mediacodec` |
| seek right after `open()` | #1215 | **pass** | 120.0 → 126.9 s (before `b7ac8fd6`: `error running command seek`, see `trace/checks-before-seek-fix.jsonl`) |
| first keyframe 8 s in (MP4, audio from 0) | #1417 | **fail** | starts at 8.03 s, every time (it used to be a race) |
| keyframe 9.4 s in, no SPS/PPS before it (TS) | #1417 variant | fail (expected) | 9.69 s: no frame can be decoded before the first parameter sets; MediaCodec can't open without them → software |
| live HLS (sliding window, no ENDLIST) | #1445 | **pass** | advanced 14.5 s in 15 s, `mediacodec` |
| HLS VOD, `start: 60 s` | #997 | **pass** | loaded in 278 ms; 60.0 → 69.4 s |
| EOF → loop → open next | #1453 | **pass** | wrapped at 4 s; next item 0 → 2.7 s on `mediacodec`; no crash lines |
| EOF → completed → open next | #1453 | **pass** | completed; next item 0 → 2.6 s on `mediacodec` |

The app's own logcat (`--pid`) had 0 `Fatal signal`/SIGABRT/SIGSEGV lines across the checks and all 40 performance runs.

## Before / after (portrait, plain/overlay window rates; baseline = stock upstream main)

| clip | before: default rate, invalid-ts | after: default | after: copy | native | nativeTexture |
|---|---|---|---|---|---|
| h264_1080p60 | 1.0/**-1.19**, 1 | 1.0/0.99, 0 | 1.01/0.99 | 0.95/1.02 | 0.95/1.0 |
| h264_1440p60 | 0.66/0.99, 1 | 1.0/1.0, 0 | 1.0/1.0 | 0.95/1.01 | 0.95/1.0 |
| hevc_1440p60 | 0.41/1.0, 1 | 1.0/1.0, 0 | 1.0/1.0 | 0.95/1.01 | 0.95/1.0 |
| vp9_1440p60 | 0.15/1.0, 1 | 1.0/1.0, 0 | 0.99/1.0 | 0.95/1.01 | 0.95/1.0 |
| av1_1440p60 | 0.53/1.0, 1 | 1.0/1.0, 0 | 1.0/1.0 | 0.95/1.01 | 1.0/1.0 |

| clip | time to motion, default: before → after (ms) | overlay Flutter fps: native before / native after / nativeTexture / media_kit after |
|---|---|---|
| h264_1080p60 | 1345 → 553 | 77.0 / 58.4 / 119.6 / 118.6 |
| h264_1440p60 | 904 → 477 | 65.0 / 80.3 / 119.8 / 119.6 |
| hevc_1440p60 | 791 → 550 | 83.8 / 80.4 / 119.8 / 119.4 |
| vp9_1440p60 | 926 → 576 | 58.6 / 82.7 / 119.6 / 119.3 |
| av1_1440p60 | 578 → 491 | 56.8 / 55.3 / 119.8 / 119.6 |

Success criteria, all met for the 20 media_kit runs:
- plain-window rate ≥ 0.99;
- no negative-rate window;
- 0 `Invalid video timestamp`;
- 0 `Failed to create file cache`;
- 0 osc errors;
- AV1 plays on the default (software dav1d, 1440p60 and 4K30).

The native player's 0.95 comes from its 500 ms position updates, not from playback. For the same reason, its motion times include up to 500 ms of that granularity.

## 1080p / 1440p detail

| clip | config | decoder | TTFF ms | motion ms | rate P/O | mpv drops P/O | raster p99 P/O ms | Flutter fps P/O |
|---|---|---|---|---|---|---|---|---|
| h264_1080p60 | mkDefault | mediacodec qti.avc | 329 | 553 | 1.0/0.99 | 11/3 | 5.29/6.61 | 58.73/118.6 |
| h264_1080p60 | mkCopy | mediacodec-copy qti.avc | 376 | 599 | 1.01/0.99 | 9/6 | 4.69/6.12 | 58.99/118.11 |
| h264_1080p60 | nativeTexture | qti.avc | 436 | 947 | 0.95/1.0 | – | 7.22/6.45 | 60.11/119.57 |
| h264_1080p60 | native | qti.avc | 387 | 899 | 0.95/1.02 | – | 8.99/6.44 | 0.11/58.38 |
| h264_1440p60 | mkDefault | mediacodec qti.avc | 248 | 477 | 1.0/1.0 | 1/0 | 5.15/6.01 | 59.89/119.56 |
| h264_1440p60 | mkCopy | mediacodec-copy qti.avc | 335 | 585 | 1.0/1.0 | 1/2 | 5.35/5.89 | 59.97/119.74 |
| h264_1440p60 | nativeTexture | qti.avc | 289 | 801 | 0.95/1.0 | – | 7.35/6.7 | 59.88/119.78 |
| h264_1440p60 | native | qti.avc | 297 | 807 | 0.95/1.01 | – | 6.41/5.97 | 0.11/80.28 |
| hevc_1440p60 | mkDefault | mediacodec qti.hevc | 340 | 550 | 1.0/1.0 | 0/0 | 5.08/6.53 | 59.99/119.36 |
| hevc_1440p60 | mkCopy | mediacodec-copy qti.hevc | 314 | 578 | 1.0/1.0 | 0/1 | 4.83/5.83 | 60.1/119.51 |
| hevc_1440p60 | nativeTexture | qti.hevc | 307 | 821 | 0.95/1.0 | – | 8.18/6.75 | 59.99/119.75 |
| hevc_1440p60 | native | qti.hevc | 253 | 763 | 0.95/1.01 | – | 6.57/6.01 | 0.11/80.38 |
| vp9_1440p60 | mkDefault | mediacodec qti.vp9 | 356 | 576 | 1.0/1.0 | 0/0 | 4.8/5.99 | 59.88/119.32 |
| vp9_1440p60 | mkCopy | mediacodec-copy qti.vp9 | 310 | 554 | 0.99/1.0 | 1/0 | 5.48/6.34 | 59.62/119.55 |
| vp9_1440p60 | nativeTexture | qti.vp9 | 339 | 849 | 0.95/1.0 | – | 7.28/6.97 | 60.1/119.57 |
| vp9_1440p60 | native | qti.vp9 | 389 | 899 | 0.95/1.01 | – | 5.67/6.79 | 0.11/82.74 |
| av1_1440p60 | mkDefault | software (dav1d) | 285 | 491 | 1.0/1.0 | 0/0 | 3.67/4.9 | 59.99/119.56 |
| av1_1440p60 | mkCopy | software (dav1d) | 270 | 476 | 1.0/1.0 | 1/0 | 3.51/4.57 | 59.86/119.37 |
| av1_1440p60 | nativeTexture | sw:av1-dav1d,sw:av1 | 344 | 861 | 1.0/1.0 | – | 6.36/6.36 | 60.1/119.77 |
| av1_1440p60 | native | sw:av1-dav1d,sw:av1 | 499 | 1017 | 0.95/1.01 | – | 4.78/6.47 | 0.11/55.31 |

The first run of the launch (h264_1080p60 on mkDefault) carries warm-up drops.

## 4K (2160p)

| clip | config | decoder | TTFF ms | motion ms | rate P/O | mpv drops P/O | raster p99 P/O ms | Flutter fps P/O |
|---|---|---|---|---|---|---|---|---|
| h264_2160p60 | mkDefault | mediacodec qti.avc | 396 | 655 | 1.0/1.0 | 7/4 | 4.37/5.67 | 59.13/119.58 |
| h264_2160p60 | mkCopy | mediacodec-copy qti.avc | 564 | 816 | 1.0/1.0 | 30/17 | 6.98/7.76 | 56.48/113.04 |
| h264_2160p60 | nativeTexture | qti.avc | 403 | 913 | 0.95/1.0 | – | 8.39/7.04 | 60.22/119.78 |
| h264_2160p60 | native | qti.avc | 1007 | 1518 | 0.95/1.01 | – | 8.79/8.09 | 0.11/74.98 |
| h264_2160p30 | mkDefault | mediacodec qti.avc | 337 | 559 | 1.0/1.0 | 0/0 | 5.43/6.38 | 29.99/119.73 |
| h264_2160p30 | mkCopy | mediacodec-copy qti.avc | 489 | 718 | 1.0/0.99 | 1/1 | 5.02/7.32 | 29.89/118.59 |
| h264_2160p30 | nativeTexture | qti.avc | 537 | 1054 | 0.95/1.0 | – | 7.66/7.46 | 30.11/119.57 |
| h264_2160p30 | native | qti.avc | 430 | 940 | 0.95/1.01 | – | 7.19/7.54 | 0.11/66.91 |
| hevc_2160p60 | mkDefault | mediacodec qti.hevc | 289 | 502 | 1.0/1.0 | 0/0 | 5.03/6.02 | 59.99/119.67 |
| hevc_2160p60 | mkCopy | mediacodec-copy qti.hevc | 448 | 758 | 1.0/1.0 | 14/1 | 10.27/9.37 | 58.13/113.48 |
| hevc_2160p60 | nativeTexture | qti.hevc | 514 | 1025 | 0.95/1.0 | – | 7.91/7.46 | 59.99/119.57 |
| hevc_2160p60 | native | qti.hevc | 680 | 1192 | 0.95/1.02 | – | 4.49/6.55 | 0.11/68.98 |
| vp9_2160p60 | mkDefault | mediacodec qti.vp9 | 321 | 533 | 1.0/1.0 | 0/0 | 3.9/4.18 | 59.99/119.57 |
| vp9_2160p60 | mkCopy | mediacodec-copy qti.vp9 | 369 | 653 | 1.0/0.99 | 25/7 | 8.03/8.32 | 57.07/115.5 |
| vp9_2160p60 | nativeTexture | qti.vp9 | 411 | 924 | 1.0/0.9 | – | 8.95/8.07 | 59.99/119.76 |
| vp9_2160p60 | native | qti.vp9 | 900 | 1414 | 0.95/1.02 | – | 4.96/6.05 | 0.11/64.51 |
| av1_2160p30 | mkDefault | software (dav1d) | 344 | 551 | 1.0/1.0 | 0/0 | 3.85/5.47 | 30.0/119.55 |
| av1_2160p30 | mkCopy | software (dav1d) | 389 | 595 | 1.0/1.0 | 1/0 | 4.05/5.03 | 29.89/119.16 |
| av1_2160p30 | nativeTexture | sw:av1-dav1d,sw:av1 | 331 | 845 | 0.95/1.0 | – | 6.6/6.56 | 30.11/119.76 |
| av1_2160p30 | native | sw:av1-dav1d,sw:av1 | 393 | 913 | 0.95/1.02 | – | 2.09/7.12 | 0.11/60.56 |

- At 4K60 the zero-copy default is where `hwdec` matters. Copy mode drops 30/17 frames on H.264 (default: 7/4), 25/7 on VP9 (0/0) and 14/1 on HEVC (0/0).
- With copy mode, the overlay window falls to 113–115 fps; zero-copy holds ~119.6.

## Animated mini-player window

The video moves between full screen and a 30% corner mini-player, once per second, for 6 s.
- The 20 s clips end ~5.5 s into the window, so rate, jumps and stalls count only the part before the clip ends ("s measured").
- The native positions come in 500 ms steps, so its "stall" is that granularity.
- "Surface changes" counts `setSurfaceSize` calls during the window.

| clip | config | Flutter fps | raster p90/p99 ms | frames >8.3 / >16.7 ms | mpv drops | rate | backward jumps | longest stall ms | s measured | surface changes |
|---|---|---|---|---|---|---|---|---|---|---|
| h264_1440p60 | mkDefault | 116.6 | 4.6/6.28 | 0/0 | 1 | 1.0 | 0 | 0 | 5.6 | 0 |
| h264_1440p60 | nativeTexture | 119.11 | 4.96/7.13 | 2/0 | – | 1.01 | 0 | 409 | 5.5 | – |
| vp9_1440p60 | mkDefault | 117.87 | 4.72/6.77 | 3/0 | 0 | 1.0 | 0 | 0 | 5.5 | 0 |
| vp9_1440p60 | nativeTexture | 119.51 | 5.14/7.41 | 3/0 | – | 1.01 | 0 | 408 | 5.5 | – |
| hevc_1440p60 | mkDefault | 117.28 | 4.64/6.16 | 1/0 | 1 | 1.0 | 0 | 0 | 5.6 | 0 |
| h264_2160p60 | mkDefault | 116.77 | 4.66/6.9 | 3/0 | 5 | 1.0 | 0 | 0 | 5.6 | 0 |
| h264_2160p60 | nativeTexture | 119.04 | 5.39/7.73 | 3/0 | – | 1.0 | 0 | 410 | 5.5 | – |
| vp9_2160p60 | mkDefault | 118.73 | 2.58/5.9 | 1/0 | 0 | 1.0 | 0 | 0 | 5.6 | 0 |
| vp9_2160p60 | nativeTexture | 119.24 | 5.53/8.45 | 8/0 | – | 1.0 | 0 | 424 | 5.5 | – |

- Both players keep up with the moving video: no frame above 16.7 ms, and media_kit's `time-pos` stays monotonic.
- media_kit's Surface does **not** follow the widget size: it stays at the video size capped to the display, and Flutter scales the texture.

## Still wrong / not done

1. **#1417: a file that starts with non-keyframes starts at its first keyframe**, audio included (8.0 s here).
   - Cause: MediaCodec drops the frames before the first IDR, and mpv's `initial-audio-sync=yes` aligns audio to the first video frame.
   - This is deterministic now; it used to be a race.
   - `initial-audio-sync=no` would start audio at 0, but it changes start and seek behavior for every file. That makes it an app-level option, not a default.
2. **No codec parameters before the first keyframe (TS cut mid-GOP):** h264_mediacodec can't open, so mpv decodes in software and doesn't retry hardware once SPS/PPS show up. Harmless at 720p, expensive at 4K.
3. **Zero-copy log noise:** `vo/gpu/aimagereader: Waiting for frame timed out!` plus `acquireLatestImage failed: -30001`. It appears at EOF/loop and on the late-keyframe start, where mpv waits 100 ms for a frame MediaCodec never delivered. Playback continues; not investigated further.
4. **Mid-stream resolution switch** (`switch_720to1080.ts`, `trace/after-fix1.jsonl`): ~1 s hold and one `Invalid video timestamp`, from two VO reconfigs. Not fixed.
5. **Surface sizing:** `setSize` is not exposed on Android. The triage's "one surface at min(video, display) + `keepaspect=no`" was not done, because a surface fixed at the first video size would cap ABR upgrades. The display cap (`0f3ac06f`) does the useful part.
6. #1289 is left for later.
7. The public Apple bipbop HLS master did not load over the phone's own connection within 40 s, so #997 was checked on a local HLS VOD. Desktop mpv starts bipbop at 60.06 s.

## Files

- `results-a-default-copy-native.jsonl`: launch A (mkDefault, mkCopy, native; link test; mkDefault animated window).
- `results-b-native-texture.jsonl`: launch B (nativeTexture, with its animated window).
- `checks.jsonl`: the functional checks.
- `codecs.log.gz`: codec component and `setSurfaceSize` lines from the bench app's own PID only.
- `trace/`:
  - `mech-before-fix1*`: instrumented mechanism trace.
  - `after-fix1.jsonl`: runs after the seek fix.
  - `late-keyframe-attach-before-decode.jsonl`: attach-before-decode on the 8 s-keyframe clip.
  - `checks-before-seek-fix.jsonl`: an earlier checks run, showing the #1215 seek failure.
- Tables: `tool/report.py results-*.jsonl --codecs <(zcat codecs.log.gz) --baseline ../2026-10-22-baseline/results-v2.jsonl`.
