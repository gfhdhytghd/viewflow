# Owned 4K motion and interaction fixture

This fixture draws a moving checkerboard, gradient, and bar over a 3840 × 2400
OpenGL ES surface. It uses a precise monotonic 60 Hz producer schedule and
avoids catch-up bursts after a stall. `fixture-render` and `fixture-swap` are
producer diagnostics, **not physical presentation receipts**.

Build with Qt 6 Gui/OpenGL:

```sh
cmake -S platform/linux-frame-fixture -B /tmp/viewflow-frame-fixture-build -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/viewflow-frame-fixture-build --parallel 2
```

The two arguments are an existing screen name and a bounded lifetime in
milliseconds (1000–300000). The current verification environment uses the
already-existing `HEADLESS-6` screen at 3840 × 2400, scale 2, workspace 9. A
matching temporary Hyprland rule places only class `viewflow-frame-fixture`
on that workspace, floats it at 1920 × 1200 logical pixels, and suppresses
initial focus, animation, blur and shadow for the fixture. Disable the owned
rule after testing; do not reload or rewrite the user's general configuration.
The application itself does not request activation or inject input.

```sh
QT_QPA_PLATFORM=wayland /tmp/viewflow-frame-fixture-build/viewflow_linux_frame_fixture HEADLESS-6 30000
```

Check live capture geometry before creating a media config: the capture backend
may include decorations outside the 3840 × 2400 content. The current backend
reports 3848 × 2408, encoded in a 3968 × 2432 atlas. The first surface configure
may briefly change DPR; exclude startup and verify stable physical dimensions.
The tested renderer is NVIDIA OpenGL ES 3.2. Desktop OpenGL context creation
failed with EGL_BAD_MATCH on this machine; the explicit GLES context avoids it.

The marker occupies physical x=32..2079, y=32..95. Its 64 cells are 32 × 64:
32 frame-counter bits, 16 input-counter bits, then 16 check bits, all MSB first.
The check word is `(frame ^ (frame >> 16) ^ input ^ 0xA65C) & 0xffff`.
Sample cell centers, reject low contrast/check failures, and correlate with the
source log. Black/white cells tolerate lossy H.264; they are not a security code.
Owned-window mouse presses and non-repeat key presses advance the input counter
and log their local monotonic timestamp. Cross-machine latency still requires
an explicit clock mapping or a receiver-side injection/observation timestamp
pair; neither the producer swap rate nor encoded submission counts prove the
60 FPS / two-frame end-to-end target.

Windows desktop observation is available as the manual CMake target
`viewflow_windows_frame_observer` in `platform/windows-composition-preview`:

```powershell
viewflow_windows_frame_observer.exe <owned-preview-process-id> 20000 marker.log
```

Run it in the same interactive Windows session as the receiver. It accepts
only a unique visible `ViewflowAtlasProxy` belonging to that exact process ID,
reads one marker scanline through DXGI desktop duplication, validates contrast
and the check word, and writes only numeric diagnostics. It assumes the verified
3848x2408 capture geometry above, scaling cell centers to the proxy client size.
It does not activate the window or inject input. Optional final argument
`physical4k` first moves only that proxy to an enumerated 3840x2400 monitor,
without changing size, z-order or focus; it fails if no such monitor is active.
The monitor and adapter diagnostics describe the current interactive session;
a WMI video-controller resolution alone does not establish an active monitor.

```sh
python3 tools/summarize_desktop_markers.py marker.log
```

The result counts changing producer IDs at DXGI `LastPresentTime` timestamps.
These are composed-desktop observations, not panel photon receipts; readback may
miss changes and adds measurable GPU work. Report acquisition and copy/map costs
alongside the observation rate. Positive timestamps and monotonic marker IDs
are required for useful timing evidence. End-to-end input latency still needs
the receiver-side input/observation pair described above.

For clock-aligned pre-draw-to-desktop latency, enable source/receiver
`VIEWFLOW_ATLAS_TIMINGS=all` and retain all three matching logs:

```sh
python3 tools/summarize_desktop_markers.py marker.log \
  --source source.log --fixture fixture.log --receiver receiver.log
```

The receiver clock anchor is mandatory: its media clock starts at connection
creation and has a different origin from desktop QPC. Bounds include the existing
paired clock estimate's uncertainty and the receiver anchor's sampling interval.
Optional source `VIEWFLOW_GPU_FIXTURE_MARKER=1` records the producer marker from
the retained source tile before packing; the summarizer then reports capture
stages for uniquely matched IDs. Repeated marker IDs are reported as ambiguous.
The current observer also maps rotated DXGI outputs; the tested 4K output is
rotated 180 degrees. `physical4k` aligns the captured border at monitor origin
minus four pixels, so the entire 3840x2400 content fits the display.
