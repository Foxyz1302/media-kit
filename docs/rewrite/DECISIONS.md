# Rewrite decisions

These are the owner's decisions as of 2026-10-23. The research behind them is in the three reports in this folder.

## Scope
Android, Linux and Windows only. No Apple work: macOS and iOS CI failures don't block anything.

## Public API
Keep `Player`, `Media`, `Playlist`, `VideoController`, `Video` and the controls source-compatible, so apps can switch to the fork through a git dependency.

## Lifecycle crash (#1348/#1443)
Port Predidit's design:
- a C wakeup that posts through `Dart_PostCObject`;
- a `NativeFinalizer` and a worker thread for `mpv_terminate_destroy`;
- an idempotent, ordered `dispose`.

The C bridge is built through a build hook. Routing release builds through the isolate initializer is not the fix.

## NativePlayer core
- Split `real.dart` into `part` files first, as a pure move with no behaviour change.
- Then:
  - dispatch property events on `reply_userdata`;
  - emit only the fields that changed;
  - add a UI-rate position stream (the exact position stays queryable);
  - give each player its own lock;
  - fix the FFI bugs: flag width and the screenshot argv.

## Defaults vs presets
Correctness and security fixes become the new defaults:
- network reconnect and timeouts, so a hiccup no longer ends a video as "completed";
- load errors delivered as events;
- `hr-seek-framedrop`;
- TLS verification on, with a bundled CA on Android and schannel or a CA bundle on Windows.

Trade-offs become opt-in presets: buffer sizes (feed/stream), desktop render quality.

## Feed and animation support
- a resize policy (no re-render on every frame while animating);
- keep one player and texture alive while the video moves between widget subtrees (mini-player);
- a player pool for feeds;
- posters and preload for neighbouring items;
- controls that are cheap to composite.

Assume the apps mostly use custom overlays, so the core must be cheap for them.

- A process-wide hardware-decoder budget, `maxHardwareDecoders`, enforced across all players:
  - over the budget, players fall back to CPU decoding (`hwdec=no`) or stay paused on a poster; the app chooses which;
  - the visible/active player gets priority.
  - Why: mobile chips have small per-codec limits (the user's phone: 6 for VP9), and on the user's desktop (legacy NVIDIA 580 driver on Wayland) several simultaneous hardware decodes corrupt the screen, in any app.

## Binaries
- **Windows:** use freeKC's 20261021-1 builds (LGPLv3; contains the d3d11va zero-copy fix). Later, rewrite the renderer on mpv's D3D11 render API, which needs the fork's own build and drops ANGLE.
- **Android:** keep the current binary for development. Before the first mobile release, ship our own build from Predidit's scripts, pinned to stable mpv/FFmpeg, with libplacebo built for OpenGL only. Fallback: Predidit v1.3.1 (minSdk 26).
- **Linux:** system libmpv until AppImage/Flatpak packaging. Never ship the GPL Linux bundle.

## Other
- Raising the minimum SDK for native assets is fine; Flutter 3.44+ is already required.
- Vulkan/gpu-next is not pursued: Android zero-copy decoding is GL-only, and Anime4K works over OpenGL.
- Benchmarks and baselines live in `media_kit_bench/results/` on the `bench` branch.
