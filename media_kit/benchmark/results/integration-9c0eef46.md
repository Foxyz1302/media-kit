# Event-path baseline: integration 9c0eef46 (run A)

Raw data: `integration-9c0eef46.json` (two JIT runs, two AOT runs).

## Setup

- Linux x64, 12 CPUs. Dart 3.13.5, system libmpv 0.41.0, FFmpeg n9.0.2.
- `bench_720p60.mp4` from `tool/gen_test_media.sh`: H.264/AAC 1280x720 at 60 fps, 4 s, looped with `loop-file=inf`.
- Headless player: `vo=null`, `ao=null`, `hwdec=no`. It runs in a spawned isolate, so it uses the NativeCallable transport, as release builds do.
- Windows of 20 s. JIT CPU numbers come from the VM profiler at a 500 µs period with native frames (`--profile-vm`). Allocation counts come from per-class allocation tracing, in a separate 250 ms (throughput) or 3 s (realtime) window.
- Every property event also passes through the benchmark's own `observeEvent` counter, which costs one closure and one future per event. That overhead is the same in every run.

## Rates

| | throughput (`untimed=yes`, `aid=no`) | realtime |
|---|---|---|
| events/s, JIT | 2572, 2655 | 62.25, 62.25 |
| events/s, AOT | 2835, 2626 | 62.20, 62.25 |
| position events/s | 2546, 2629 | 59.65 |
| seek-bar repaints/s (1000 px bar over the 4 s clip) | same as position events | 59.65 |
| time-label changes/s | 52 | 1.0 |

Throughput mode is limited by decoding, not by Dart: the player isolate is busy 12–13% of the time. Its events/s therefore track mpv's decode rate. The comparable numbers are the per-event costs below.

In realtime mode, `stream.position` fires on every video frame (59.65/s), while the time label changes once per second (E-5).

## CPU per event (JIT, throughput)

| | run 1 | run 2 |
|---|---|---|
| Dart isolate busy | 13.1% | 12.4% |
| all Dart-side work, µs/event | 51.1 | 46.5 |
| `InitializerNativeCallable._callback` drain loop, inclusive | 30.6 | 27.0 |
| `NativePlayer._handler`, inclusive | 6.2 | 5.6 |
| `mpv_wait_event`, inclusive | 0.3 | 0.6 |

The two inclusive rows overlap: the drain loop runs the first synchronous part of `_handler`.

Exclusive samples by kind: native 72–73%, Dart 16%, stubs 8–9%. About 63% of all samples are in libc functions that `dladdr` cannot name. `mpv_wait_event` accounts for less than 1 µs, so the time is not lock contention with mpv's core thread. Unverified hypothesis: it is malloc/free and memmove in the VM's per-wakeup message delivery and allocation paths. `perf` with libc debug symbols would settle it.

Realtime CPU per event cannot be resolved by sampling. At 0.1–0.3% busy, 20 s yields only 47–113 samples, and the two runs give 19 and 45 µs/event. Use the throughput figure.

## Allocations per event

| class | throughput | realtime |
|---|---|---|
| `Pointer` (dart:ffi) | 70.1, 69.7 | 70.0 |
| `_OneByteString` | 23.2, 23.1 | 23.6 |
| `_Closure` | 11.9, 12.2 | 15.6 |
| `_Future` | 5.2, 5.3 | 6.8 |
| `_Double` | 2.0 | 5.8 |
| `Duration` | 1.0 | 0.96 |
| `PlayerState` | 1.0 | 0.97 |
| `_TwoByteString` | 0 | 0 |

The audit predicted the strings (E-1, about 21 property-name decodes per event) and the one `PlayerState` per event (E-2). Not in the audit: about 70 boxed FFI `Pointer` objects per event, from `.ref`/`.cast()` chains on the event structs.

Total allocated bytes are not reported. The VM's accumulated allocation counters miss short-lived objects that are allocated inline: they report 0 `PlayerState` per event.

## P2-E1 targets, checked in run C against run B

- time-pos events: 0 String allocations (today about 23), and at most 1 small object (today about 115 traced objects);
- CPU per event at least 3× lower: at most about 16 µs, from 46–51 µs today.
