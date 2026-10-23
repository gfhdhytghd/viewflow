# Canonical capture lifetime cleanup build

2026-09-09. The root App destructor now stops each capture while the source map retains strong references. This closes a teardown lifetime hazard found by inspection; it is not proof of the cause of the earlier 0xC0000409. This historical canonical 31-file snapshot built and passed all four Windows CTests. An earlier concurrent staging attempt received another candidate archive and was rejected by source hashes before build or execution; the retry uses a unique temporary archive. No installed reverse binary was replaced.

The 31 build-input files are archived under `source/`; local and remote SHA-256 maps agree. Build logs and actual probe status are retained in `method/`.
