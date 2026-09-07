# Viewflow

Viewflow is an experimental cross-device window compositor. Applications stay
on their source machine while window pixels, input, clipboard data, files, and
per-application audio move across a shared logical desktop.

The repository currently contains an executable, tested foundation rather than
a finished three-platform product. Implemented components are:

- protocol 2.1 control types for topology, geometry, deadline-gated input, clipboard, file
  drag, per-application audio, raw HID leases, and clock synchronization;
- a coordinator with replay-safe transfer state machines, generation-numbered
  input/HID leases, window-family audio routes, and committed geometry epochs;
- authenticated QUIC control/blob streams plus low-latency media datagrams,
  clock mapping, bounded reassembly, and separate normal-media/exact-blur
  latency statistics;
- atomic color/alpha frame admission, latest-frame queues, and forward sparse
  atlas residency with overlap/viewport culling and optional transparent
  precomposition (see [configuration and limits](docs/occlusion-and-transparency.md));
- device-pair atlas layout with stable reservations, transactional geometry
  invalidation and disconnect suspension, plus GPU composition/encoding adapters
  and a supervised QUIC-to-native receiver API; application orchestration remains
  incomplete (see [atlas integration](docs/atlas-layout.md));
- a receiver-side media API that reads authenticated QUIC datagrams, preserves
  encoded color/alpha bytes through atomic admission, and delivers them to an
  explicit decoder-facing sink; geometry changes discard partial old frames;
- a raw premultiplied-BGRA payload codec and proxy sink adapter, plus a Windows
  layered-window presenter with per-pixel alpha and move/resize support;
- a standalone Wayland per-toplevel capture client using compositor-provided
  image-copy capture into shared memory, preserving advertised alpha formats;
- a versioned owner-only local IPC service for a separate Deskflow/HID process;
- a lease-, target-, and sequence-validated QUIC input path with relative
  pointer motion, buttons, high-resolution wheel input, HID keyboard usages,
  disconnect release-all, and receiver-applied acknowledgements;
- a Windows Session 1 `SendInput` backend, including F13-F24 and common
  consumer-key mappings, with a stable injection tag for loop prevention;
- a read-mostly Hyprland 0.56 backend that enumerates monitors/windows directly
  over compositor IPC, plus a build-tested compositor metadata plugin.

The native pixel path is not product-complete. The opt-in `coded_window_peer`
example has exercised HyprCapture GPU window capture -> NVENC -> authenticated
QUIC -> Windows hardware decode/composition in bounded WindowsVM trials. Full
preview bounds and upright normal-output orientation have been visually checked;
this is not acceptance of every transform, resolution or performance target.
The Viewflow Hyprland plugin provides metadata and a separately authorized,
window-scoped native pointer route; capture still comes from HyprCapture, not
that plugin's capture backend. The separate
[Wayland capture helper](platform/wayland-capture/README.md) has captured and
visually verified an owned diagnostic window using `wl_shm`
([evidence](docs/evidence/linux-capture-20260904/README.md)).
For Hyprland, the previously exercised capture integration is HyprCapture's own
`window_capture` interface, to retain compositor borders and shadows; standard
Wayland capture remains a compatibility/diagnostic path, not proof of complete
decoration capture. See the [capture contract](docs/hyprcapture-integration.md).
The MVP is migrating to the independent
[`viewflow-capture` plugin](platform/viewflow-capture/README.md): its window-only
GPU capture library builds, and the atlas source defaults to its separate Lua
namespace. HyprCapture remains an explicit legacy diagnostic provider; its
ongoing development is not modified or required by the new build. Native load,
visual readback, exact release, stop and unload have passed in bounded nested
runtime checks. Three subsequent bounded 20-second two-window CUDA/NVENC/QUIC/
Windows trials completed 530, 512 and 498 native submissions. These results do
not establish sustained two-refresh performance, physical presentation or input
acceptance.
The [HyprCapture adapter](platform/hyprcapture-capture/README.md) has now captured
and visually verified one owned decorated window through the loaded plugin
([evidence](docs/evidence/linux-capture-20260904/hyprcapture.md)). GPU streaming
and native motion trials are tracked in the
[current integration status](docs/window-input-integration-status.md).
The Windows atlas receiver and Linux GPU source now have explicit
[`vf-media-peer receive/send` process entries](docs/atlas-peer.md). One current
single-window trial completed 159 native visual submissions before a deadline
failure; that failed boundary remains part of the acceptance record. Continuous
recovery, product-session integration, sustained performance, physical
presentation and physical multi-window/input acceptance remain incomplete.
Native macOS ↔ Hyprland/Windows window sharing is available through the standalone
[`vf-window-peer`](docs/macos-window-sharing.md), with live capture and interaction
acceptance still pending. The macOS Quartz
keyboard/mouse receiver has passed a bounded [LAN live smoke test](docs/evidence/macos-input-live-20260907/README.md);
broader physical acceptance remains pending. The CPU
layered-window presenter is a separate incremental endpoint, not the GPU
hardware-decode/composition path used by the coded example.

The media receiver API is exercised by an authenticated loopback integration
test (`cargo test -p viewflowd --test media_receiver_quic`). It is not yet wired
to the running peer's window-control loop. The raw BGRA adapter can call the
native Windows presenter. This particular raw-payload test does not cover the
coded example's hardware decoder or establish capture, visual correctness, or
display latency.
The native presenter has also passed a short Windows Session 1
[API submission check](docs/evidence/windows-proxy-20260904/README.md), including
size changes and process cleanup; visual and timing acceptance remain pending.

The performance requirements are acceptance targets, not current benchmark
results. Every retained standard-media sample must present within two target
refresh periods (33.3 ms at 60 Hz); P99 remains a diagnostic statistic, not the
acceptance boundary. Exact compositor blur is measured separately and may
exceed that budget. 6K60 is an optimization point, not a protocol or resolution
ceiling.

## Build

macOS native discovery, ScreenCaptureKit capture and AppKit presentation are in
[`platform/macos`](platform/macos/README.md). See the
[window-sharing setup](docs/macos-window-sharing.md) for paired backends.
Native keyboard/mouse receiving is available via
`--input-backend native`; see [macOS input setup](deploy/macos/README.md).

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo run -p viewflowd -- --help
```

`viewflowd` can run an mTLS-authenticated QUIC health-check peer without a
system `protoc` installation. It exchanges periodic monotonic-clock probes,
logs peer addresses and RTT/offset estimates, and reconnects with a capped
exponential delay:

```sh
# Listening peer
cargo run -p viewflowd -- serve \
  --bind 0.0.0.0:44119 --cert server.pem --key server.key --ca ca.pem

# Connecting peer
cargo run -p viewflowd -- connect \
  --peer 192.0.2.10:44119 --server-name viewflow-peer \
  --cert client.pem --key client.key --ca ca.pem \
  --input-backend native \
  --device-id 00000000000000000000000000000002
```

`--input-backend native` supports Windows and macOS and requires the receiver's stable
`--device-id`. A listening peer may send one balanced smoke-input script with
`--input-script`; scripts must start with an offered lease, end with all keys
and buttons released, and are transported only once per daemon lifetime. This
is a deployment probe, not the final Hyprland edge-capture integration.

Certificates and keys are always loaded from explicit paths; no test identity
is embedded in the binary. This peer uses its own UDP port and does not stop or
reconfigure Deskflow. Keep Deskflow running until physical mouse, keyboard,
wheel, held-button dragging, return-to-local, and disconnect release have all
been verified on the affected machines.

Viewflow code is GPL-3.0-only. Deskflow is not linked into these binaries; it is
integrated as a separate GPL-2.0-only process over local IPC.

An input acknowledgement means that the receiving daemon validated the exact
lease/target/sequence tuple and that its native backend accepted the event. It
does not provide exactly-once delivery across a peer crash or lost
acknowledgement.

Source-derived implementation notes for Moonlight, Sunshine, and FreeRDP RAIL
are under `docs/`. Third-party source is not copied into Viewflow.

跨系统剪切板：桌面会话自动双向同步文本和 PNG；Linux、Windows、macOS 也可运行独立的 `vf-clipboard-peer`。配置与限制见 [剪切板同步](docs/clipboard-sync.md)。
