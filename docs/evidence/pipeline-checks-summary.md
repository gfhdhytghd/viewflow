# Pipeline fallback checks (2026-10-29 UTC)

Starting commit: `9acc768b`. All commands below ran in the `pipeline` worktree.
The task permits a disabled fallback; these checks do not prove an active media
pipeline. No input injection, desktop capture or focus manipulation was used.

| Command | Exit | Result | Raw output |
|---|---|---|---|
| `cargo test --workspace` | 0 | 990 passed, 4 ignored; zero failures | 原始日志未入库 |
| `cargo test -p viewflowd --features native-gpu-nvenc` | 0 | 751 passed, 16 ignored; zero failures | 原始日志未入库 |
| `cargo clippy --workspace --all-targets -- -D clippy::unwrap_used` | 0 | Passed; existing warnings remain; no warnings in new core window or new handshake tests | 原始日志未入库 |
| `cargo test -p viewflowd pipeline_` | 0 | 4 passed, including 2 new real QUIC handshake tests and 2 existing mock native activity tests | 原始日志未入库 |
| `python -m py_compile tools/weak-network-test.py` | 0 | Python syntax passed | launcher |
| Mocked measurement-guard smoke check | 0 | Own launcher/shell ignored; lower-PID launcher and actual tests wait 60s; higher-PID waiting launchers defer; pgrep failure stops launch | [guard](pipeline-checks-tools.txt) |
| `git diff --check` | 0 | Passed | final local check |

The workspace run includes the eight new fixed-window tests (bounds 1/2/3,
reordered completions with ordered retirement, middle loss, transitive color /
alpha / patch loss, independent recovery, pinned alpha identity, generation /
geometry / same-generation fence resets, dual lanes and stale callbacks).
The targeted log predates a test-only cast-to-checked-conversion cleanup; final
workspace/native checks cover all executable Rust changes. Final Clippy also
covers the doc-comment backtick cleanup described in `pipeline-readiness.md`.

The sixteen ignored native-feature tests were not enabled wholesale. Real
capture/input remains user-operated. Only the explicitly owned NVENC netem
experiment is run with `--ignored` by the harness.

Generated `pipeline-*.txt` logs retain tool output verbatim, including trailing
spaces from Clippy suggestions and `tc`. The evidence-local `.gitattributes`
exempts only those generated logs from whitespace lint; source and Markdown
checks remain enabled.
