# Installed canonical reverse performance build

2026-09-09. The 39 source files match the canonical workspace and the Windows stage. All six CTests pass. Relative to the initial integration, a copy/metadata resize race retries the frame while preserving the last presented image; the encoder diagnostic VARIANT is initialized. The alpha implementation and exactness probe sources are byte-identical to the initial build that passed the 33-frame GPU probe. This final binary independently passes the full lifecycle/GPU test, including live mode changes.

| Trial | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |
|---|---:|---:|---:|---:|
| root-frame-a1 | 32.947 | 80.156 | 96.916 | 98.424 |
| root-latency-b1 | 31.765 | 91.336 | 94.770 | 111.993 |
| root-latency-b2 | 33.477 | 75.650 | 107.936 | 112.062 |
| root-frame-a2 | 33.509 | 78.406 | 95.391 | 112.417 |

These final full-chain trials use the watched mode file through the real controller, including native polling overhead. The native is identical in all arms, direct/alpha/capture-change routes are verified, and each test restores its previous private setting. The installed Linux native and the measured Linux native have identical SHA256 768f11a5fde4145349349cca3cc869981179981055b1eb25527981a2174488be. Mode distributions overlap; no 60 ms claim is made.

The Windows native SHA256 is E1543F0754BAE0741955EF5FBD178262ED10AFE05E3845060E28AAC4121B93D0. It is now installed at the existing configured path; see ../production-deployment/README.md.
