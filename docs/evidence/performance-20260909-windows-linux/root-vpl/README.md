# Canonical VPL integration and actual installed build

2026-09-09. All 69 local/remote build inputs match the canonical workspace at archival time. Six Windows CTests pass. Intel HEVC automatically selects VPL; failed initialization falls back to Media Foundation. Other devices/codecs retain Media Foundation. No VPL SDK installation is needed: API headers and their MIT license/provenance are vendored, while the existing System32 runtime is loaded dynamically. The current Intel runtime exposes API 2.16.

| Trial | Distinct FPS | Median upper ms | P95 upper ms | Max upper ms |
|---|---:|---:|---:|---:|
| root-vpl-frame-a1 | 39.546 | 79.143 | 80.118 | 146.179 |
| root-vpl-latency-b1 | 40.923 | 68.746 | 85.528 | 102.051 |
| root-vpl-latency-b2 | 41.157 | 77.791 | 78.495 | 144.443 |
| root-vpl-frame-a2 | 41.003 | 68.151 | 84.992 | 151.567 |

All four runs log automatic VPL selection (Intel vendor 32902, forced=0). One color task is in flight at most; every successful submission has pending=0, so the public one/four-frame admission limits are not binding here and do not establish distinct performance benefits. The mode medians/P95 cross between runs. Presentation phase contributes variation; this evidence does not certify a particular decomposition of that variation. Maximum observations above 100 ms are preserved and do not close the connection.

The canonical 20-frame lifecycle/GPU test passes all phases and three live mode changes. The VPL encoder implementation is byte-identical to the candidate used for full-frame synthetic RGB quality checks. Installed SHA256: `875E56F9E746B5DAEA37814DC67C54495A9B313CD6F0EB6B2652A59F057F42FE`. See [installation and rollback](../vpl-deployment/README.md). The 60 ms target remains unmet.
