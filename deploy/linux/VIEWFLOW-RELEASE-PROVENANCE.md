# Viewflow Linux Rust release provenance

`generate-viewflow-release-provenance.sh` identifies a Linux release without a
Git commit. It enumerates every regular file under the allowlisted Viewflow
source roots, records relative path, SHA-256, byte size and mode, and binds
that set to `Cargo.toml`, `Cargo.lock`, the exact offline locked release
command, `rustc -Vv`, `cargo -Vv`, and the Rust host triple.

It causally creates the exact `viewflowd` and `viewflow-deployment-marker`
artifacts itself: `--build-dir` must be a fresh, absent directory outside the
source tree, and is used as `CARGO_TARGET_DIR` for the fixed offline locked
release command. The generator creates it with current-UID ownership and exact
mode `0700`. The manifest records cwd, target directory, host/target triple
and release profile. It records both the invoked rustup shim and the active
toolchain compiler/Cargo binary selected by `rustup which`, including path and
SHA-256. Both executables are exact `build-dir/release/...` paths,
are distinct ELF files, and bind SHA/size/mode/device/inode/link-count/GNU build
ID. Cargo artifacts may legitimately have link count greater than one inside the
fresh private target tree; that exact count is recorded and final-rechecked.
Source, unit and drop-in inputs still require link count one. It records the
same identity fields for the unit and Deskflow drop-in.

Use a clean source staging tree: `.git` metadata is excluded, but `target`,
agent metadata and Python bytecode caches are rejected. Nested symlinks and
special files are rejected, and every source directory/mode is recorded. The output directory
must already exist and not be group/world writable. Publication is a hard-link
create-once operation followed by file and parent-directory fsync; existing
outputs are never replaced.

```bash
deploy/linux/generate-viewflow-release-provenance.sh \
  --source-dir /absolute/viewflow-source-stage \
  --build-dir /absolute/fresh-absent-target-dir \
  --unit /absolute/candidates/viewflow-peer.service \
  --dropin /absolute/candidates/deskflow-viewflow.conf \
  --output /absolute/owner-only/viewflow-release-provenance.json

deploy/linux/check-viewflow-release-provenance.sh \
  --manifest /absolute/owner-only/viewflow-release-provenance.json \
  --manifest-sha256 '<printed lowercase sha256>'
```

The checker rejects unknown and duplicate JSON keys, then regenerates the
canonical manifest from the recorded paths using `--verify-existing` (no build,
no overwrite) and compares every byte. Generator and checker each recheck source,
tool and artifact hash/size/build-ID/inode state immediately before success. A pass is
integrity/provenance evidence; it is not runtime or deployment authorization.
