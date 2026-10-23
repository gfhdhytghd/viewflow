# Encoder queue-depth comparison

2026-09-09. All four successful trials use one 39-file native build and retain direct submission, render alpha summary and capture-change skipping. The order is B/A/A/B. The initial depth-4 launcher failed its cloned 0/1 argument validation before any Windows task or peer started; its method, failure and completed nested cleanup are preserved under transport/runs/queue-4-a1.

| Trial | Distinct FPS | Median upper ms | P95 upper ms | Maximum upper ms |
|---|---:|---:|---:|---:|
| queue-1-b1 | 32.212 | 75.987 | 95.449 | 110.032 |
| queue-4-a1r | 33.621 | 82.553 | 99.276 | 100.395 |
| queue-4-a2 | 31.972 | 76.993 | 94.789 | 176.600 |
| queue-1-b2 | 32.417 | 81.919 | 98.563 | 164.950 |

Every logged successful submission has pending=0 even with a configured limit of four. The encoder input-ready event already serializes this workload. Thus these samples do not establish a throughput or latency benefit from changing the pending limit. Modes still define different admission bounds; neither is represented as a guaranteed faster result. Source/remote input hashes match and the tracker CTest passes.
