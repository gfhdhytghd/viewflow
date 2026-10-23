# Demand DMA scratch experiment

Candidate QEMU 11.1.1 includes both the existing CPU-only VFIO exclusion and
the experimental RamDiscardSource file backend. Its independent QMP test
passed, including growth, rejection without state changes, object lifecycle,
ordinary-backend compatibility, and migration blocker cleanup. The initial
missing QAPI field failure is retained separately; it was fixed and rebuilt.

The authorized normal Windows shutdown completed before restarting with the
candidate. Four production pixel banks and their CPU-only names were retained.
Only the separate scratch function at 00:0a.0 changed to a managed 1 GiB BAR.
Windows returned with Intel Graphics, VDD, and six IVSHMEM devices reporting
OK. The normal sender and receiver resumed. No user input was injected and no
research process was stopped.

## Observations

| Stage | File page residency | Result |
| --- | ---: | --- |
| Boot, DMA prefix 0 | 0 | No eager whole-bank VFIO population |
| QMP grow to 1 MiB | 1 MiB | Actual VFIO prefix population succeeds |
| Windows import entire 1 GiB heap | 1 GiB | Import succeeds but defeats demand residency |
| Driver map only, after resetting unmapped tail | 1 MiB | Driver mapping alone does not populate tail |
| QMP grow to 81 MiB | 81 MiB | Prefix growth succeeds |
| Protect remaining tail PAGE_NOACCESS | 81 MiB | VirtualProtect fails with Windows error 487 |
| GPU writes 6144 x 3456 BGRA image | 1 GiB | Fence completes, independent host comparison has zero mismatches |

The map-only control was run after the import-only process had released its
heap, D3D device and mapping. To repeat residency observation, only the
unmapped scratch tail beyond the first MiB was hole-punched; the VFIO-mapped
first MiB remained untouched. No production file was discarded.

`dma-demand-6k-host-verification.json` compares all 84,934,656 image bytes.
The guest only initializes the source texture on the CPU, then submits GPU
copies into the external heap; it never CPU-writes or checks destination
pixels. Both D3D devices report S_OK. The host does not read the unused tail.

This establishes actual 6K GPU-to-IVSHMEM transfer correctness with a partial
VFIO mapping. It does **not** satisfy demand physical memory: the complete
heap import still populates the 1 GiB backing. Page residency is not a direct
measurement of pinned pages. There is no sustained-FPS or end-to-end latency
result from this correctness probe.

## Segmented hardware result

Use smaller independently importable BAR segments, backed by disjoint offsets
of one logical bank file. Only enable/import segments needed by the image.
For 64 MiB segments a tight 81 MiB image needs two segments (128 MiB resident).
The GPU copy must split a row that crosses a segment boundary without adding
padding to the existing tight SHM layout.

After another authorized normal shutdown, the scratch device was replaced by
three 64 MiB functions at 00:0a.0/.1/.2. Each backend aliases a different offset
of a new 1 GiB sparse scratch file. All three start with zero DMA prefix.
Windows reports eight IVSHMEM devices OK, including the five unchanged
production devices. Normal transport resumes.

Enabling and importing function 0 leaves residency at exactly 64 MiB. All
other 64 MiB chunks remain nonresident (`dma-segmented-import-hold.json`).
Enabling function 1 permits a complete tight 6K transfer in four copy regions:

- First 2730 rows into segment 0.
- First 4096 pixels of row 2730 into segment 0's final 16 KiB.
- Remaining 2048 pixels of that row into segment 1's initial 8 KiB.
- Last 725 rows into segment 1 at offset 8192.

The GPU fence and device check succeed. The independent host compares all
84,934,656 bytes with zero mismatches (`dma-segmented-6k-host-verification.json`).
Total residency is 128 MiB: first two chunks 64 MiB each, third chunk and all
remaining capacity zero (`dma-segmented-6k-residency.json`). No destination
pixels are initialized or verified by the Windows CPU.

This establishes the tested two-segment demand-memory behavior and cross-host
copy correctness. The complete 64-function/4-bank production topology and
presenter integration are not established by this small scratch experiment.


## Windows GPU to Linux GPU through the same demand-backed memfd

The next authorized normal VM restart replaced only the scratch backing with
one sealed 1 GiB memfd, inherited by QEMU and handed to the user-owned probe
through SCM_RIGHTS. The three 64 MiB PCI aliases remain at 00:0a.0/.1/.2.
Initial residency is zero; enabling and using the first two segments produces
128 MiB residency with all remaining capacity untouched.

The Windows segmented probe copies the 6144 × 3456 test texture and waits for
its GPU fence. The Linux probe exports the same 84,934,656-byte prefix through
udmabuf, imports it with EGL and samples it on the NVIDIA GPU into a local
RGBA framebuffer. Every readback byte matches (zero mismatches). Linux does
not read or initialize the source pixels on the CPU. Evidence:
`dma-memfd-6k-windows.log`, `dma-memfd-6k-linux-limit1g.json`, and
`dma-memfd-6k-linux-gpu-limit1g.log`.

The installed NVIDIA driver advertises linear ARGB8888 as external-only.
GL_TEXTURE_2D binding fails; GL_TEXTURE_EXTERNAL_OES imports and samples
correctly. The initial export attempt also found the kernel udmabuf 64 MiB
export limit; raising size_limit_mb to 1024 permits this 81 MiB export. This
is a limit, not an allocation: measured residency stays 128 MiB and the unused
896 MiB remains nonresident. The setting is persisted through a tmpfiles rule.

This proves cross-GPU pixel correctness and demand-backed memory behavior for
the scratch path. It does not prove sustained 60 fps, end-to-end latency,
scanout, production frame-slot retirement, or automatic fullscreen routing.


The production-candidate `GpuDecoder` import helper subsequently consumed the
same completed Windows scratch frame (`dma-memfd-production-helper.json` and
`.log`). Its own raw texture swizzle/alpha readback matches every byte; a
released caller/AVFrame does not release the shared slot until GPU completion
is polled. Residency is still 128 MiB before and after, with zero tail. This
extends correctness evidence to the actual receiver helper, not sustained
production throughput. The self-owned 4 MiB probe also verifies GL state
restoration around the import/draw.
