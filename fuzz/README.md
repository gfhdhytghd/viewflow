# Fuzzing

libFuzzer targets for every decoder that reads bytes from a peer, a local IPC
pipe, or a socket. A malformed message must be rejected on its own; none of
these inputs may panic, hang, or allocate without a bound.

This crate has its own `[workspace]`, so the main workspace never builds it.
Private decoders are reached through `fuzz_api` modules that exist only with
each crate's `fuzzing` feature.

```sh
cargo install cargo-fuzz
cd fuzz
cargo +nightly fuzz build
cargo +nightly fuzz run control_envelope seeds/control_envelope -- \
    -max_total_time=60 -rss_limit_mb=2048
```

`seeds/` holds a few valid messages per format so the fuzzer gets past magic
numbers and exact lengths quickly. Pass the seed directory after the target
name; new corpus entries go to `corpus/<target>` (ignored by git).

Where an encoder exists, the target also checks that a decoded value
re-encodes to the same bytes or to a stable canonical form.

| Target | Input |
| --- | --- |
| `sidecar_request`, `sidecar_response` | Deskflow sidecar IPC frames (platform `sidecar`) |
| `sidecar_quarantine_marker` | Durable sidecar quarantine marker |
| `windows_input_wire` | Windows input-service request and result records |
| `reliable_decode` | VFRS reliable stream header, control and blob chunks |
| `codec_descriptor` | VFCD codec descriptor and VFCF frame metadata |
| `alpha_rle` | VFAR alpha payload: decode, validate, profile agree |
| `raw_bgra` | VFBG raw BGRA payload |
| `media_datagram` | VFMD media datagram header |
| `media_reassembly` | Datagram sequences through `MediaAssembler` |
| `control_envelope` | Protobuf `ControlEnvelope` to `DomainControl` |
| `protocol_roundtrip` | Protobuf to domain to protobuf for each typed message |
| `hyprcapture_stream` | HCSF headers through a `FrameCursor` |
| `hyprcapture_gpu` | HCGF frame, HCGI geometry, HCGR release |
| `native_window_input` | VFRV input records and `read_input` |
| `cursor_feedback` | VFCF cursor telemetry datagrams |
| `atlas_feedback` | Atlas V3 feedback against a pending `AtlasFrame` |
| `audio_wire` | VFAU PCM datagrams |
| `clipboard_record` | Clipboard lane record, including PNG decode limits |
| `local_ipc_text` | Presenter-child lines and HyprCapture JSON replies |
| `deployment_marker` | Deployment quarantine marker |
| `hyprland_ipc` | Hyprland JSON replies and VFHY completion packets |
