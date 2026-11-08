# Fork state

The single place to resume from. Update it when something lands or a decision changes.
Last updated: 2026-11-09, at integration 75c5011a.

## Where things are

- Repo: github.com/Foxyz1302/media-kit (origin). Branch `integration` is the fork's main line; lane branches merge into it.
- Tags apps pin:
  - `v1.5.0-starsync.1` = 42435425 (core lifecycle)
  - `v1.5.0-starsync.2` = 8726f7d1 (+ ANGLE licenses)
  - `v1.5.0-starsync.3` = 75c5011a (+ async mpv calls, Android and desktop fixes)
- Users:
  - Starsync (desktop Linux/Windows) pins `.3`.
  - leafbooru (Android) pins `.3` on its sheet-sketch branch, `63e806eb` on main.
- Plan docs (older, partly superseded by this file): `plan` branch `docs/rewrite/` (DECISIONS.md, issues-triage.md, architecture-audit.md, predidit-and-binaries.md). Core lane notes: `docs/rewrite/core-lane-progress.md` (this branch).
- Apps must take EVERY media_kit package from the fork: git url + ref (tag) + path, with dependency_overrides for all `media_kit_libs_*`. The lock must show no `source: hosted` media_kit package.

## What's in integration

- **Upstream harvest:** 14 upstream PRs + #1464 + #1440 (Linux non-blocking render); fork fixes from other forks (S/W stride/size/rgba, Windows update-callback clear #1472).
- **Core** (media_kit/lib/src/player/native):
  - per-player lock with bounded waits;
  - safe, idempotent dispose (handle re-checked before every native call, late events dropped);
  - a guardian isolate (#1348);
  - prompt destroy on a worker isolate that joins COM's MTA on Windows;
  - the event-loop deadlock fixed (property listeners and hooks no longer awaited);
  - no libmpv call waits for mpv's core on the UI isolate (async API; hook_add in a worker);
  - #1420 flag width.
- **Android:**
  - surface attached before decoders (on_preloaded);
  - zero-copy `hwdec=mediacodec` first;
  - render at view size;
  - start-burst fix (no surface resize mid-open);
  - opt-in `VideoController.maxHardwareDecoders` (a playing player takes a paused one's decoder);
  - opt-in `PlayerConfiguration.positionUpdateInterval`;
  - dispose order (#1289; vid/vo/wid dropped first);
  - first-frame signal on playback-restart (#1379);
  - quiet dispose during create.
- **Linux:**
  - teardown lock and deferred texture-name delete (SEGV and VRAM-leak fixes);
  - render at widget size (`renderAtWidgetSize` bool?, default on for Linux, off for Windows);
  - BLOCK_FOR_TARGET_TIME=0 + `video-timing-offset=0.02`.
- **Windows:**
  - freeKC libmpv 20261021-1;
  - `PlayerConfiguration.tlsVerify` (null = `tls-verify=no` on Windows);
  - ANGLE/SwiftShader/Vulkan/SDK licenses shipped as `angle-licenses.txt`;
  - publish-under-lock, the normalizeURI fix (#1422), teardown ordering.

## Decisions (settled; reopen only with new evidence)

- Apple platforms are out of scope.
- HCPP stays OFF. It costs ~7 fps app-wide (a per-frame raster→main-thread hop). Retest when flutter#192083 lands. Landscape raster cost is the device/Flutter path, not the texture (a still image costs the same).
- No CA bundle: Windows defaults to `tls-verify=no`, matching the old libmpv.
- No own Flutter engine fork: too heavy on this machine.
- No C bridge / build hooks for now. The Dart-only lifecycle was enough; a NativeFinalizer isn't safe from Dart.
- The D3D11 renderer and the Linux render thread are low priority: Windows real use is crash-free and Linux raster is <2 ms after no-block.
- #1417 (late-keyframe start) is mpv behaviour; it would need an mpv patch.
- Frame pacing: mpv already queues evenly; the leftover jitter is Flutter's.

## Verified in real use

- Starsync Linux (3 machines, 3 evenings) and Windows (4 machines, 1 evening): zero crashes, no stuck players. Old rate: ~1 Windows crash per 5–6 opens.
- leafbooru on Android: the formerly erroring post plays, and 4K60 is fine.
- Phone bench (SM7435, 120 Hz): churn ok, no leak; 4K60 first frame 0.26–0.42 s.

## Open (not started unless asked)

- "No render context set": opening before the Linux render context exists means black forever. Needs a native signal + `video-reload`. Starsync works around it by awaiting `controller.platform`.
- The Windows `dxva2-egl Failed to create EGL surface` log noise (harmless).
- Rare edges: the guardian vs an in-flight screenshot; a tiny exit window that needs a C bridge; the Windows VideoOutputManager create/dispose race (Dart covers it; a native ordered queue would be clean).
- Android hardware-decoder hand-over is weak with 3 pages plus pending disposes (use maxHardwareDecoders).
- CI: the Linux headless leak-cycles test fails on integration too; one network flake; a 1-in-24 shuffle-order flake on Windows tests. Linux CI runners need audio-device observation off (libpipewire hang).

## How to work here

- Heavy steps (build, test, analyze, pub get) run one at a time: `flock <job tmp>/heavy.lock -c '…'`. The PC is short on RAM.
- Phone sessions run one script each under the phone lock. Privacy: no screenshots, only `logcat --pid` of our app, no settings changes, never unlock.
- Test players are always muted (volume 0).
- The NVIDIA GTX 1080 corrupts under multi-video load: at most 1–2 players on Linux GUI runs.
- Builds go in one persistent checkout (incremental ~30 s vs 10+ min fresh). The Gradle build cache is on.
- GitHub Actions on the fork is enabled (no schedules). Dispatch frugally; Windows is only testable there.
