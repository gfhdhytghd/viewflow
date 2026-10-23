# Windows → Linux IVSHMEM window frames

Linux KVM host + Windows guest can send the reverse window atlas as exact BGRA
pixels through an `ivshmem-plain` PCI device. This is an opt-in native backend
path; physical network peers continue to use H.264/HEVC. Both native backends
must include this implementation.

The existing authenticated paired QUIC connection still carries window IDs,
geometry, membership, frame references and ordered input. No new listener or
input authorization rule is introduced. Pixel data and alpha stay in shared
RAM; there is no video encoder, decoder, chroma subsampling or alpha compression
on this path. This implementation still performs GPU readback, a guest CPU copy,
a host CPU copy and an OpenGL texture upload: it is **not zero-copy**.

## Data ownership and recovery

* Windows queues D3D11 copies into two staging textures and polls completion
  without blocking Map. It holds matching window metadata until that copy is
  ready. A busy readback queue skips submission, retaining the session.
* Four cache-aligned shared slots use lock-free 64-bit ownership atomics.
  Writers may replace ready slots, but cannot overwrite a slot held by a reader.
  The little-endian SHM1 reference contains slot, producer epoch, sequence and
  dimensions and slot capacity. Differing guest/host mapping sizes cannot be
  used as raw frames. A stale reference is dropped without presenting mismatched pixels.
* Linux copies a claimed slot into a reusable owned buffer, then immediately
  returns the shared slot. It retains only the newest waiting raw frame per
  activity lane. GL/Wayland consumers retain their own pixel ownership.
* BGRA is uploaded directly, with RGB channel swizzling and original alpha.
  Window hit testing and shadow metadata still use the exact alpha plane.
* Windows has one device owner; Linux has one `flock` reader owner. A restarted
  side reclaims only slots abandoned by that side, leaving the opposite side's
  live ownership intact. The ABI requires coherent cached x86-64 RAM.
* A local shared-memory reader-ready flag selects the raw path. Reader attach
  and orderly detach cause a lane-local transition after in-flight work drains.
  Missing Windows driver/device or an atlas exceeding the slot capacity falls
  back to the existing encoded path. Missing Linux mapping keeps encoded
  reception available and reports/skips unavailable raw references. A killed
  reader may leave its readiness flag set until that reader restarts; it does
  not impose a timeout or tear down the paired session.

33 ms remains a measurement target, not a frame authorization or disconnect
boundary. There is no shared-frame age cutoff.

## VM and native configuration

Keep the Linux display GPU bound to its host driver. Pass a separate GPU in an
appropriate IOMMU group exclusively to Windows. On the development machine,
Intel `0000:00:02.0` is already bound to `vfio-pci` in group 0; NVIDIA
`0000:02:00.0` remains on `nvidia` for Linux display/rendering.

Add to the existing QEMU command (a dedicated file per VM/paired window stream):

```text
-object memory-backend-file,id=viewflow_shm,size=512M,mem-path=/dev/shm/viewflow-frames,share=on
-device ivshmem-plain,memdev=viewflow_shm
```

Create the file with the host receiver's ownership and read/write access. Do not
replace or truncate a mapping used by a running VM. QEMU requires a power-of-two
region size. Four slots in 512 MiB accommodate 6144×3456 BGRA atlases; each slot
has `(region_size - 4096) / 4` bytes rounded down to a 64-byte boundary. Oversize
atlases use the encoded fallback.

For Intel IGD passthrough, the guest PCI aperture must fit the IOMMU's address
width. The development machine initially aborted when its new shared BAR was
assigned at `0xe0010000000`; `host-phys-bits=on,host-phys-bits-limit=39` keeps
that address space within the device's range. This limits guest address space,
not CPU clocks. Consult [QEMU's IGD documentation](https://github.com/qemu/qemu/blob/master/docs/igd-assign.txt)
and the machine's actual IOMMU capability before copying that value.

Install a signed virtio-win-compatible IVSHMEM driver in Windows. The development
installation uses the IVSHMEM driver extracted from the official
[Looking Glass stable host package](https://looking-glass.io/downloads), whose
catalog was verified as signed by Microsoft Windows Hardware Compatibility
Publisher. Only the driver was installed, not Looking Glass's host service.
The mapped-device IOCTL ABI is documented by
[virtio-win Public.h](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/ivshmem/Public.h).

Append these native arguments to the existing paired `reverse`/`backend` config:

```json
{"native":"C:\\path\\viewflow_windows_reverse.exe","args":["-6144","-780","0","2676","--ivshmem","0"]}
```

```json
{"native":"/path/viewflow_linux_reverse","args":["3072","390","2","--ivshmem","/dev/shm/viewflow-frames"]}
```

Windows's argument is the driver device index; Linux's is its matching host
backing file. `VIEWFLOW_IVSHMEM` is also supported with those platform-specific
values. Keep existing capture bounds, placement and scale. Do not enable an
unrelated device (for example one owned by Looking Glass).

## Build and noninteractive validation

Build the existing `platform/windows-reverse` and `platform/linux-reverse`
CMake projects. Their CTest suites include `shared_frames`: extent checks,
wire framing, stale references, padded rows, reader/writer ownership,
restart recovery, and concurrent pixel integrity.

`viewflow_shared_probe` is built in both projects. Windows accepts
`WIDTH HEIGHT COUNT [FPS]`, creates a hardware D3D11 BGRA fixture, and sends
only bounded frame references to stdout. Linux accepts the backing-file path,
reads these records from stdin, checks every source pixel, uploads through the
production raw GPU path, and verifies sampled RGB/alpha in an offscreen EGL
surface. Its timings measure host copy and completed GPU upload, **not desktop
capture-to-photon or input latency**. It never injects input or changes focus.
The fixture can also be configured as each side's native backend to exercise
real paired QUIC framing; it exits after COUNT frames, so the existing bridge's
normal native-child recovery is expected in that test.

See [the development-machine evidence](evidence/ivshmem-20261007/report.md).

## Normal session startup on the development host

The deployed Windows→Linux route is separate from the Mac route and the older
bidirectional desktop session. Its capture rectangle is Windows physical
`0,0–6144,3456`; Linux proxies use origin `0,0`, scale `2` on the current
6144×3456 display. This replaces the older parked-display rectangle for this
route: existing Windows applications appear as ordinary Linux proxy windows.
Mouse/keyboard input keeps the existing paired native routing.

* Linux: `viewflow-ivshmem-windows.service` (user service), enabled at login.
  `tools/ivshmem-linux-session.py` discovers the current Hyprland signature and
  Wayland socket before starting the paired peer. Binaries and launcher live
  under `~/.local/lib/viewflow/ivshmem/`; config is
  `~/.config/viewflow/ivshmem/windows.json`.
* Windows: scheduled task `Viewflow-Windows-Linux-IVSHMEM`, interactive user
  `wilf`, triggered at login. `tools/ivshmem-windows-session.ps1` supervises the
  peer and rotates the previous session log. Its deployed wrapper, config,
  binaries and logs are in `C:\Users\wilf\Viewflow\ivshmem-20261007`.
  A logged-in desktop is required; no password or automatic login is stored.
* The paired QUIC listener is guest UDP 44339. It uses the existing pair's
  certificates. The installed firewall rule admits the current host address.
  This deployment uses guest `172.16.105.24` and host `172.16.105.62`; update
  the peer endpoint/firewall if DHCP changes these addresses.
* `journalctl --user -u viewflow-ivshmem-windows.service` shows connection,
  shared-memory transport, renderer, recovery and `ivshmem-present` counters.
  Five-second draw p50/p95 samples measure host draw through EGL submission;
  they exclude capture, shared-memory copy and physical display scanout.
  Swap totals count windows, not atlas frames or display refreshes. Static
  windows intentionally produce few frames. Misses above 33 ms are counted
  and never terminate the session.

Stop this route with `systemctl --user stop viewflow-ivshmem-windows.service`.
Disable that unit to remove Linux autostart. Stop/disable the Windows scheduled
task to remove the source supervisor; a running child may need to be stopped
by its exact `windows-linux.json` command line. Keep the shared backing file
intact while QEMU is running. The original Mac configs are unchanged.
