# CPU-only IVSHMEM with VFIO

The Viewflow transport reads a D3D staging texture on the CPU and copies it
into IVSHMEM. The passed-through GPU never DMA-accesses the shared frame
banks. Stock QEMU's VFIO memory listener nevertheless maps RAM-backed PCI BARs
into the device IOMMU, which pins the complete tmpfs backing allocation.
Disabling `prealloc` alone does not provide demand-only physical memory.

`viewflow-cpu-only-ivshmem.patch` applies to QEMU 11.1.1. It excludes explicitly
named `viewflow_cpu_only_*` memory regions from the VFIO listener. Guest CPU
KVM mappings and ordinary guest RAM DMA mappings remain unchanged. These
backends must use `x-use-canonical-path-for-ramblock-id=off`, and must never
be submitted to a device as DMA buffers. This is a private Viewflow integration,
not an upstream QEMU option or a general-purpose DMA optimization.

Build in a separate prefix; do not replace the distro QEMU executable:

```sh
curl -fLO https://download.qemu.org/qemu-11.1.1.tar.xz
tar -xf qemu-11.1.1.tar.xz
cd qemu-11.1.1
patch -p1 < /path/to/viewflow/platform/qemu/viewflow-cpu-only-ivshmem.patch
mkdir build
cd build
../configure --target-list=x86_64-softmmu --disable-docs --disable-werror \
  --disable-tools --disable-guest-agent --disable-slirp --disable-gtk \
  --disable-sdl --disable-vnc --disable-spice --enable-kvm
ninja -j6 qemu-system-x86_64
```

Use `-L /usr/share/qemu` for the existing host firmware. The VM-specific
service override selects this executable; other VMs keep using distro QEMU.

For the Windows signed IVSHMEM driver, use a 1 MiB control BAR and four 1 GiB
pixel BARs, rather than one 8 GiB BAR. `tools/prepare-ivshmem-banks.py` creates
the sparse files and the PCI bank-location descriptor before the VM starts.
It must only run while that VM is stopped. Control PCI bus/device is 0:5;
pixel devices are 0:6 through 0:9. The receiver uses the base path and
`.slot0` through `.slot3`. The publisher resolves banks by PCI location,
not SetupDi enumeration order. Both sides retain support for legacy single
BAR configurations.

Validate after boot with Windows PnP status, `ivshmem-mapped ... banks=4`,
physical file block counts, and the shared frame/GPU probes. A sparse file
size or a successful build alone does not prove demand-only allocation.

## Experimental grow-only GPU DMA banks

`viewflow-demand-dma.patch` also targets QEMU 11.1.1. Apply it alongside the
CPU-only patch when testing a dedicated GPU-accessible scratch bank. It adds
`x-viewflow-dma-managed=on` to memory-backend-file and a runtime QOM property
`x-viewflow-dma-prefix`. It uses QEMU's RamDiscardSource interface and existing
VFIO listeners, initially exposing zero bytes to DMA. Successful growth maps
the additional prefix before acknowledging the QMP request.

The backend ID must start `viewflow_dma_`, and the backend requires
`share=on,reserve=off,prealloc=off`. There is no backing basename requirement:
independent segment backends may share offsets of an existing bank file, or
open an inherited memfd through `/proc/self/fd/N`. The explicit backend ID
continues to distinguish these regions from `viewflow_cpu_only_*`, which the
VFIO listener excludes. The launcher must retain/pass the memfd correctly;
accepting its path does not itself prove DMA or EGL import compatibility.
The capacity and prefix must be 1 MiB aligned. The prefix cannot shrink.
Managed backends explicitly block migration/save-restore because prefix state
has no migration representation yet. Ordinary file backends remain unchanged.

Run the isolated API/lifecycle test before using a candidate binary:

```sh
python3 tools/test-qemu-demand-dma.py --qemu /path/to/candidate/qemu-system-x86_64
```

This test has no guest, VFIO device, or GPU. It does not establish that Windows
can import an entire BAR without touching its unmapped tail. The separate
scratch probe and independent host pixel/residency measurements test that
hardware boundary. Do not rename the existing CPU-only banks or enable the
production DMA capability flag based on this QOM test alone.
