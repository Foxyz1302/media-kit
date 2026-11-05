# Core lane (`core-rewrite`): progress

State on 2026-11-05: the lifecycle items for Starsync 1.5.0 are done, with no C bridge and no build hook. The branch is `origin/integration` @ `32dc16af` plus the commits below.

## Done
| Commit | What |
|---|---|
| `ed5c1519` | A lock per player (the static `NativePlayer.lock` stays, deprecated and unused). Bounded waits: 20 s for the player's own init, 10 s once per player for an attached VideoController, after which calls go on without it. A failed `_create` completes init with an error, so calls throw and dispose still works. |
| `93d1f4e8` | Safe dispose. Every native call reads the handle right before the call (`_live`), never across an `await`. `dispose` is idempotent and ordered: earlier calls finish (bounded), stop, release callbacks (render context freed there), streams closed, events stopped with the handler in flight drained, pending requests completed, destroy. Escape hatches throw from the moment dispose is called. If something may still use the handle (VideoController still initializing, a release callback or handler still running, a screenshot/playlist `compute`), the destroy waits in the background. The guardian isolate (below). NativeReferenceHolder: main isolate only, isolate-based delivery only, the handle leaves it before it's destroyed. `PlatformPlayer.dispose` runs release callbacks before closing the streams. |
| `3965b5d1` | Destroy right after dispose, on a worker isolate, instead of 5 s later on the UI isolate. dispose completes once the handle is destroyed (bounded 10 s). |
| `f2229cde` | The event-loop deadlock. `observeProperty` listeners and mpv hooks run outside the loop (hooks call `mpv_hook_continue` when done). User observers get ids ≥ 2^40 and `MPV_FORMAT_STRING` (E-6, E-8). The fallback bitrate file read runs outside the loop. `observeEvent` listeners are still awaited, because they borrow the `mpv_event`. |
| `c6eec8cb` | A deferred destroy waits for the same event drain; a failed guardian spawn is retried. |

## Design: why no NativeFinalizer, and the guardian isolate
- **mpv aborts** if a handle is destroyed while a render context is alive. Verified in mpv 0.41 `player/client.c`: `mp_destroy_client` → (last strong client) `mp_destroy` → `mp_clients_destroy`, which prints "Broken API use: mpv_render_context_free() not called." and calls `abort()`. So the handle is destroyed only after the release callbacks, and never blindly while a desktop VideoController may hold one.
- **A NativeFinalizer can't be the safety net from Dart.** Its callback can only be a libmpv function. The VM runs it in VM state under `NoSafepointScope` (`Isolate::RunAndCleanupFinalizersOnShutdown`, `NativeFinalizer::RunCallback`). `mpv_terminate_destroy` blocks on mpv threads, and those threads call the wakeup `NativeCallable`, which allocates on the Dart heap (`FfiAsyncCallbackSend`). A pending safepoint then deadlocks the process. The finalizer also can't clear the wakeup callback first (that takes 3 arguments). Doing it safely needs the C bridge (Predidit's design).
- **The Dart-only replacement: a guardian isolate per owner isolate.**
  - It owns the wakeup `NativeCallable.listener` and forwards each wakeup to the owner. When the owner dies, the callable stays valid, so there's no "Callback invoked after it has been deleted" (#1348).
  - It gets `Isolate.addOnExitListener` of the owner. On exit, it clears the wakeup of each handle still alive and destroys it, or only sends `quit` if the handle may have a render context (marked when a VideoController attaches on desktop).
  - dispose hands a handle over with one `destroy` message, so a handle is destroyed exactly once whenever the owner dies. The guardian runs the destroy in `Isolate.run`.
  - Cost: one extra port hop per wakeup, not per event.
- **The isolate-based delivery** (debug main isolate, execmem-restricted) is unchanged in design. dispose waits for its helper to leave `mpv_wait_event`, then destroys in `Isolate.run`. Hot restart still goes through NativeReferenceHolder (`quit`, no destroy).

## Tests and measurements
- Headless: `dart test test/headless --concurrency=1` → 62 pass, 2 skipped (`stream-outage-is-an-error-not-completed` and `stream-http-error-stops-playing`, P1-C5/P1-N1, not this lane).
  - Untagged and passing: `isolate-kill-with-live-players-1348`, `leak-resources-released-after-dispose` (1 ms, was 5 s+), `lifecycle-double-dispose`, `lifecycle-player-not-blocked-by-another`, `lifecycle-unobserve-property-keeps-position`.
  - New: `lifecycle-stuck-video-controller-blocks-only-its-player`, `lifecycle-dispose-racing-calls`, `lifecycle-no-events-after-dispose`, `lifecycle-dispose-waits-for-event-in-flight`, `lifecycle-dispose-defers-destroy-for-stuck-listener`, `lifecycle-observe-property-listener-awaits-calls`, `lifecycle-hook-awaits-calls`. The last two fail on the code before `f2229cde`.
- Linux stress (`media_kit_test/lib/teardown_stress.dart`, 1 lane, muted, hwdec auto, h264/hevc/vp9/av1 clips; sampler in `tmp/core/stress/run.sh`):
  - Release (guardian path), 200 iterations: PASS, 0 errors, 274 s. RSS plateaued at about 650–690 MiB and dropped to 445 MiB at the end. Threads were 50–53 during the run and 22 at the end; FDs were 190–195 during the run and 98 at the end. mpv `core` threads: 1 most of the time, at most 3 for single samples (probably queryDecoders' temporary handle), 0 at the end.
  - Debug (isolate path), 100 iterations: PASS, 0 errors. At the end: threads 23, FDs 97, 0 cores, RSS 605 MiB (debug JIT).
- Windows: `ci.yml` dispatched on `core-rewrite`, see the run linked from the integration merge.

## Left
- Owner killed during an in-flight `screenshot`/`setShuffle` `compute`: the guardian may destroy the handle under it. The fix is the async `screenshot-raw` and async `playlist` get from the FFI item below.
- Release-mode app exit with a desktop VideoController: if the engine kills the isolate group before the guardian handles the owner's exit, the callable is deleted with the wakeup still set. This was pre-existing, and the window is now smaller. Only the C bridge closes it.
- Windows `VideoOutputManager.Create`/`Dispose` run on detached threads that race for one mutex. A `Dispose` that wins over a pending `Create` leaves an output (and a render context) for a handle that's being destroyed. Dart covers it only by waiting for the VideoController's init before the destroy. The native fix is one ordered queue (Windows lane).
- Not done from the old plan: P1-C0 split, `reply_userdata` dispatch for internal observers, UI-rate position, FFI fixes (flag width, argv size, async screenshot/playlist), CA bundle, `malloc_trim` proposal.
