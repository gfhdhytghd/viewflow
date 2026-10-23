# Matched full-frame synthetic RGB comparison

2026-09-09. The same 90 common marker IDs are decoded from each of four streams; every one of 21,233,664 RGB pixels per frame is compared with the exact fixture shader using the first encoded occurrence. Aggregate PSNR is 41.871488 dB for mft-speed0, 41.871363 for direct-source-stop, 41.870557 for capture-changes and 41.871362 for alpha-summary-render. All four probes exit normally and validate opaque alpha. This establishes comparable error on this synthetic grid, not lossless output or fidelity on natural images and text. Inputs, helper source/binary hashes, chosen markers and per-frame results are preserved in method/.

Source, methods and raw observations are retained beside this report. `sha256.json` covers all archived files except itself.
