# Four-bank segmented DMA candidate

This is a deployment candidate, not evidence that production 6K60 or sub-frame latency has been achieved. The four 1 GiB memfds preserve the 16384 × 16384 BGRA virtual capacity and existing CPU bank aliases. Each bank also has sixteen 64 MiB IVSHMEM segment aliases. Only requested segments are enabled through QEMU's managed DMA prefix and imported by D3D12. A 6144 × 3456 frame occupies 81 MiB but currently activates two segments (128 MiB) per used bank; four such banks would activate 512 MiB, not 4 GiB at startup.

## Evidence and remaining checks

The [hardware report](evidence/6k60-20261008/demand-dma-hardware.md) records Windows GPU → sealed memfd → Linux udmabuf → NVIDIA EGL external-texture correctness. The 81 MiB frame crossed a 64 MiB boundary, full GPU-rendered readback had zero mismatches, and only the first 128 MiB became resident. See [Linux result](evidence/6k60-20261008/dma-memfd-6k-linux-limit1g.json) and [GPU probe log](evidence/6k60-20261008/dma-memfd-6k-linux-gpu-limit1g.log). This is scratch-path correctness, not sustained frame-rate or production lifecycle proof. Residency measurements alone do not establish pinning.

`tools/test-qemu-dma-banks-topology.py` runs a private diskless q35 TCG process with CPUs stopped, four CPU aliases, and all 64 DMA functions. It checks exact unique BDFs (00:0a.0 through 00:11.7), zero backend prefixes, zero residency in all four memfds, then issues QMP quit. The installed candidate passed this test. Stopped CPUs mean firmware resource assignment and Windows driver enumeration remain untested. The topology reserves 4 GiB of segment BAR address space in addition to the 4 GiB CPU aliases and other devices; actual guest allocation must be checked after boot.

`tools/test-qemu-dma-banks-launch.py` uses only fake QMP and a fake child. It verifies ABI metadata, independent requests, transient retry, control-file receiver locking, FD transfer, cleanup, and polling. Pending eligible segments use 1 ms polling; idle and retry backoff use 50 ms. These intervals are scheduling choices, never session deadlines.

## Prepare and review

1. Record the current override hash and generate a candidate with `tools/prepare-qemu-dma-banks-config.py --source <override> --expected-sha256 <hash> --output-dir <new-directory> --launcher <installed-banks-launcher.py> --qemu <candidate-qemu>`. The generator only writes the new directory. It preserves an exact source backup and emits a manifest and candidate override.
2. Review the source hash immediately before installation. Preserve `prepare-banks.py` in `ExecStartPre`; it prepares the control layout consumed by the keeper. The generated cleanup targets `/run/viewflow-dma-banks.sock`, replacing the old scratch socket cleanup. It must run only after the previous VM/keeper has stopped.
3. Install the reviewed `tools/qemu-dma-banks-launch.py` to the path selected above. Keep the scratch launcher and QEMU rollback binary available. Confirm the QEMU binary supports `x-viewflow-dma-managed` and `x-viewflow-dma-prefix` and excludes only the explicitly named CPU-only banks from VFIO DMA mapping.
4. Stop the VM through its normal shutdown path, replace the override, reload systemd, and start the service. These steps interrupt the VM and belong to the authorized deployment operator; the generator performs none of them.

## Staged acceptance

First boot with the existing CPU transport. Verify all four CPU aliases and 64 segment devices enumerate correctly in Windows, without driver or firmware resource errors. Confirm the keeper exports four sealed FDs, layout generation and inode identities match the receiver, and all unrequested segment prefixes remain zero. The keeper lock is a separate persistent `.lock` inode; the receiver retains its exclusive control-file lock.

Then enable the candidate D3D12 producer and Linux DMA-BUF path. The producer requests segment masks before importing/writing; the keeper acknowledges only successful QMP mappings. Failed mappings retry locally with backoff. Publication must follow GPU completion, and receiver/snapshot leases must remain held until sampling completes. Retain the previous image when a surface stops transmitting. The current implementation only grows activated segments; no shrinking or reclaim claim is made.

Check first-use growth, steady-state residency, byte correctness, queue/lease retirement and recovery before measuring sustained 6K60. Linux uses external-texture sampling on the tested NVIDIA driver. Fullscreen routing and actual presentation latency require their own measurements. Live mouse/keyboard acceptance remains user-operated.

## Rollback

Shut down the candidate VM normally and wait for its keeper to exit. Restore `source.override.conf` from the generated directory, verify its recorded source hash, reload systemd, and start the previous service. Keep its original scratch launcher and QEMU binary in place. The original `prepare-banks.py` recreates the prior control/bank setup during startup; do not reuse candidate metadata with another generation's memfds. Do not unlink a live keeper's lock or socket. The persistent lock inode may remain after normal exit and is intentionally reused.
