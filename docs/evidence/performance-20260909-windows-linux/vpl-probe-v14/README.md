# Video processor automatic processing switch

The same binary reads the actual default automatic-processing flag as TRUE, compares default/disabled/disabled/default, and reads FALSE back for both disabled runs. All other conversion and encoding settings are unchanged.

| Trial | Auto processing | Total median ms | Total P95 ms | Conversion interval median ms |
|---|---:|---:|---:|---:|
| auto-a1 | 1 | 18.130 | 21.437 | 3.874 |
| disabled-b1 | 0 | 18.095 | 25.962 | 3.879 |
| disabled-b2 | 0 | 18.032 | 25.927 | 3.855 |
| auto-a2 | 1 | 18.026 | 26.046 | 3.864 |

The four 120-frame 6K HEVC outputs are byte-identical and pass NVDEC/CUDA/GLES. Disabling the flag establishes no useful speed improvement on this hardware; it is not adopted. A TRUE API flag does not establish that extra enhancement work was actually executed.

26 source inputs match their remote hashes. Build, actual binary identity, normal process exit and the unchanged installed C914 source are recorded. GPU query intervals can include scheduling and dependencies, and this isolated probe excludes WGC, networking, live desktop presentation and physical scanout. [API reference](method/references.md).
