# Skip unchanged capture versions

2026-09-09. The tracker compares capture versions and all tile metadata fields. It commits only accepted submissions; a later capture remains pending. Unchanged scenes receive a periodic one-second refresh and requested keyframes bypass skipping. Neither interval terminates a session. The dedicated tracker test passes. The standalone run decodes all 958 frames with exact opaque alpha and records 32.866 distinct frames/s; this excludes live transport. The subsequent lifecycle probe exposed resize and closed-handle defects, so this prototype was not installed. See ../lifecycle/README.md and ../integrated-candidate/README.md.

Source, methods and raw observations are retained beside this report. `sha256.json` covers all archived files except itself.
