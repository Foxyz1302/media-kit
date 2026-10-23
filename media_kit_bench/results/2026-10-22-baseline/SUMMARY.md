# Android baseline, 2026-10-22

**Setup**
- Device: Xiaomi 2312DRA50G, Snapdragon 7s Gen 2 (SM7435), Android 16, 120 Hz.
- Code: stock upstream main `c533e446`, built on Flutter 3.47.7 in profile mode.
- Clips: 20 s synthetic clips from `tool/encode_clips.sh`.
  - 1440p60: H.264 25 Mbps, HEVC 15 Mbps, VP9 15 Mbps, AV1 ~8.6 Mbps.
  - 1080p60: H.264.
- Native baseline: better_native_video_player 1.7.5 (hybrid composition).
- v2 ran portrait and landscape. A playback window starts only once playback moves; each run has a 9 s plain window plus a 5 s animated-overlay window.

**Findings**
- **Decoding is not the bottleneck.** H.264, HEVC and VP9 always ran on the qti hardware decoders. mpv ran at 60 fps with 0 decoder drops and single-digit frame drops. AV1 has no hardware decoder; software dav1d kept up on this light clip.
- **media_kit's Android startup is broken.** The playback rate in the plain window was 0.05–0.79 (native: 0.95). Several overlay windows had *negative* rates, meaning `time-pos` jumped back up to ~9 s. 28 of 30 runs logged mpv's `Invalid video timestamp X -> 0.000000`.
  - Suspect: `android_video_controller/real.dart`'s `widListener`. On a surface resize it sets `vo=null`, re-creates `vo`, then seeks to the possibly stale `player.state.position`.
- **Disk cache fails.** `cache-on-disk=yes` has no writable directory on Android, so every run logs `lavf: Failed to create file cache`.
- **`hwdec=auto-safe` resolves to `mediacodec-copy`.** Zero-copy `mediacodec` is as good or slightly better (fewer drops).
- **`mediacodec_embed` doesn't help.** It does not reduce Flutter raster cost (landscape overlay p99 up to 15.6 ms), and it fails on AV1: one frame, then no playback.
- **Landscape fullscreen with an animated overlay is expensive.** Raster p90 rises from 4–5 ms (portrait) to 12–15 ms, which misses the 8.3 ms budget at 120 Hz (~96–104 fps) but stays under 16.7 ms.
- **The native player under hybrid composition:** Flutter sits idle (~0.1 fps) until widgets go on top. Then it drops to 57–84 fps despite raster p99 ≤ 8.7 ms, so the limit is hybrid composition's frame syncing. That matches the user's "smooth until I touch anything".

**Files**
- `results-v2.jsonl`, `results-v1-portrait.jsonl`: raw per-run records.
- `codecs-v2.log.gz`: codec component lines from the bench app's own PID only.
- Analyze with `tool/analyze.py`.
