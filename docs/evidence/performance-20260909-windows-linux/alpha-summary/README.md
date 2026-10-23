# Rejected initial compute alpha summary

2026-09-09. The initial compact-alpha candidate has a local HRESULT macro that shadows its input variable. MSVC warning C4700 exposed the invalid check; the exact-alpha probe failed before qualification. The first PowerShell wrapper failure is retained separately from the subsequent native probe failure. This candidate was never installed. See ../alpha-summary-fixed/README.md for the corrected implementation.

The 37 build-input files are archived under `source/`; local and remote SHA-256 maps agree. Build logs and actual probe status are retained in `method/`.
