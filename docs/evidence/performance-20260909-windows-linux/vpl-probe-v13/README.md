# CBR, constant QP and ordinary P-frame timing

The corrected same-binary probe sizes output bitstreams from GetVideoParam BufferSizeInKB multiplied by the effective BRCParamMultiplier, with a 16 MiB minimum. The CQP allocation is 31,850,000 bytes; that capacity is not the actual compressed frame size. All four configurations accept their requested rate method, QP values where applicable, and GPB setting. The logged QPI/QPP/QPB fields alias bitrate fields in CBR and are not QP values there.

| Trial | Rate / P structure | Median ms | P95 ms | Encoded bytes |
|---|---|---:|---:|---:|
| cbr-a1 | CBR / GPB | 17.986 | 18.376 | 5351185 |
| gpb-off-b1 | CBR / regular P | 18.077 | 23.916 | 5441710 |
| cqp-c1 | CQP 26 / GPB | 18.026 | 22.890 | 1565250 |
| cqp-gpb-off-d1 | CQP 26 / regular P | 17.965 | 25.874 | 1565639 |
| cqp-gpb-off-d2 | CQP 26 / regular P | 18.042 | 26.027 | 1565639 |
| cqp-c2 | CQP 26 / GPB | 17.734 | 26.205 | 1565250 |
| gpb-off-b2 | CBR / regular P | 18.108 | 23.935 | 5441710 |
| cbr-a2 | CBR / GPB | 18.069 | 26.000 | 5351185 |

All eight streams contain 120 frames and pass NVDEC/CUDA/GLES at 6144×3456. Each repeated configuration produces the same bytes; different configurations are not claimed pixel- or quality-equivalent. Medians remain about 18 ms, so neither fixed QP nor ordinary P pictures establishes a useful speed improvement. The CBR controls match the earlier external-allocation baseline bitstream. These settings are rejected for deployment, without changing the current bitrate policy.

26 local/remote source inputs match; the actual native and decoder identities are recorded. All probes exit normally, no probe process remains and the installed C914 executable is unchanged. This is an isolated conversion/encode probe, excluding WGC, QUIC and live desktop presentation. [Initial capacity failure](../vpl-probe-v12/README.md) and [primary API references](method/references.md) are retained.
