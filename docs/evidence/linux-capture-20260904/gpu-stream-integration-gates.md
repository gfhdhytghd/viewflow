# GPU stream integration gates

Update: the local render-loop -> Rust receiver -> native GPU encoder chain
has now been exercised on actual Dolphin frames. See
[2026-09-05 live evidence](gpu-live-20260905.md) for artifacts, cold-start
rejections, explicit warmup, and the 12-frame 8.0–13.0 ms local result.
Windows transport/presentation integration remains pending. The component
status below records earlier steps, not the latest runtime boundary.

Status (2026-09-05): component tests pass; the live capture-to-Windows path
is not integrated or accepted. Separate-process DMA-BUF import and native
fence probes now establish the sharing prerequisite, not live presentation.

Latest independent checks:

- Fresh HyprCapture build at `/tmp/viewflow-hyprcapture-gpu-build`: plugin
  builds; `ctest -R window-gpu --output-on-failure` passes wire, sender, and
  hardware export tests (3/3). The loaded plugin was not overwritten.
- Full build followed by full CTest passes 17/17, including recording state
  and RGBA transform tests. This predates the GPU render-loop hook integration.
- `cargo test -p viewflowd --lib --quiet` passes 171/171 before adding the GPU
  socket receiver. These are source tests, not real desktop acceptance.
- `/tmp/window-gpu-export-test` passes native-fence, layout, GL state
  preservation and exact imported RGBA checks.
- `/tmp/viewflow-dmabuf-encoder/viewflow-gpu-dmabuf-encoder-integration-test`
  passes changing two-frame encoding and interleaved encoder lifetime checks.
- The hardware export CTest is opt-in with `HYPRCAPTURE_GPU_EXPORT_TEST=ON`;
  ordinary builds do not require a functioning GPU test environment.

The opt-in render-loop hook now accepts `mode: "window-gpu"` through the
existing start/stop controls; `window` remains the CPU transport. Geometry,
timestamp and shadow metadata are frozen before rendering. Busy/Connecting
skips rendering; only a matching release allows allocation reuse. A retired
sender stops the session. Independent full build and CTest after this hook
pass 17/17. This new plugin has not been loaded into the compositor.

Remaining: receiver/encoder wiring and a real changing Dolphin preview
meeting the unchanged presentation deadline. The receiver must authenticate
the expected compositor PID and UID, not merely accept any same-UID peer.

The standalone Rust GPU socket component is now implemented and independently
tested (daemon library 177/177). It validates exact compositor PID/UID, HCGF
size and two close-on-exec descriptors; malformed packets retire the session.
An explicit release is bound to both frame lineage and a private session token.
Dropping a frame does not send HCGR. Native encode failure requires retirement,
not release, because source-read completion may be unproven. This component
is not yet connected to the native encoder or a diagnostic CLI.

Final lint cleanup: `cargo clippy -p viewflowd --lib -- -D warnings` passes.
An earlier full 177-test run passed; subsequent full runs were not stable:
parallel execution hit the existing sidecar generation test's revoke deadline,
and a serial run hit the existing clock-snapshot test's unsynchronized-clock
rejection (measured loopback RTT 8973 us). The sidecar test passed in isolation.
No production deadline or clock-uncertainty threshold was relaxed. Do not
interpret these source checks as a clean repeatable full acceptance matrix.

The existing HCSF v1 payload is a sealed CPU memfd containing straight,
top-down RGBA. A GPU handle must not be passed under that format or validated
as though it were a sealed memfd. Keep the existing recording path unchanged.

Before replacing the diagnostic's CPU path:

1. Prove an owned GL texture can feed a CUDA hardware frame and NVENC, with
   decoded color checks and independently verified alpha. Keep the original
   render timestamp and explicit frame identity; encoder submission is not
   display completion.
2. Choose and separately prove the process boundary. Same-process GL/CUDA
   registration is not proof that an exported DMA-BUF or CUDA IPC allocation
   can be imported by the receiver. Validate device identity, format, stride,
   geometry, producer ownership and synchronization on the chosen boundary.
3. Preserve the existing stream's top-seam repair, unpremultiplication and
   optional shadow repair. Test GPU results against CPU fixtures, including
   alpha zero, rounded corners, scale changes and decoration extents. A color
   encoder alone cannot replace the alpha plane or destination blur metadata.
   Explicitly convert the GL framebuffer's row origin and render crop to the
   protocol's top-down image coordinates. Synthetic GL row comparisons alone
   do not prove the remote window is upright. Freeze shadow/style parameters
   with the render-time geometry rather than querying a later window state.
4. Bound in-flight resources and retain each source allocation until its
   consumer releases it. Dropping a stale frame must release its handle and
   synchronization object exactly once. Disconnect and resize must invalidate
   old geometry generations without reusing a still-owned texture.
5. Never block Hyprland's render/event thread on encoding, networking or a
   consumer ACK. Export/handoff failure must remain local to the opt-in stream;
   it must not change or disable the user's recording implementation.
6. Re-run the real decorated Dolphin preview at its physical dimensions.
   Require changing content, exact frame lineage, independent alpha and blur,
   and fresh native submission within the existing deadline. GPU capability
   probes and synthetic frames are prerequisites, not this acceptance test.

Observed source boundary: `finalizeReadyWindowStreamFrame` currently repairs
the top seam, unpremultiplies RGBA and repairs the transparent shadow after
readback. Bypassing that function without equivalent processing would regress
the visual result already confirmed by the user.
