# Full-frame synthetic quality comparison

2026-09-09. The same 68-file candidate runs Media Foundation and VPL with the same waitable 6K fixture. All 957 MFT frames and 1181 VPL frames pass marker, opaque-alpha, NVDEC/CUDA/GLES and dimension checks. Source recordings are local-file runs, separate from full transport measurements.

On 90 common markers, every RGB pixel of each 6144×3456 frame is compared to the exact fixture shader, using the first encoded occurrence. Aggregate PSNR is 41.899489550 dB for MFT and 41.899524890 dB for VPL. This synthetic grid shows essentially equal error; no conclusion about natural images, small text or lossless fidelity is implied. Marker lists, stream hashes, helper source/binary hashes and per-frame results are preserved.
