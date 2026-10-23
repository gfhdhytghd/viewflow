# Actual IVSHMEM scratch-device preparation

Read-only QMP inspection found the live Q35 guest's existing IVSHMEM control
device at PCI 00:05.0 and four 1 GiB frame banks at 00:06.0 through 00:09.0.
The 00:0a.0 slot was unused. No existing bank was opened for this experiment.

Attempted to add a separate 16 MiB memory-backend-file object and ivshmem-plain
device at 00:0a.0. Object creation succeeded; device_add returned:

    Bus 'pcie.0' does not support hotplugging

object-del succeeded and the dedicated backing file was removed. Confirmed
the scratch file is absent and viewflow-ivshmem-windows.service remains active.
This is a topology constraint, not a failure of D3D12 heap import.

Prepared, but did not install, a startup configuration candidate under
`build/ivshmem-backup/dma-scratch-boot/`. It adds only the 16 MiB scratch backend
and slot 10 device to the currently installed override. source.json records
the original file hash so installation can detect configuration drift. The
scratch file needs exclusive creation and sizing before starting that candidate.
Actual scratch-device testing requires a guest restart; current document-save
state has not been confirmed. Prior restart approvals do not establish that
newly opened documents are saved.

## Host-side validation prepared

`tools/verify-ivshmem-dma-scratch.py` opens the dedicated backing read-only,
requires a regular 16 MiB file, and compares every byte of the first 1 MiB with
the guest's GPU-copy pattern. It also checks that the remaining 15 MiB is zero.
Use `--expect-zero` before the guest probe on a freshly created backing, retaining
that output alongside the subsequent pattern result. Wait for guest fence and
probe completion before checking; this is not a concurrent-reader test.

Synthetic temporary-file tests passed for zero baseline, absent pattern, exact
pattern, tail corruption, and wrong extent. No live IVSHMEM was used. These tests
validate the checker only; actual cross-host GPU-write evidence remains pending
guest restart confirmation and execution against the separate device.

## Before-import backing residency observation

`tools/ivshmem-residency.py` observes owner-controlled regular backing files with
read-only mmap/mincore; it does not read or populate pixel pages. A temporary
three-page tmpfs check confirmed zero resident pages stayed zero across repeated
observations, and writing one page changed the observed count to exactly one.

`ivshmem-residency-before-dma.json` records the current four production bank
inodes, each with a 1 GiB virtual extent. Their resident file pages total
551,362,560 bytes (about 526 MiB) before any production DMA import. This is a
point-in-time observation during normal operation, not a fixed working-set limit.
The tool measures file page residency, not GPU pin counts or process RSS. Paired
observations around an isolated actual import are still needed to determine
whether importing a maximum-sized bank eagerly populates its full extent.

## Authorized restart and actual DMA result

After the user explicitly authorized restart, the current override hash matched
the prepared candidate's source hash. The original override was backed up as
`build/ivshmem-backup/dma-scratch-boot/90-viewflow-ivshmem.conf.before-restart`.
A dedicated owner-only 16 MiB backing was created exclusively and its zero
baseline verified (`dma-scratch-zero.json`). The candidate was installed, Windows
was shut down normally with shutdown.exe /s /t 0, and the service reached
inactive/dead before being started. No forced QEMU termination was used.

Windows returned with Intel Graphics and six IVSHMEM devices reporting OK.
The normal Windows scheduled sender and Linux service resumed; Linux logs
reported the paired connection and raw IVSHMEM transport. No research process
was stopped and no input/focus test was injected.

`--test-ivshmem-copy 0 10 16777216` mapped exactly the dedicated device with WC
cache policy (2). Both enumerated Intel adapters imported the actual heap,
created the placed buffer, completed a GPU copy of 1 MiB, and reported zero
byte mismatches and S_OK device checks. Evidence:
`d12-actual-ivshmem-windows.log`. After the probe exited, the independent Linux
checker verified every payload byte and an untouched zero 15 MiB tail, with zero
mismatches (`dma-scratch-host-result.json`). This is actual cross-host GPU-write
evidence, not private RAM. It does not validate production cached mappings (1),
6K frame publication, maximum-bank residency, sustained FPS or presentation
latency. The production D12 switch remains off.

## Production cache-policy check

Added explicit `--test-ivshmem-cached-copy` (cache policy 1) alongside the existing
WC scratch mode. After verifying the prior guest probe had exited, only the
dedicated scratch file was reset and its zero baseline checked. The rebuilt
probe imported that actual cached mapping and copied the same 1 MiB GPU pattern
successfully on both enumerated Intel adapters. Linux independently verified
zero mismatches and an unchanged zero tail. Evidence: `dma-cached-zero.json`,
`d12-cached-ivshmem-windows.log`, `dma-cached-host-result.json`.
This establishes cached-mapping support at the tested 16 MiB extent, not the
residency or performance of the 1 GiB production banks.
