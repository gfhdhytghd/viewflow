# Canonical lifecycle fixes and Windows build

2026-09-09. Canonical source tracks expected capture dimensions and retries only a stuck resized capture after 500 ms, retaining its last texture. It validates HWND ownership and positive geometry before publishing metadata and rechecks ownership after reading the title. This prevents the reproduced closed-handle metadata frame. The 31 build inputs match the canonical workspace at archival time and the Windows stage; all four existing Windows CTests pass. The 21-frame runtime regression uses the separate integrated candidate with the same lifecycle fix, not this canonical binary. Performance features and reverse modes have not yet been integrated into this build. The installed reverse binary is unchanged.

Source, methods and raw observations are retained beside this report. `sha256.json` covers all archived files except itself.
