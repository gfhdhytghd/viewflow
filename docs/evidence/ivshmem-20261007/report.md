# IVSHMEM implementation and deployment — 2026-10-07

## Delivered

Windows → Linux native reverse windows now support a BGRA IVSHMEM atlas path.
The existing paired QUIC route carries frame references and window metadata;
input remains on its existing ordered path. Two asynchronous D3D staging
textures feed four shared slots. Linux keeps the newest pending raw frame per
lane, retains owned/reusable pixels, and uploads BGRA directly to OpenGL.
See [implementation/configuration](../../windows-linux-shared-memory.md).

No video encoding/decoding is used for raw frames. This is not zero-copy:
guest readback/copy and host copy/upload remain. No 33 ms disconnect boundary
was added. Obsolete slot references are skipped while retaining the session.

## Machine and deployment

* Existing VM: `windows-autoshop.service`, QEMU/KVM, disk under
  `/home/wilf/data/PDL_ASP_Monitor/runtime/windows-vm/`.
* Intel `8086:7d67`, `0000:00:02.0`, remains exclusively on `vfio-pci`, IOMMU
  group 0. The actual D3D probe reports vendor `8086`, device `7d67`.
* NVIDIA RTX PRO 6000 stays bound to `nvidia` and remains Linux's display GPU.
  The host rendering probe reports that NVIDIA renderer.
* Windows is running with its original 24 GiB RAM and 10 vCPUs. The temporary
  8 GiB configuration used during initial memory pressure was removed.
* At the user's request, the standalone MiniMax/ComfyUI process using about
  46 GiB RSS was terminated. Host available RAM recovered to about 55 GiB
  before restoring the VM's 24 GiB allocation. Gateway/databases were retained.
* `/etc/systemd/system/windows-autoshop.service.d/90-viewflow-ivshmem.conf`
  adds the 512 MiB shared device and caps guest physical addresses at 39 bits.
  The original service file is unchanged. The backing file is
  `/dev/shm/viewflow-frames`, owned by `wilf`, mode 0600; boot creation is in
  `/etc/tmpfiles.d/viewflow-ivshmem.conf`.
* Initial uncapped PCI placement caused QEMU's VFIO DMA mapping failure at
  `0xe0010000000`. Retries were stopped; the physical-address limit fixed it.
  Linux's NVIDIA GPU was never detached. QEMU subsequently ran with no restarts.
* The signed IVSHMEM driver was installed as `oem19.inf`. Its catalog signature
  was `Valid`, signer Microsoft Windows Hardware Compatibility Publisher.
  Looking Glass's host service was not installed.
* After increasing the BAR from 256 to 512 MiB, Windows retained the old device
  extent through an ACPI power cycle. A full guest restart refreshed it.
  The final driver probe reports `ivshmem-mapped bytes=536870912`.
  Matching slot-capacity checks were added to both readiness and references
  so mismatched extents cannot silently address different pixel data.
* Windows `C:\Users\wilf\Viewflow\desktop-test\receive.json` now selects
  `C:\Users\wilf\Viewflow\ivshmem-20261007\build\Release\viewflow_windows_reverse.exe`
  with `--ivshmem 0` and an explicit `--mode-file` pointing to the existing
  `desktop-test\reverse-performance-mode` (read back as `frame-rate`), preserving
  the existing performance controller. The prior config is backed up in that deployment folder
  as `receive.before-ivshmem.json`.
* Linux `~/.config/viewflow/desktop-source.json` now selects
  `build/ivshmem-linux/viewflow_linux_reverse` with
  `--ivshmem /dev/shm/viewflow-frames`. Original bounds, origin and scale are
  retained. Backup: `build/ivshmem-backup/desktop-source.before-ivshmem.json`.

## Verification

Linux Release build and **10/10** CTests passed. Windows MSVC Release build and
**17/17** CTests passed. The shared protocol test checks concurrent pixel
integrity, pitched rows, stale references, full/busy slots, restart ownership,
wire validation, and mismatched mapping extents. `git diff --check` passed for
the touched platform directories. Existing unrelated working-tree edits were
retained; a task-only diff is in `build/ivshmem-backup/task-changes.patch`.

The final real paired-QUIC fixture run used existing pair certificates and
40-byte shared references through the existing `vf-window-peer` binaries.
Three completed 3840×2160 batches of 120 frames produced:

| Batch | Received | Obsolete references | Host copy p50 / p95 | Completed GPU upload p50 / p95 |
| --- | ---: | ---: | --- | --- |
| 1 | 118 | 2 | 2.150 / 3.408 ms | 3.709 / 9.216 ms |
| 2 | 120 | 0 | 2.154 / 3.454 ms | 4.166 / 9.510 ms |
| 3 | 120 | 0 | 2.265 / 3.580 ms | 4.694 / 10.432 ms |

Every consumed CPU pixel matched the generated BGRA fixture. Offscreen GPU
sampling verified RGB channel order and alpha. Each source batch was paced at
60 fps; this is a fixture, not a captured desktop. Source-child EOF after each
120-frame batch exercised the existing bridge's local recovery. Test completion
used SIGTERM to stop the isolated Linux peer. Temporary Windows probe tasks,
processes and the scoped UDP 44339 firewall rule were removed afterward.
The reader-ready flag left by the forced probe termination was cleared through
a fresh exclusive reader mapping; final readback was zero.

A separate 6144×3456 capacity/stress run sent 120 frames, consumed 108 and skipped
12 overwritten references. All consumed pixels and GPU samples matched.
Host-copy p50/p95 was **6.985/9.647 ms**, completed GPU-upload p50/p95
**11.655/17.831 ms**. Fixture generation, transport and validation took about
4.30 seconds: this does **not** establish 6K60 throughput. Per-pixel validation
is deliberately expensive and is outside the reported copy/upload timings.

Encoded fallback regression also decoded/uploaded all 60 HEVC fixture frames
on NVIDIA with `gl_error=0`.

## Remaining acceptance

Windows was subsequently logged in using the user-authorized credentials via
RDP, then transferred back to the console with tscon. A nonactivating capture
fixture and the native WGC producer emitted 16 codec-3 references; after the
producer exited, the Linux reader materialized the four retained newest frames
(2560x1792, two tiles, 2,080,476 nonzero-alpha pixels per frame). Earlier slots
were overwritten as designed. This validates real WGC capture into shared RAM;
it is not an exact-pixel fixture assertion or a native presentation test.
See `live-capture.log`. The temporary interactive scheduled task was removed.

The subsequently deployed normal session presented five real Windows
application windows through WGC → IVSHMEM → NVIDIA → native Wayland proxies.
Compositor client readback confirmed all five mapped, visible, on workspace 5;
a local compositor screenshot confirmed rendered Windows application content.
The screenshot remains a local build artifact because it contains desktop data.
End-to-end latency, sustained dynamic 6K60, and physical mouse/keyboard
interaction remain **not yet accepted**. No synthetic input or
focus changes were used. Offscreen transport/rendering results are not
capture-to-photon measurements, and stage percentiles must not be added to
claim an end-to-end percentile.

Rollback: restore the two backed-up peer configs and reconnect through their
normal launchers. The original native executables were not overwritten.
Removing the new service drop-in and tmpfiles entry restores the VM's original
configuration on its next cold start; do not truncate/remove shared RAM while
the VM or a reader is using it. Removing the guest's IVSHMEM driver is optional
when the device is removed.


## Normal session and recovery follow-up

The enabled Linux user service is `viewflow-ivshmem-windows.service`; the
Windows interactive logon task is `Viewflow-Windows-Linux-IVSHMEM`. Both have
supervision. The launcher resolves the live Hyprland environment instead of
using the obsolete inherited signature. The source captures physical
`0,0–6144,3456`, with Linux origin `0,0` and scale `2`.

The actual five-window atlas reached 7168×3328 BGRA, within the 512 MiB
mapping's slot capacity. Initial source/reader startup briefly selected HEVC,
then switched to raw IVSHMEM when the receiver became ready. Subsequent
reconnections selected raw directly. The renderer is the host NVIDIA GPU.

An intentional SIGKILL of only the owned Linux native receiver at 16:09:12
was recovered by the existing paired bridge at 16:09:13. The peer remained
alive, shared-memory ownership was recovered, and all five proxies returned.
One recovery-first draw took 38.218 ms; later five-second local draw submission
p95 samples were roughly 10–17 ms. These are per-window host draw→EGL-swap
submission measurements on a mostly static desktop, not per-atlas FPS, GPU
completion, input latency or capture-to-photon latency. A 33 ms miss did not
close the stream. Source diagnostics are disabled during normal use.

The follow-up Linux build and all 10 CTests passed. The launcher compiled with
Python; the Windows supervisor passed PowerShell parser validation; the systemd
unit passed `systemd-analyze --user verify`. The Mac route did not need to be
stopped and its configuration remains unchanged.


For a second recovery test the Windows paired peer was forcibly stopped.
Its supervisor launched PID 19864; Linux retained its peer process and
reconnected at 16:11:08 after the existing QUIC idle timeout. All five raw
proxies returned. This path takes approximately 30 seconds, rather than the
one-second native-child recovery. Logs: `normal-session-linux.log` and
`normal-session-windows.log`. No input was injected for either recovery test.
