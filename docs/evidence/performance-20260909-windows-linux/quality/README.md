# Matched 6K grid quality comparison

Compare encoder quality/speed 50 and 0 using the first encoded occurrence of each of 90 common source marker IDs. Each selected frame compares all 21,233,664 RGB pixels against the exact synthetic fixture shader with GPU reduction after the Linux hardware decoder and YCbCr-to-RGB conversion. Opaque alpha is verified separately.

Aggregate RGB PSNR: 41.873890 dB (50), 41.877638 dB (0). Paired per-frame PSNR difference median +0.003129 dB, minimum -0.001412 dB. The measured grid has essentially unchanged error; this is neither lossless output nor evidence of equal quality on natural images, fine text, or other workloads.

An initial speed-0 coverage check counted repeated marker IDs and failed with 95 comparisons for 90 requested markers. The corrected helper records only the first occurrence, producing exactly 90 comparisons. The initial failure remains in `method/speed0-duplicate-coverage.log`; corrected results are in `speed0.log`. The default-50 run had no duplicated selected IDs and already follows the same first-occurrence policy. `source/platform/linux-reverse/quality_probe.cpp` is the corrected implementation; the initial preparation script predates that fix.

See `summary.json`, `method/markers.txt`, both raw GPU logs, and the SHA-256 manifest. These offline quality runs did not overlap full transport timing runs.
