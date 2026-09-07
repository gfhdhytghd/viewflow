# Sunshine implementation notes

Source inspected: `LizardByte/Sunshine` commit
`377e07ce4590fcdd179442043af1e6b84ddbe001` (2026-08-26). The checkout was
shallow and clean. This note records implementation patterns useful to
Viewflow; it is not a proposal to copy Sunshine source.

Sunshine declares `GPL-3.0-only` in `CMakeLists.txt:19` and
`pyproject.toml:10`. Unless a file has a different license, its source-code
expression and derivative implementations must be treated as GPL-covered.
Public API concepts and independently implemented ideas require a separate
analysis; the boundary guidance below is engineering guidance, not legal
advice.

## Decision matrix

| Area | Sunshine reference | What Viewflow may reuse | Recommendation |
| --- | --- | --- | --- |
| Wayland capture | `src/platform/linux/wlgrab.cpp`, `wayland.cpp` | Public Wayland, DMA-BUF, GBM, EGL, and DRM APIs through an independent implementation | Use the Hyprland plugin as the authoritative per-window producer. Treat wlr-screencopy as a whole-output compatibility path only. |
| Portal capture | `src/platform/linux/portalgrab.cpp`, `pipewire.cpp` | Portal DBus and PipeWire APIs through an independent implementation | Keep as a permission-friendly whole-monitor fallback. Do not assume that negotiation yields DMA-BUF. |
| DRM/KMS capture | `src/platform/linux/kmsgrab.cpp` | DRM/KMS and DMA-BUF APIs through an independent implementation | Useful for descriptor ownership and fallback design, but not as Viewflow's default per-window source. |
| VAAPI encode | `src/platform/linux/vaapi.cpp` | libva, DRM, EGL, and FFmpeg APIs through an independent implementation | Primary Linux Intel/AMD path. Describe it as GPU-resident with no CPU pixel copy, not as copy-free. |
| NVIDIA encode | `src/platform/linux/cuda.cpp`, FFmpeg NVENC descriptors in `src/video.cpp` | CUDA, EGL, OpenGL, and FFmpeg APIs through an independent implementation | Support a DMA-BUF -> GL -> CUDA bridge, while measuring the device-to-device copy. |
| Vulkan Video | `src/platform/linux/vulkan_encode.cpp` | Vulkan external-memory and FFmpeg APIs through an independent implementation | Experimental path only until driver, modifier, and codec coverage is proven. |
| System audio | `src/platform/linux/audio.cpp`, `src/audio.cpp` | PulseAudio/PipeWire and Opus APIs through an independent implementation | Reuse the sink-monitor concept, not Sunshine code. |
| Per-app audio | Not implemented by Sunshine | PulseAudio sink-input or native PipeWire node routing | Implement independently; do not use Sunshine's global default-sink switch. |
| Scheduling | `src/video.cpp`, `src/stream.cpp`, `src/thread_safe.h` | Latest-frame and monotonic-clock concepts | Adopt the policies, but choose Viewflow-specific queue sizes and count every eviction. |
| Executable reuse | Sunshine's GameStream server | Running an unmodified program as a separate process | Clear runtime/deployment boundary, but not by itself a copyright conclusion. GameStream also lacks Viewflow's per-window DMA-BUF, atlas, alpha-plane, and QUIC contracts. |

## Linux capture paths

The DMA-BUF variants of the three GPU-oriented Linux capture paths converge on
`egl::surface_descriptor_t` in `src/platform/linux/graphics.h:496-504`:

- width and height;
- DRM fourcc and modifier;
- up to four plane file descriptors;
- per-plane pitch and offset.

`egl::img_descriptor_t::reset()` closes the owned plane descriptors
(`graphics.h:603-635`). This explicit ownership model is worth reproducing:
every boundary must say whether it borrows, duplicates, or consumes each FD.
Sunshine turns the descriptor into EGL attributes in
`src/platform/linux/graphics.cpp:596-631`, creates an
`EGL_LINUX_DMA_BUF_EXT` image in `egl::import_source()` (`:640-667`), and binds
it to a GL texture. Portal/PipeWire also has a MemPtr fallback that delivers
pixels through `img_t::data` rather than a valid DMA-BUF descriptor
(`src/platform/linux/pipewire.cpp:927-932`).

### wlroots screencopy plus linux-dmabuf

The relevant frontend is `wl::wlr_t` in
`src/platform/linux/wlgrab.cpp:38`. Its flow is:

1. `wlr_t::init()` (`wlgrab.cpp:48-139`) connects to Wayland, discovers
   outputs, and records physical and logical geometry.
2. `interface_t::add_interface()`
   (`src/platform/linux/wayland.cpp:209-239`) binds
   `zwlr_screencopy_manager_v1`, `zwp_linux_dmabuf_v1`, and the output metadata
   interfaces.
3. `wlr_t::snapshot()` (`wlgrab.cpp:160-183`) calls
   `dmabuf_t::listen()` (`wayland.cpp:299-326`) to issue
   `capture_output` and dispatch until the frame reaches a terminal state.
4. After the compositor reports the format and modifier,
   `dmabuf_t::create_and_copy_dmabuf()` (`wayland.cpp:377-434`) allocates a GBM
   BO, exports its FD, creates a linux-dmabuf `wl_buffer`, and asks screencopy
   to write into it.
5. `dmabuf_t::ready()` (`wayland.cpp:495-521`) records the compositor
   timestamp. `wlr_vram_t::snapshot()` (`wlgrab.cpp:419-443`) transfers the
   plane-FD ownership into the encode image.

Despite the internal `WLR_EXPORT_DMABUF` naming and log text, this checkout
creates wlr-screencopy and linux-dmabuf objects, not an old
`zwlr_export_dmabuf_*` object. The distinction matters when probing compositor
support.

Limitations for Viewflow:

- This is output capture, not a protocol for selecting an arbitrary Wayland
  window. Viewflow still needs its Hyprland compositor plugin to identify a
  window family and export its color and alpha planes.
- `dmabuf_t::buffer_done()` (`wayland.cpp:437-459`) has no SHM fallback, so
  this path requires wlr-screencopy, linux-dmabuf, and xdg-output support; the
  last is also a hard check in `wlr_t::init()` (`wlgrab.cpp:68-75`).
- The wlr-screencopy protocol is a non-standard compositor extension
  historically associated with the wlroots ecosystem, and is deprecated in
  favor of newer standardized image-copy-capture protocols. It should be a
  compatibility backend, not Viewflow's long-term compositor contract.
- `wlr_ram_t::snapshot()` (`wlgrab.cpp:255-288`) imports the DMA-BUF into EGL
  and then performs `GetTextureSubImage()` readback. That is an explicit CPU
  fallback and must be observable as such.

### Portal and PipeWire

The permission-oriented path starts in
`src/platform/linux/portalgrab.cpp`:

- `dbus_t::connect_to_portal()` (`:233-256`) prefers combined RemoteDesktop and
  ScreenCast, then falls back to ScreenCast-only.
- `create_portal_session()` (`:353-417`) and
  `select_screencast_sources()` (`:469-520`) create a session and request
  monitor sources, embedded cursor, and multiple streams.
- `start_portal_session()` (`:522-630`) parses the returned PipeWire node,
  serial, position, size, and restore token.
- `open_pipewire_remote()` (`:633-647`) obtains the PipeWire remote FD.
- `portal_t::configure_stream()` (`:710-758`) passes the FD and node identity
  to the shared PipeWire capture implementation.

`src/platform/linux/pipewire.cpp` then:

- connects through `pw_context_connect_fd()` in `pipewire_t::init()`
  (`:245-274`);
- advertises DMA-BUF formats for suitable VAAPI, Vulkan, or pure-NVIDIA paths,
  while always advertising `SPA_DATA_MemPtr` as a fallback in
  `ensure_stream()` (`:288-353`);
- selects `SPA_DATA_DmaBuf` only when a negotiated modifier is present in
  `on_param_changed()` (`:636-719`);
- drains every queued `pw_buffer` and retains only the newest in `on_process()`
  (`:584-634`);
- duplicates each plane FD and copies its modifier, pitch, and offset in
  `fill_img_dmabuf()` (`:403-413`);
- copies MemPtr frames into double-buffered staging memory when DMA-BUF was not
  negotiated.

Portal is a useful fallback because it follows desktop permission policy, but
it cannot guarantee a stable source identity or a zero-CPU-copy result. The
user or portal backend controls source selection, the restore token has its own
lifecycle, and the selected PipeWire format can still be MemPtr. Viewflow must
log the actual negotiated memory type for every stream.

There is also a subtle testing point: the encode-device factory uses the
availability of importable DMA-BUF formats to choose some VRAM devices
(`pipewire.cpp:1049-1075`), while the compositor may ultimately negotiate
MemPtr. The Viewflow implementation should choose or validate the fast path
against the buffer type actually received, not only the capability probe.

### DRM/KMS

`src/platform/linux/kmsgrab.cpp` is a direct-display alternative:

1. `card_t::init()` (`:438-489`) opens the DRM card/render node, enables plane
   capabilities, and enumerates planes.
2. `display_t::init()` (`:898-1104`) selects the card, plane, CRTC, framebuffer,
   and capture geometry.
3. `display_t::refresh()` (`:1381-1443`) gets the current framebuffer and uses
   `card_t::handleFD()` (`:678-687`) / `drmPrimeHandleToFD()` to export GEM
   handles as DMA-BUF FDs.
4. `display_vram_t::snapshot()` (`:1849-1889`) transfers the resulting
   descriptor to VAAPI, CUDA, or Vulkan. `display_ram_t::snapshot()`
   (`:1648-1689`) imports through EGL and reads pixels back.

The cursor plane uses a separate CPU mapping and `DMA_BUF_IOCTL_SYNC` path.
KMS also requires access to the primary DRM node and elevated capture
capability. Sunshine initializes it before dropping `CAP_SYS_ADMIN`, and
marks it unavailable at runtime in AppImage and Flatpak builds
(`kmsgrab.cpp:2098-2100`). This is a useful descriptor and
privilege-boundary reference, but it is the wrong source for Viewflow's
per-window compositing semantics.

Backend probing lives in `src/platform/linux/misc.cpp:1211-1309` and
`:1344-1379`. The construction order is KMS, NvFBC, wlroots, X11, Portal, then
KWin. KMS appears first partly because it must initialize before Sunshine drops
privileges; this ordering should not be interpreted as a recommendation that a
normal Wayland application prefer KMS.

## Hardware encoding

Sunshine separates four concerns that Viewflow should also keep distinct:

1. capture image and memory type (`img_t`, `mem_type_e`);
2. GPU conversion device (`encode_device_t::convert()`);
3. FFmpeg hardware device/frame context;
4. codec selection and encoder options.

The common interfaces are in `src/platform/common.h:503-586` and
`:659-726`. `make_encode_device()` in `src/video.cpp:2521-2570` asks the active
display backend for the conversion device. `make_avcodec_encode_session()`
(`:1908-2294`) constructs the FFmpeg codec and hardware frames, while
`encode_avcodec()` (`:1773-1846`) performs `avcodec_send_frame()` and drains
packets.

This separation exposes an important truth: selecting a hardware codec does
not prove an end-to-end GPU path. If the display device does not provide a
hardware conversion context, `video.cpp:2264-2277` replaces it with
`avcodec_software_encode_device_t`; that path uses swscale and then uploads to
the hardware frame. Viewflow telemetry must report the capture memory type,
conversion path, and final `AVFrame::format`, not just an encoder name.

### VAAPI

Linux Intel and AMD encoding is registered through FFmpeg VAAPI in
`src/video.cpp:1185-1247`: `AV_HWDEVICE_TYPE_VAAPI`,
`AV_PIX_FMT_VAAPI`, and NV12/P010 software formats with `h264_vaapi`,
`hevc_vaapi`, and `av1_vaapi`.

The GPU path in `src/platform/linux/vaapi.cpp` is:

- `va_t::init()` (`:153-196`) opens the DRM render device and initializes
  GBM/EGL.
- `va_t::set_frame()` (`:420-494`) allocates a VA surface through FFmpeg,
  exports it as DRM PRIME, and imports its Y/UV planes as EGL render targets.
- `va_vram_t::convert()` (`:544-575`) imports the capture DMA-BUF as an EGL
  source and renders the color conversion/scaling into that VA surface.
- `va_ram_t::convert()` (`:525-538`) uploads CPU BGRA before running the same
  GPU conversion.

The source DMA-BUF is not passed directly to the codec as
`AV_PIX_FMT_DRM_PRIME`. Even the fast path performs a GPU shader
conversion/render into an encoder-owned VA surface. The accurate claim is
"GPU-resident with no CPU pixel copy," not "zero-copy."

### NVIDIA / FFmpeg NVENC

On Linux, the NVENC descriptors in `src/video.cpp:729-824` use FFmpeg's CUDA
hardware context and `h264_nvenc`, `hevc_nvenc`, or `av1_nvenc`. Sunshine's
native `src/nvenc/*` session is a different, currently Windows-oriented path.
The CUDA hardware-device callback is
`cuda_init_avcodec_hardware_input_buffer()` at `video.cpp:3524-3535`.

For a general DMA-BUF capture source,
`gl_cuda_vram_t::convert()` in `src/platform/linux/cuda.cpp:532-605`:

1. imports the source DMA-BUF through EGL/OpenGL;
2. performs GL color conversion;
3. maps registered GL targets through CUDA interop;
4. copies the converted planes into the FFmpeg CUDA frame with
   `cuMemcpy2DAsync`.

This avoids CPU pixel copies but includes a device-to-device copy. It must not
be advertised as strict zero-copy. The RAM path (`cuda_ram_t::convert()`,
`:290-328`) performs an upload before CUDA conversion. NvFBC has a separate
CUDA-resident source path, but it also copies the captured device buffer into a
Sunshine texture (`cuda.cpp:1175-1204`).

### Vulkan Video

`vk_vram_t::convert()` in
`src/platform/linux/vulkan_encode.cpp:286-376` imports a capture DMA-BUF and
dispatches compute RGB-to-YUV conversion (`:768-894`). `import_dmabuf()`
(`:534-643`) duplicates the FD, creates a DRM-modifier `VkImage`, imports
external memory, and binds it. FFmpeg then owns the Vulkan hardware frame and
video-encode integration.

The design is valuable for understanding multi-plane modifiers and ownership,
but Vulkan Video remains the highest-risk backend: codec extensions, modifier
support, synchronization, and driver behavior vary substantially. Viewflow
should keep it behind an experimental capability gate until the exact hardware
matrix has sustained-stream tests.

### QSV and fallback cautions

The QSV descriptor block in `src/video.cpp:827-937` and its encoder-list entry
are guarded by `_WIN32`. This checkout does not provide a Linux QSV path;
Intel Linux encoding goes through VAAPI/libva.

X11 capture is also not a GPU fast-path reference here. `XGetImage` and the
SHM path in `src/platform/linux/x11grab.cpp` ultimately copy into Sunshine RAM,
and the encoder devices use RAM input. Comments suggesting that SHM avoids a
copy must not be used as end-to-end proof.

For each Viewflow backend, validation should distinguish:

- CPU pixel copies;
- GPU/device-to-device copies;
- color-conversion passes;
- negotiated DRM fourcc and modifier;
- source and destination GPU identity;
- final FFmpeg hardware-frame format;
- every transition to a RAM fallback.

## System and per-application audio

Sunshine's Linux audio backend uses the PulseAudio client API. On a modern
PipeWire desktop, it normally reaches PipeWire through `pipewire-pulse`; the
native PipeWire code described above is video-only.

`server_t::sink_info()` in `src/platform/linux/audio.cpp:426-519` creates or
discovers stereo, 5.1, and 7.1 `module-null-sink` instances.
`get_monitor_name()` (`:554-583`) resolves the selected sink's monitor source,
and `microphone()` (`:596-613`) records that source through `pa_simple_new()`
(`:101-131`). `src/audio.cpp:157-274` chooses the configured, virtual, or host
sink and captures float PCM. `encodeThread()` (`audio.cpp:109-152`) encodes
48 kHz 2/6/8-channel Opus multistream with
`OPUS_APPLICATION_RESTRICTED_LOWDELAY`, constant bitrate, and a separate
high-priority worker.

Sunshine does **not** implement per-application audio capture in this checkout:

- it does not enumerate or subscribe to PulseAudio sink inputs;
- it does not move individual sink inputs;
- it does not match native PipeWire audio nodes by application metadata;
- `server_t::set_sink()` (`platform/linux/audio.cpp:626-654`) changes the
  global default sink, and `audio.cpp:211-220` uses that global operation for
  the first streaming session.

That behavior is unsuitable for Viewflow, where an audio route belongs to a
window family. Changing the default also does not move existing sink inputs:
already-running or explicitly routed applications can remain on the previous
sink and therefore be absent from Sunshine's virtual-sink monitor. A minimal
independent PulseAudio-compatible design is:

1. create one dedicated virtual sink per active Viewflow route or mixing group;
2. enumerate and subscribe to sink inputs;
3. where possible, inject a Viewflow route identifier into inherited
   PulseAudio/PipeWire properties, then use process-tree and application
   metadata as fallbacks; PID or `application.name` alone is not stable or
   unique;
4. move only the selected sink inputs to the virtual sink;
5. capture the virtual sink monitor as float PCM at 48 kHz;
6. subscribe for newly created streams and reapply the route generation;
7. record each input's original sink and restore it only when the matching
   route generation is revoked; use durable journaling or startup
   reconciliation because in-process cleanup cannot survive a hard crash;
8. if host playback is requested, loop the virtual sink into the original host
   sink without changing the global default, while preserving the channel
   layout and preventing feedback; account for added buffering and use
   reference-counted cleanup when routes or viewers share the loopback.

A native PipeWire alternative can match application audio nodes and request an
F32/48 kHz format. The actual format is negotiated, and capture requires graph,
session-manager, and permission cooperation distinct from the ScreenCast
portal video path. It may provide better graph semantics but is a new audio
implementation; Sunshine's video `pipewire_t` is not reusable for it.

Viewflow should also define policy for ambiguous or shared processes: multiple
windows from one process, browser and Steam subprocesses, detached launchers,
native PipeWire clients that do not preserve an injected tag, application
restarts, streams without PID metadata, and two remote devices requesting the
same source. Audio route generation must prevent a late callback from
resurrecting an old route.

## Frame scheduling and latency policy

The reusable idea is a latest-value media pipeline with one monotonic capture
timestamp, not Sunshine's exact queue depths.

### Capture and encode

- `captureThread()` in `src/video.cpp:1507-1660` runs at critical priority,
  owns a pool of 12 images, and broadcasts the same `shared_ptr<img_t>` to all
  active asynchronous sessions.
- Each session uses `img_event_t`, an `event_t` latest value rather than a FIFO
  (`src/video.h:118-120`; overwrite behavior in
  `src/thread_safe.h:37-49`). Raising a new image overwrites an unconsumed old
  one.
- `encode_run()` (`video.cpp:2347-2453`) waits no longer than
  `1000 / minimum_fps_target`; the default target is half the requested FPS.
  On static content it re-encodes the previous converted frame. An IDR request
  can use the old or initial dummy frame immediately instead of waiting for new
  capture.
- `video::capture()` (`video.cpp:2911-2939`) uses separate capture and
  per-session encode threads for encoders with `PARALLEL_ENCODING`. Other
  encoders use one shared synchronous capture path and encode clients serially.

Platform pacing generally advances `next_frame += interval`. If capture is
late, the loop reanchors rather than replaying every missed tick. PipeWire
drains pending buffers and emits only the newest. This prevents historical
frames from consuming the latency budget.

`img_t::frame_timestamp` is a `steady_clock::time_point`
(`src/platform/common.h:503-521`). The timestamp follows the encoded packet into
`stream::videoBroadcastThread()` (`src/stream.cpp:1469-1690`), where Sunshine
computes host processing latency before FEC, encryption, pacing, and the socket
send. Real captured frames derive their 90 kHz RTP timestamp from capture time;
static repeated frames that lack a capture timestamp use the sender's
rate-control timeline.

### Queue and send policy

The generic mailbox queue defaults to 32 elements
(`src/thread_safe.h:391-422`, `:826-836`). At capacity, `queue_t::raise()`
unconditionally clears the entire backlog before inserting the new item; it is
not a selective oldest-item eviction and the queue type itself is not
media-specific. That policy may be acceptable at a carefully chosen
replaceable-media boundary, but it would be data loss for control, clipboard,
file, HID, or lease messages.

The video sender is a separate high-priority thread. It generates FEC shards
and smooths UDP bursts with a cross-frame rate-control timeline. This is packet
burst pacing, not frame pacing; capture and minimum-FPS logic establish the
frame cadence.

For Viewflow:

- use the host monotonic clock for host-local stage timings, carry a media
  timestamp and `frame_id` across the network, and use a separate client
  monotonic clock for receive/decode/presentation timings; compute end-to-end
  latency only after clock-offset estimation through Viewflow's clock-sync
  protocol;
- retain latest-frame replacement for unencoded color/alpha capture or atlas
  work, but evict the pair atomically by `frame_id`; this paired-plane rule is
  a Viewflow design inference, not behavior proven by Sunshine;
- after predictive encoding, discard only complete dependency units that the
  media protocol marks as disposable; loss of a reference frame requires IDR
  or explicit reference-frame invalidation recovery;
- never apply backlog-clearing semantics to reliable control traffic;
- reanchor after missed deadlines instead of encoding a burst of stale frames;
- repeat static content at the encode layer only when the negotiated decoder or
  transport requires it;
- count every eviction at the component that performs it;
- size image buffers and queues from an explicit latency budget rather than
  copying Sunshine's capacities of 12, 30, or 32;
- avoid serial multi-client encoding in the capture callback, because the
  slowest encoder would delay every client and hold capture images longer.

## Process-boundary options

### Unmodified Sunshine

Running an unmodified Sunshine executable and communicating through its
existing network protocol creates a clear runtime and deployment boundary. It
does not, by itself, determine whether a surrounding work is legally
independent. It also does not solve Viewflow's core requirements: Sunshine
exposes a GameStream-compatible whole-display stream, not a generic local API
for per-window DMA-BUF export, atlas placement, paired color/alpha elementary
streams, or Viewflow's QUIC control protocol.

It can still be used operationally as a separate remote-desktop product, but it
should not sit in Viewflow's media hot path.

### Custom helper

A GPL helper derived from Sunshine may remain a separate executable and expose
a documented local protocol. Process separation alone does not guarantee that
the non-GPL side is non-derivative, especially if the protocol mirrors private
classes or creates intimate shared control flow. That architecture needs legal
review before distribution.

If Viewflow needs a helper, the lower-risk engineering direction is an
independent implementation against public APIs with a narrow, versioned IPC:

- Portal DBus returns a PipeWire remote FD and node/serial;
- DMA-BUF planes cross a Unix socket through `SCM_RIGHTS`, accompanied by
  width, height, fourcc, modifier, pitch, offset, source GPU, and ownership;
- explicit sync fences travel with the frame when the producer API provides
  them;
- audio routing exposes route generation, application identity, virtual sink
  identity, and restore acknowledgement;
- the receiver validates plane counts, sizes, offsets, modifiers, FD types,
  and generation before importing anything.

The Hyprland plugin should remain the compositor-aware producer of per-window
metadata and pixel planes. A host-owned media worker can independently import
those descriptors, build the atlas, encode color and alpha, and feed Viewflow's
existing transport contracts. This keeps compositor ABI risk, media-driver
risk, and GPL-derived code in explicit compartments.

## License and distribution checklist

Before adopting any path:

- Treat Sunshine source-code expression and any copied, closely translated, or
  derivative class layout and control-flow implementation as GPL-3.0-only
  unless a specific file says otherwise. Do not infer that abstract algorithms
  or public API concepts are automatically covered; preserve evidence of an
  independent implementation.
- Implement Wayland, Portal, PipeWire, DRM, GBM, EGL, VAAPI, Vulkan, FFmpeg,
  PulseAudio, and Opus integration from their official specifications and
  library documentation, not by translating Sunshine source.
- Audit every protocol XML file and retain its copyright/license text plus the
  notices required for generated stubs. The inspected checkout's
  `wlr-protocols`, `wayland-protocols`, and `plasma-wayland-protocols`
  submodules were not populated, so their pinned files still require review.
- Audit the exact FFmpeg build configuration and all linked codec libraries.
  Sunshine's default bundled-dependency path downloads prebuilt archives and
  statically links FFmpeg plus codecs, while prepared binaries can be supplied
  separately. The unpopulated build-deps checkout was insufficient to verify
  the default archives' full configuration and notices.
- Keep library copyright compliance separate from codec patent licensing.
  Sunshine's `docs/legal.md:14-20` makes the same distinction.
- Do not infer the runtime NVIDIA library terms from the bundled NvFBC header.
  That header carries its own permissive notice, while CUDA, NvFBC, NVENC, and
  the driver remain subject to NVIDIA's applicable licenses and EULAs.
- If distributing a modified Sunshine or a derivative helper, satisfy GPLv3
  corresponding-source and notice obligations for that distributed component.
- Record source provenance and an independent-design note for every Viewflow
  backend implementation.

## Concrete adoption order

1. Keep the Hyprland compositor plugin as the only authoritative per-window
   capture path. Define an owned multi-plane DMA-BUF descriptor plus explicit
   fence semantics between the plugin and media worker.
2. Implement VAAPI first for Linux Intel/AMD: DMA-BUF import, one measured GPU
   conversion into encoder-owned NV12/P010 surfaces, and a clearly logged RAM
   fallback.
3. Add the NVIDIA EGL/GL/CUDA bridge as a separate backend and expose its
   device-to-device copy in metrics.
4. Add Portal/PipeWire only as a whole-monitor fallback and capability probe;
   select the encode path from the actual negotiated buffer type.
5. Implement per-app audio independently using PulseAudio sink-input routing
   first, including subscription, generation checks, host loopback, and
   transactional restoration. Evaluate native PipeWire after behavior is
   correct.
6. Apply latest-frame scheduling to unencoded atomic color/alpha pairs, define
   encoded-frame dependency/drop rules plus IDR recovery, and keep reliable
   control queues lossless and bounded separately.
7. Gate Vulkan Video and direct KMS capture behind explicit experimental or
   diagnostic settings until hardware and privilege matrices are proven.

Sunshine is most valuable here as evidence that Linux capture, GPU conversion,
hardware encode, and low-latency scheduling must be designed as separate,
observable layers. It is not a drop-in source for Viewflow's per-window,
alpha-preserving architecture.
