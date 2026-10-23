# Two-task VPL deployment and rollback

2026-09-09. The canonical Windows source is installed at the original reverse executable path, SHA256 `C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB`. Its 69 local/remote source files match, six Windows CTests pass, four full 6K transport trials qualify, and all 21 lifecycle frames pass GPU decoding, metadata, alpha and ordered drain accounting. Quality comparison of 90 common complete 6K frames has effectively unchanged synthetic RGB error; component equivalence to the canonical encoder is checked in archive-depth-v5.py.

| Mode | Distinct FPS range | Median upper ms | P95 upper ms |
|---|---:|---:|---:|
| frame-rate | 54.169–54.872 | 56.998–62.938 | 63.633–73.623 |
| latency | 40.505–41.922 | 76.410–77.260 | 77.603–77.902 |

The measurements end at Linux nested desktop observation, excluding physical scanout. Maximum upper estimates are 94.688–144.390 ms across the four runs. The 60 ms P95 goal remains unmet. Both public modes are selectable without session restart; fewer pending frames did not reduce measured latency here. Frame-rate remains the default and the restored configured mode.

The previous 875E56F9 binary is backed up in the directory recorded in [install-state.json](method/install-state.json). The earlier E154 backup is retained. The one-shot installer validates both original and staged hashes, atomically replaces the original executable, and has an installation failure rollback branch. To roll back, first ensure the native source is stopped, then restore the backup to the recorded target; source configuration does not need changing. Do not rerun this installer against an already upgraded target.

Installation verifies native status, original receive/mode/config hashes, UI/controller files, services and monitor rectangles, then performs real controller latency/frame-rate round trips and restores the original mode. User/machine backend and depth overrides are read and checked. Windows main task remains Ready; Linux desktop service is inactive and the existing input service remains active. No main paired session was started, and no physical-input or focus injection was used. The next normal start uses this source binary.
