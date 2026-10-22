# Windows: a native D3D11 renderer on mpv's render API (design)

- Status: design for later, nothing implemented. DECISIONS.md ("Binaries") schedules it after the fork has its own Windows
  libmpv build.
- Base: `windows-render` (integration @ `9c0eef46` plus this lane's commits). Line numbers refer to that tree.
- Sources: mpv `4255130de4` "libmpv: add D3D11 render API backend" (2026-10-15); Predidit's d19286c1 "mailbox triple
  buffering" and 21aacaf9 "no stall pipeline" (read-only clone at `83b7ca63`); integration's #1468 (3b96c91f); Flutter's
  `shell/platform/windows/external_texture_d3d.cc` (flutter/flutter, `stable`).
- Effort: **S** ≤ 1 agent-day, **M** = 2–5 days, **L** = 1–3 weeks.

---

## 1. Why

Today's path (`media_kit_video/windows/`), on ANGLE over D3D11:

- **Producer.** A single `ThreadPool(1)` worker, shared by every output (`video_output_manager.h:78`), runs `Render()`
  (`video_output.cc:211`). `ANGLESurfaceManager::Draw` takes `mutex_`, makes the context current, lets mpv draw and ends
  in `glFinish()` (`angle_surface_manager.cc:63-70, 98`). The CPU waits for all of mpv's GPU work, Anime4K included.
- **Consumer.** Flutter's raster thread calls the `GpuSurfaceTexture` callback (`video_output.cc:393`), which calls
  `Read()`: the same `mutex_`, then `CopyResource` from the internal into the external texture and a `Flush`
  (`angle_surface_manager.cc:72-80`). The raster thread therefore waits up to one whole mpv render, then pays a
  full-frame copy.
- **Decoding.** Zero-copy d3d11va goes through mpv's `d3d11-egl` interop (EGLStream into ANGLE). It only works with the
  freeKC build (mpv 1d156861).
  - On the windows-latest runner (WARP, ANGLE GLES 3.0) the interop gets ANGLE's D3D11 device and stops at `Failed to
    create hwdevice_ctx`, because WARP has no video decoder (render probe in run 39872489883). mpv 0.41.0 gives up
    earlier, silently, at the extension check.
  - Even with the interop, mpv's renderer runs through ANGLE's GL-to-D3D11 translation.
- **Device.** The D3D11 device uses the default adapter (`angle_surface_manager.cc:187-195`), not Flutter's.
- **Size.** ANGLE costs about 21 MB per app (`libEGL`, `libGLESv2`, SwiftShader, the Vulkan loader, `d3dcompiler_47`).

What a D3D11 renderer on mpv's own render API changes:

- mpv draws with its `ra_d3d11` straight into a texture of ours, on a device of ours. There is no GL, no EGL, no ANGLE
  and no `glFinish`.
- d3d11va decodes on that same device and mpv samples the decoder's texture directly. That is zero-copy, including the
  4:4:4 and high-bit-depth formats of 0d68a842, which only the native D3D11 path uses.
- Flutter's raster thread no longer waits for the producer and copies nothing: it gets the shared handle of the newest
  finished frame.
- Every output can render on its own thread: there is no ANGLE global state to serialise.
- Windows arm64 can get hardware rendering. Both arm64 builds have no OpenGL (`-Dgl=disabled`), so today they render
  in software. That needs an arm64 build with mpv's `d3d11` feature.

## 2. mpv's API (4255130d, client API 2.6)

Header `include/mpv/render_d3d11.h`; backend `video/out/d3d11/libmpv_d3d11.c` (101 lines), registered ahead of GL in
`video/out/gpu/libmpv_gpu.c`.

```c
#define MPV_RENDER_API_TYPE_D3D11 "d3d11"
MPV_RENDER_PARAM_D3D11_INIT_PARAMS = 21,  // mpv_render_context_create(): mpv_d3d11_init_params*
MPV_RENDER_PARAM_D3D11_FBO = 22,          // mpv_render_context_render(): mpv_d3d11_fbo*

typedef struct mpv_d3d11_init_params { void *device; } mpv_d3d11_init_params;  // ID3D11Device*
typedef struct mpv_d3d11_fbo { void *tex; } mpv_d3d11_fbo;                     // ID3D11Texture2D*
```

**Device.**
- The embedder passes its `ID3D11Device` once, at context creation. mpv adds a reference, so the caller may release its
  own after `mpv_render_context_create` returns.
- `init()` needs mpv's SPIR-V compiler (`spirv_compiler_init`) and `ra_d3d11_create`. A build without the `d3d11`
  feature, which needs `spirv-cross` and `shaderc`, simply lacks the backend.
- mpv loads the inbox `d3dcompiler_47.dll` from System32 first (`ra_d3d11.c:2212-2241`), so the app no longer needs to
  bundle it.

**Target.**
- One `ID3D11Texture2D` per `mpv_render_context_render` call, created on the same device.
- It needs `D3D11_BIND_RENDER_TARGET` and `D3D11_USAGE_DEFAULT`. It must not be multisampled, an array or mipmapped.
- Supported formats: `B8G8R8A8_UNORM`, `R8G8B8A8_UNORM`, `R10G10B10A2_UNORM`, `R16G16B16A16_FLOAT`; no sRGB formats.
- mpv wraps the texture for that call only: `wrap_fbo` → `ra_d3d11_wrap_tex`, and `done_frame` → `ra_d3d11_flush` plus
  `ra_tex_free`. It keeps no reference.

**Synchronisation.**
- All of mpv's work is submitted to the immediate context before `mpv_render_context_render` returns.
- Later work on the same device needs no synchronisation. Another device that reads the texture must be synchronised
  by the embedder; the header suggests a keyed mutex around the render call.

**State and threads.**
- mpv uses the device's immediate context and does not restore its state. The stages mpv doesn't set must be at their
  `ClearState()` defaults.
- Any thread may call `mpv_render_*`, but no other thread may use the immediate context meanwhile.
- The general rules of `render.h` still apply:
  - render calls are never concurrent on one context;
  - the render thread must never wait for a client API call that needs the core (`render.h:74-83`). mpv breaks such a
    deadlock with a timeout and logs `mpv_render_context_render() not being called or stuck.`

**Hardware decoding.**
- d3d11va decodes on the embedder's device from mpv's decoder thread. mpv turns on `ID3D10Multithread` protection for
  it (`hwdec_d3d11va.c:128-137`) and needs D3D11.1 (`:118-125`).
- A device created with `D3D11_CREATE_DEVICE_SINGLETHREADED` gets copy-back only.
- mpv's own device needs no `D3D11_CREATE_DEVICE_VIDEO_SUPPORT` (`d3d11_helpers.c:477`).

**What the API does not do.**
- It reports no device loss. The embedder asks the device itself (`GetDeviceRemovedReason`).
- It has no swap chain, no presentation and no frame queue. The mailbox below is entirely ours.

**Build pins.**
- 4255130d already contains 1d156861 (the d3d11egl fix), 40c998a1 (the hwdevice reference release), 0d68a842, and the
  ra_d3d11 preparations b1b03bd347 and 0b3d2ab525. The binaries report's suggestion to find a later commit for 40c998a1
  is unnecessary: it is 18 commits before 4255130d.
- The pin should still be at or after 4dfee616 (2026-10-16, 15 commits after 4255130d), the WASAPI fix for #1449.
- No published binary contains 4255130d: Carapacik is on 0.41.0, Predidit and freeKC on `0b7ed670`, 130 commits
  earlier.

## 3. Reference: Predidit's mailbox (d19286c1, 21aacaf9)

Predidit's pipeline predates 4255130d and runs on a private render API, `MPV_RENDER_API_TYPE_DXGI` (patch
`mpv-0001-dxd11-render-api.patch` in Predidit/libmpv-win32-video-cmake). mpv renders into `GetBuffer(0)` of an
`IDXGISwapChain` the plugin passes in. The plugin's swap chain is a facade, `MailboxSwapChain`
(`media_kit_video/windows/mailbox_swap_chain.{h,cc}` at 21aacaf9):

- **Four slots.** Each slot is a `B8G8R8A8_UNORM` texture with `RENDER_TARGET | SHADER_RESOURCE`, `MISC_SHARED` (a legacy
  shared handle, which is what `kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle` takes), an `ID3D11Fence` and its last
  value.
- **State.** One `std::atomic<uint32_t>` packs the roles:
  - bits 1:0 `free`, bits 3:2 `completed`, bits 5:4 `pending_or_extra`, bit 6 `has_pending`;
  - plus a producer-private `write_slot_`;
  - initial value 57 = `0b0_11_10_01`;
  - the four roles always name four different slots.
- **`ProducerCommit()`**, on the producer thread after the render:
  1. `ID3D11DeviceContext4::Signal` on the slot just drawn.
  2. If a frame is pending and its fence has completed (`GetCompletedValue`, which doesn't block), one CAS promotes it to
     `completed` and the old `completed` becomes `extra`. The promoted index is then stored in `latest_completed_slot_`
     with release order.
  3. A CAS publishes the drawn slot as `pending`. The old `free` becomes the next `write_slot_`, and `pending_or_extra`
     becomes `free`.
- **`ConsumerAcquire()`** is a single acquire load of `latest_completed_slot_`. It returns that slot's shared handle,
  with no CAS, no fence poll, no flush, no mutex and no keyed mutex.
- **Device.** Created on Flutter's adapter (`registrar_->GetView()->GetGraphicsAdapter()`) with `BGRA_SUPPORT`, and GPU
  thread priority 5.
- **The plugin's side.**
  - `Render()` is `mpv_render_context_render`, then `mpv_render_context_report_swap`, then `ProducerCommit()`.
  - The texture callback sets `desc->handle = ConsumerAcquire()`.

**What carries over to 4255130d unchanged:** the slots, the fences, the state machine, the adapter choice and the call
sequence. The facade goes away. Instead of mpv calling `GetBuffer(0)`, every render passes the write slot:

```cpp
mpv_d3d11_fbo fbo{slots_[write_slot_].texture.Get()};
int block = 0;
mpv_render_param params[]{
    {MPV_RENDER_PARAM_D3D11_FBO, &fbo},
    {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block},
    {MPV_RENDER_PARAM_INVALID, nullptr},
};
mpv_render_context_render(render_context_, params);
mpv_render_context_report_swap(render_context_);
mailbox_->Commit();
```

**Gaps in Predidit's version.** These come from the binaries report (§2.2) and from reading 21aacaf9:

1. No device-lost handling; nothing calls `GetDeviceRemovedReason`.
2. `Resize` sets `texture_id_` from `RegisterTexture` before the texture is in `textures_` (Predidit `video_output.cc`,
   `Resize`). The callback's `textures_.at(texture_id_)` can then throw inside the engine. That is the crash #1468 fixed.
3. `MailboxSwapChain::Resize` releases all four slots, on the producer thread, while Flutter may still have one of
   their handles bound.
4. It needs `ID3D11Device5` (`CreateFence`) and `ID3D11DeviceContext4` (`Signal`), Windows 10 1703 or later. Without
   them it falls back to software rendering.
5. Cross-device reuse is guarded only by rotation. The old `completed` slot becomes `free` at the promotion and is
   drawn into again from the next commit on, so about one or two video frames after Flutter last acquired it. Nothing
   fences Flutter's sampling on its own device, and Flutter's share-handle consumer takes no keyed mutex. This is
   inherent to the design.

## 4. Design

### 4.1 Objects and threads

- `D3D11Output` per `VideoOutput` replaces `ANGLESurfaceManager`. It owns:
  - an `ID3D11Device` and its immediate context;
  - the current `TextureMailbox` and the mailboxes retired by resizes;
  - the producer thread.
- **One producer thread per output**, not the shared `ThreadPool(1)` (triage #29). With a device per output, nothing is
  shared any more, and a 24 fps player no longer queues behind a 60 fps one.
- **Producer jobs.** The producer thread is the only thread that uses the immediate context. It runs the render and
  `Commit`, mailbox creation on resize, and `mpv_render_context_free` at teardown.
- **mpv's decoder thread** also uses the device, through `ID3D10Multithread`, which mpv enables.
- **Flutter's raster thread never touches our device.** It opens the shared handle on Flutter's own device.
- **The update callback** keeps today's role (`NotifyRender`). It wakes the producer through a coalescing flag and a
  condition variable, instead of posting two tasks per frame (`CheckAndResize` and `Render`, `video_output.cc:203-209`).

### 4.2 Device and adapter

- `D3D11CreateDevice` on `registrar_->GetView()->GetGraphicsAdapter()`. A texture shared through a legacy handle
  generally opens only on the adapter that created it, which matters on multi-GPU laptops.
  - Hardware driver, feature levels 11_1 to 10_0.
  - Flags `D3D11_CREATE_DEVICE_BGRA_SUPPORT`, never `SINGLETHREADED`.
  - Debug builds can add the debug layer when the SDK layers are installed.
- `mpv_render_context_create` gets `{MPV_RENDER_PARAM_API_TYPE, "d3d11"}` and `{MPV_RENDER_PARAM_D3D11_INIT_PARAMS,
  &init}`. On failure (an mpv without the backend, or no D3D11.1), fall back exactly as today: OpenGL through ANGLE
  while it is still shipped, then `MPV_RENDER_API_TYPE_SW`.

### 4.3 Mailbox

- Port 21aacaf9's four-slot state machine as it is; it is small and its invariants are documented in its header.
  - Slot textures: `B8G8R8A8_UNORM`, `RENDER_TARGET | SHADER_RESOURCE`, `MISC_SHARED`.
  - Formats: Flutter imports only `RGBA` pbuffers, and the descriptor says `kFlutterDesktopPixelFormatBGRA8888`, so 10-bit
    and float targets bring nothing to Flutter's compositor.
- **Fences.** `ID3D11Fence` per slot when `ID3D11Device5` and `ID3D11DeviceContext4` exist. Otherwise use a
  `D3D11_QUERY_EVENT` per slot, ended after the render and polled in `Commit` with
  `GetData(..., D3D11_ASYNC_GETDATA_DONOTFLUSH)`. That is as non-blocking as the fence, works from feature level 10_0,
  and removes Predidit's fall back to software rendering.
- **Reuse window.**
  - Keep four slots.
  - Track the slot Flutter has bound. Each descriptor sets `release_context` to the slot index, and the engine calls
    `release_callback` after it binds a handle (`external_texture_d3d.cc`, `CreateOrUpdateTexture`). That slot stays out
    of `free` until Flutter binds another one.
  - This removes overwriting while bound. It does not remove the case where Flutter's GPU is still sampling a slot it
    has already switched away from; that needs a fence Flutter doesn't expose.
  - Measure before adding slots.

### 4.4 Consumer

- The `GpuSurfaceTexture` callback takes `textures_mutex_` only to look up the descriptor (today's lock, kept for the
  publication order in §4.5). It sets `handle = mailbox->Acquire()`, sets `release_context`, and returns.
- **Cost that moves.** Flutter's `ExternalTextureD3d` keeps one EGL surface and compares handles. A new handle means
  `eglDestroySurface` plus `CreateSurfaceFromHandle(EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE)`, which opens the shared
  resource in ANGLE.
  - A mailbox hands out a new handle for every new video frame, so every new frame pays one open of a shared resource
    on the raster thread. It is CPU work in the driver, not a GPU stall and not a copy.
  - Today's path pays a mutex wait, a full-frame `CopyResource` and a `Flush` instead.
  - Measure both with the benchmark lane's raster-time p90 at 1440p and 4K, with and without Anime4K.
- `kFlutterDesktopGpuSurfaceTypeD3d11Texture2D` (`EGL_D3D_TEXTURE_ANGLE`) would avoid the open, but it needs a texture
  on Flutter's own device. The plugin API gives only the adapter, and mpv would share Flutter's immediate context.
  Not usable.

### 4.5 Texture registration and resize

Keep #1468's publication order (`video_output.cc:333-340, 403-415`):
- `texture_id_` goes to 0 under `textures_mutex_` before the old texture is unregistered;
- the new ID is published only after the descriptor is in `textures_`, under the same lock;
- Dart hears about it only after that.

Then change what a resize does:
- **Keep the texture ID.** The engine re-imports whenever the handle changes and takes the size from the descriptor. A
  resize can therefore create a new mailbox at the new size and return its handles from the next callback on.
  - There is no unregister or register, and no blank frame. This is the "new texture ID per resize" problem (P2-W2).
  - Dart still gets `VideoOutput.Resize` with the same ID and the new rect.
- **Retire the old mailbox; don't release it.** It is freed once Flutter has bound a handle of the new mailbox (the
  `release_callback` of §4.3), plus a frame of margin. Predidit releases all four slots at once while one is bound
  (gap 3).
- **Take the size from Dart (protocol v2 `SetSize`).** Don't call `mpv_get_property("video-out-params")` on the
  producer, which is a client API call on the render thread (§2).
  - Today's `CheckAndResize` → `GetVideoWidth/Height` does exactly that (`video_output.cc:302-327, 465-507`).
  - The render probe logged `mpv_render_context_render() not being called or stuck.` once per player at the first
    video reconfig. That call is a likely cause; it was not isolated.

### 4.6 Device lost (keep #1468's semantics)

**Detection, on the producer:**
- before every render, `device->GetDeviceRemovedReason() != S_OK` (as `ANGLESurfaceManager::IsDeviceLost`,
  `angle_surface_manager.cc:82-86`, checked in `Render`, `video_output.cc:216-222`);
- after a failed `mpv_render_context_render`;
- when creating a mailbox fails with `DXGI_ERROR_DEVICE_REMOVED` or `DXGI_ERROR_DEVICE_RESET`. Today that is the
  exception from `SetSize` that `Resize` catches (`video_output.cc:373-382`).

**Reaction.** The same as today's `ReportDeviceLost` (`video_output.cc:453-463`):
- stop rendering;
- create no textures and mailboxes;
- tell Dart once. Today that is texture ID 0; with protocol v2 it is `VideoOutput.DeviceLost {handle}`.

The destructor must still not wait for an unregister callback when no texture is registered (`video_output.cc:186-191`).

**Recovery.** Two levels:
1. **What #1468 does now (keep first).** The app disposes of the player and opens the media in a new one, which gets
   a new device. Nothing in mpv has to survive the loss.
2. **In place (later, M).** The producer:
   - clears the update callback;
   - frees the render context;
   - creates a new device, mailbox and render context;
   - reports a new texture.

   Freeing the render context during playback makes mpv kill the VO and deselect the video track
   (`player/client.c`, `do_kill` → `error_on_track`). Someone has to select `vid` again afterwards: Dart, or native
   code on a thread that is not the render thread. That needs a protocol v2 message.

### 4.7 Teardown

This is the order of P1-W1. D3D11 makes it simpler: there is no current context to hold.

1. `mpv_render_context_set_update_callback(ctx, nullptr, nullptr)`. It takes mpv's update lock, so no callback runs
   after it returns.
2. Stop the producer thread after its current render.
3. Unregister the texture and wait for its callback, or skip the wait when none is registered (#1468).
4. `mpv_render_context_free` on the producer thread, or any thread once the producer has stopped. Wait for it: mpv
   aborts with "mpv_render_context_free() not called" if the core goes first (`player/client.c:195-200`), which this
   lane's f56b20e9 and 2da7b5e9 guard against today.
5. Release the mailboxes and the device.
6. Answer `VideoOutputManager.Dispose` (2da7b5e9).

## 5. Build and packaging prerequisites

- **An own Windows libmpv** (binaries report §3.6, "Windows, next").
  - mpv at or after 4dfee616, with `-Dd3d11=enabled`, which pulls in `spirv-cross` and `shaderc`.
  - FFmpeg with d3d11va.
  - Start from freeKC/libmpv-builds. Its x64 DLL already has `d3d11 shaderc spirv-cross` in mpv's feature list, but
    it pins `0b7ed670`.
  - arm64 with `-Dd3d11=enabled` if spirv-cross and shaderc build there.
- **Choose the backend at run time.** Check `mpv_client_api_version() >= MPV_MAKE_VERSION(2, 6)` and that
  `mpv_render_context_create` with `"d3d11"` succeeds. Otherwise use the ANGLE path, until ANGLE is dropped.
- **Headers.** Vendor `render_d3d11.h` (ISC, as the other mpv headers) until every shipped archive has it.
- **Drop ANGLE** from `media_kit_libs_windows_video` once the D3D11 path is the default and the fallback is software.
  That saves about 21 MB; `d3dcompiler_47.dll` comes from System32.

## 6. Order of work

| Step | What | Effort | Depends on |
|---|---|---|---|
| 1 | Own libmpv build ≥ 4dfee616 with `d3d11`; publish under the fork with sources | M | – |
| 2 | `D3D11Output`: device on Flutter's adapter, render into a single shared texture, consumer copy-free | M | 1 |
| 3 | Port the mailbox (21aacaf9) with the event-query fallback and the bound-slot tracking | M | 2 |
| 4 | Resize with a stable texture ID and retired mailboxes | S–M | 3, protocol v2 `SetSize` |
| 5 | Device-lost detection and reporting (#1468 contract) | S | 2 |
| 6 | Per-output producer threads; `BLOCK_FOR_TARGET_TIME=0`; `report_swap` | S | 2 |
| 7 | Teardown order of §4.7 | S | 2 |
| 8 | Drop ANGLE from the libs package | S | 2–7 on by default |
| 9 | In-place device-lost recovery | M | 5, protocol v2 |

Step 2 can start with two textures in ping-pong and an event query each, published only once the query has completed.
That already removes `glFinish`, the mutex shared with the raster thread, and the copy. Step 3 replaces the ping-pong
with the four-slot mailbox, which is the throughput step.

## 7. Risks and open questions

- **Per-frame shared-resource opens** on Flutter's raster thread (§4.4). Unmeasured. If they cost more than today's
  copy at 4K, the fix belongs in the engine: `ExternalTextureD3d` would keep one EGL surface per handle instead of one in
  all, an upstream change. Within the plugin, the only alternative is copying into one long-lived handle again.
- **Reuse window** (§3, gap 5). Expect tearing, not crashes, when Flutter's GPU runs more than about two video frames
  late. Test by stalling the raster thread.
- **Driver variance.** `ID3D10Multithread` protection serialises mpv's decoder against our renders. Measure frame
  pacing with two players on one GPU.
- **mpv state leakage.** mpv leaves the immediate context dirty. Our only other immediate-context calls are `Signal`
  and `End(query)`, which state doesn't affect.
- **The API is new** (2026-10-15) and only Predidit's patch has seen real use. Pin a commit and keep the ANGLE path as
  the fallback until it has shipped in an app.

## 8. Verification

- **CI (windows-latest, WARP).** An integration test like this lane's render probe:
  - render a local file;
  - check that the texture ID is non-zero and the rect is the video size;
  - read `current-vo`;
  - dispose ×3 and time it.

  WARP has no video decoder, so CI shows the interop and the render path, not zero-copy decoding.
- **Real machine:**
  - `hwdec-current` reports `d3d11va`;
  - CPU % and package power on 4K HEVC against the ANGLE path;
  - raster-time p90 at 1440p and 4K with Anime4K;
  - a device lost through `dxcap -forcetdr` or a driver restart, which must report ID 0 or `DeviceLost` once and then
    allow a new player;
  - resize while playing: no blank frame, no `textures_.at` throw;
  - multi-GPU laptop: the device on Flutter's adapter (log the adapter LUIDs).
