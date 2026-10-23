# Demand-sized DMA mapping for the Looking Glass transport path

Status: the single-1-GiB-BAR demand-residency candidate failed its hardware
acceptance condition. The QEMU prefix mechanism works, and actual 6K GPU writes
were correct, but importing the entire BAR as a D3D12 heap populated the entire
1 GiB backing. The revised candidate below uses independently importable
64 MiB BAR segments. Segment hardware validation is still pending.

## Hardware outcome and revised candidate

The authoritative run record is
[Demand DMA scratch experiment](evidence/6k60-20261008/demand-dma-hardware.md).
Its distinct observations must not be collapsed into a single pass:

- QEMU prefix 0 left the scratch file nonresident; growing to 1 MiB populated
  only 1 MiB. Windows driver map-only also left residency at 1 MiB.
- Importing the entire mapped BAR with `OpenExistingHeapFromAddress()` succeeded
  but made the complete 1 GiB resident. The D3D12 import, rather than the driver
  mapping alone, defeats this candidate's demand-residency requirement.
- Attempting `VirtualProtect(..., PAGE_NOACCESS)` on the unused tail failed
  with Windows error 487. Protection splitting is not an available solution
  in this tested configuration.
- The actual 6144 × 3456 GPU copy completed and independent Linux verification
  compared all 84,934,656 bytes with zero mismatches. Residency was nevertheless
  1 GiB: transfer correctness passed; dynamic-capacity acceptance did not.

These are scratch correctness/residency observations, not pin-count, sustained
60 fps, or end-to-end latency measurements.

The next experiment uses **three 64 MiB IVSHMEM functions** backed by distinct
offsets in the same separate 1 GiB scratch file. Enable/import the first two
segments for the 81 MiB image; leave the third at prefix 0 and unimported as a
residency control. No result for this experiment is claimed here. Its new GPU
probe must preserve the tightly packed image across the 64 MiB boundary,
including a row that crosses that boundary; it must not insert row padding.

If this succeeds, retain the four existing CPU-only 1 GiB production banks for
compatibility and add independently importable segment views of their backing
files. The logical 16K/1 GiB-per-bank limit remains unchanged; the active 6K
allocation becomes 128 MiB per bank (512 MiB for four active banks), rather than
the single-BAR design's intended 81 MiB. That is a candidate 64 MiB growth
granularity, not a claim that the original finer residency target was met.

Each segment needs its own file-backend object: `ivshmem-plain` rejects reusing
an already mapped memdev. Distinct objects can use the same shared file with
different `offset` values. Generic PCI multifunction support can group eight
functions per slot, with function 0 marked multifunction; final 64-function
enumeration and PCI resource allocation remain unverified. See
[QEMU IVSHMEM](https://github.com/qemu/qemu/blob/v11.1.1/hw/misc/ivshmem-pci.c),
[file-backend offsets](https://github.com/qemu/qemu/blob/v11.1.1/backends/hostmem-file.c),
and [PCI multifunction handling](https://github.com/qemu/qemu/blob/v11.1.1/hw/pci/pci.c).

## Requirement and preferred approach

Keep four fixed virtual pixel banks, each with a maximum of 16384 × 16384 × 4
bytes (1 GiB), and a separate control region. Do not initially pin or populate
the entire 4 GiB aperture. Enable host IOMMU mappings only for the pixel extent
actually required, rounded to a fixed mapping granularity.

Prefer a QEMU file-backed bank implementing **RamDiscardSource**, attached to
the existing **RamDiscardManager** machinery. Expose a narrow host-side command
for increasing the populated prefix. Reuse QEMU's VFIO discard listener to
perform mappings instead of implementing another QMP interface that directly
issues arbitrary VFIO map/unmap operations.

This is a design inference from the existing QEMU interfaces, not a claim that
stock QEMU already provides a configurable IVSHMEM prefix backend. The backend,
command, lifecycle handling, and Viewflow handshake still need implementation.

The first iteration should grow only. Shrinking is not required by the user's
request for demand growth and introduces additional GPU, reader, and backing
storage lifetime requirements.

## QEMU integration APIs

The reference version is QEMU v11.1.1. Its interfaces differ from older examples
that implement a RamDiscardManager class directly:

- Implement `RamDiscardSourceClass::get_min_granularity` and `is_populated`.
- Attach the source with
  `memory_region_add_ram_discard_source(&backend->mr, source)` before exposing
  the bank in the guest address space.
- Obtain its manager with `memory_region_get_ram_discard_manager()`.
- Grow with
  `ram_discard_manager_notify_populate(rdm, source, old_prefix, delta)`.
  Notify listeners before committing the new source state. The manager excludes
  the notifying source from its population check and rolls back notified
  listeners if population fails.
- Keep the source and backing alive while any listener or bank mapping can
  reference them. Device teardown must remove mappings before removing the
  source; deleting the last source while listeners remain can make previously
  discarded ranges appear populated.

See the primary [RamDiscardSource/manager declarations](https://github.com/qemu/qemu/blob/v11.1.1/include/system/ram-discard-manager.h),
[manager implementation](https://github.com/qemu/qemu/blob/v11.1.1/system/ram-discard-manager.c),
and [memory-region source attachment](https://github.com/qemu/qemu/blob/v11.1.1/system/memory.c).

In `hw/vfio/listener.c`, `vfio_container_region_add()` checks for a discard
manager before its ordinary whole-region DMA map. The discard listener maps
populated chunks using `vfio_container_dma_map()`, translating region offsets
into the actual address-space IOVA. Registration replays populated ranges;
discard notifications call `vfio_container_dma_unmap()`. This also avoids
assuming that a bank's PCI BAR address remains constant.
See the [VFIO listener implementation](https://github.com/qemu/qemu/blob/v11.1.1/hw/vfio/listener.c).

The existing Viewflow patch skips every `viewflow_cpu_only_*` region before
these branches. Such a name must not be used unchanged for the new DMA backend:
use an explicit new backend identity, or adjust the skip condition to permit
the managed backend. Simply attaching a source behind the unconditional skip
would leave GPU DMA unavailable.

## Granularity and capacity

For the RDM mapping layer, use **1 MiB** granularity, contingent on verifying the actual VFIO
container's minimum supported IOMMU page size and the BAR/region alignment.
The granularity must be a power of two and at least that minimum. If the
container requires a larger granularity, select a compatible value before
registering listeners; do not change it underneath existing mappings.

| Frame | Pixel bytes | 1 MiB prefix per bank | Four banks |
| --- | ---: | ---: | ---: |
| 6144 × 3456 BGRA | 84,934,656 = 81 MiB | 81 MiB | 324 MiB |
| 16384 × 16384 BGRA | 1 GiB | 1 GiB | 4 GiB |

At 2 MiB granularity, the 6K prefix becomes 82 MiB per bank, or 328 MiB for four
banks. A 1 MiB granularity creates at most 4096 mappings across four full banks;
verify the container's mapping limit rather than assuming this budget is free.
These numbers describe pixel-prefix mappings, not total process/GPU memory.
Control pages, capture textures, snapshots, driver allocations, and staging or
registration overhead remain additional resources. The table is the original
single-BAR prefix calculation, not its achieved residency: the hardware result
above invalidated that expectation after D3D12 import. With 64 MiB segments,
the mapping layer can still use 1 MiB units, but an imported segment must have
its full 64 MiB enabled and its full residency budget accounted for.

Map only a bank that is actually needed. Reserving virtual capacity and mapping
all four maximum-sized banks are distinct operations.

## Growth handshake

1. Calculate the destination's actual D3D12 allocation/footprint extent and
   round it to the selected mapping granularity. Verify it fits the bank.
   Existing SHM1 consumers require tightly packed BGRA; a padded row pitch
   cannot silently be published as that layout.
2. Stop new submissions to the affected bank and drain its outstanding Windows
   GPU work. Preserve all source and destination leases until completion.
   Coordinate Linux reader/upload leases before any operation that could
   replace mappings, registrations, resources, or backing storage.
3. The host issues a bank-specific growth request with the expected mapping
   generation and desired prefix. Validate bounds and generation in QEMU's
   normal serialized control context. Do not accept arbitrary process pointers
   or caller-supplied IOVA mappings.
4. QEMU notifies population for the new suffix. On failure, leave the previous
   prefix and generation authoritative; the failed larger frame can recover
   locally while the existing stream and last snapshot remain available.
5. After success, commit the prefix and generation and return an acknowledgement.
   Windows may only submit a destination requiring the new extent after that
   acknowledgement. Associate the acknowledgement with the same bank generation
   used by the submission.
6. Publish frame metadata only after its GPU completion fence. Hold the writer
   reservation through completion and preserve the existing reader-release
   ownership rules. Prefix-map acknowledgement is not frame completion.

Growth is a resize operation, not a per-frame operation. An unchanged frame
extent should incur neither QMP traffic nor VFIO mapping churn.

## CPU access, discard, and lifetime limitations

RamDiscardManager does **not** block guest CPU accesses to the unpopulated tail.
KVM can keep the entire BAR mapped; touching its tail can still fault pages in.
The guest and host must avoid clearing, scanning, or registering the entire
maximum aperture. This is especially important when importing a D3D12 heap:
`OpenExistingHeapFromAddress()` describes a whole mapped region, not a caller
selected prefix. Whether the current driver imports or touches pages beyond
the populated prefix was initially unknown. The referenced hardware experiment
now confirms that importing this configuration's full 1 GiB BAR populates the
whole backing, so prefix-only VFIO mapping is insufficient by itself.
See [Microsoft's external-heap API](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12device3-openexistingheapfromaddress).

TYPE1/TYPE1v2 VFIO permits coordinated discard while disabling uncoordinated
discard; the iommufd path has corresponding coordination support. KVM disables
discard when `KVM_CAP_SYNC_MMU` is unavailable. Verify these capabilities rather
than overriding the discard protection flags. Sources:
[legacy VFIO container](https://github.com/qemu/qemu/blob/v11.1.1/hw/vfio/container-legacy.c),
[iommufd container](https://github.com/qemu/qemu/blob/v11.1.1/hw/vfio/iommufd.c),
[KVM implementation](https://github.com/qemu/qemu/blob/v11.1.1/accel/kvm/kvm-all.c).

If shrink is added later, it must first exclude all GPU writes, Linux uploads,
retained reader leases, and any snapshot still backed by the affected memory.
Releasing a VFIO mapping alone does not free pages retained by another GPU
registration. Physical backing discard must also be coordinated; punching a
hole in a live shared frame is not a valid reclamation mechanism. The
[virtio-mem implementation](https://github.com/qemu/qemu/blob/v11.1.1/hw/virtio/virtio-mem.c)
provides an existing example of successful backing discard followed by listener
notification. No shrink implementation is proposed for the first iteration.

## Why not start with vIOMMU or manual VFIO maps

`intel-iommu,caching-mode=on` synchronizes guest IOMMU mappings with assigned
devices, but it does not itself guarantee demand-sized GPU heap mappings.
Windows and its display driver must actually use the corresponding WDDM DMA
remapping functionality. A guest could still map the entire imported heap.
Changing this topology is therefore a separate experiment, not a verified fix.
See [QEMU VT-d options](https://www.qemu.org/docs/master/system/invocation.html)
and [Microsoft GPU DMA remapping](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iommu-dma-remapping).

A manual QMP map implementation would have to duplicate container/address-space
lifetime handling, BAR relocation, alignment, rollback, dirty tracking, and
mapping accounting. TYPE1v2 unmap requests cannot bisect an earlier mapping;
the existing discard listener's granular mapping already addresses this
constraint. See the [Linux VFIO implementation](https://github.com/torvalds/linux/blob/master/drivers/vfio/vfio_iommu_type1.c).

## Linux receiver and KVMFR

The existing CUDA upload receiver can remain for the first Windows direct-write
integration test, provided its registrations also cover only the active extent
and retain their leases until GPU completion. That test would establish the
producer-side improvement, not completion of the Looking Glass-style DMA-BUF
receiver path.

Looking Glass's static KVMFR device allocates its configured size with
`vmalloc_user()`. Configuring it for the full four-bank maximum is therefore
incompatible with the requirement to avoid allocating the maximum at startup.
Its DMA-BUF export does not turn that initial allocation into demand-sized
backing. Reference: [KVMFR allocation and export implementation](https://github.com/gnif/LookingGlass/blob/cdba29f2f6bcae3ded26369fc231a067cbca3752/module/kvmfr.c).

The final Linux DMA-BUF path needs compatible dynamic backing as well.
Shared memfd plus udmabuf is a candidate to investigate, not a verified solution:
QEMU backing compatibility, sealing, subrange export, NVIDIA EGL import,
residency, and release synchronization all require validation. See the primary
[udmabuf implementation](https://github.com/torvalds/linux/blob/master/drivers/dma-buf/udmabuf.c).

## Required experiment before production use

The dedicated single-BAR scratch test described above has completed and failed
the demand-residency condition. Continue with the three-segment experiment,
not another claim that a small placed buffer limits a whole imported heap.
Measure residency before and after importing each active segment and confirm
the third control segment remains nonresident. Independently compare the full
81 MiB GPU-written image, especially pixels around the 64 MiB boundary. Later
receiver registration must also be measured; it must not repopulate the unused
tail through another GPU API. Verify failed growth preserves the old mapping
and BAR/listener recreation replays the committed prefix. Keep all desktop
input and focus user-operated, and leave production-owned banks untouched.

No result from a fully mapped 16 MiB scratch BAR, ordinary private RAM, build,
or source inspection proves these demand-mapped 1 GiB conditions. Hardware
acceptance and the overall 6K60/16.7 ms latency target remain unproven here.
