# Dynamic resize candidate verification

2026-09-04. This is build/test evidence, not native visual acceptance.

The reliable control reader now owns partial header/payload progress across
cancelled select polls. Geometry updates are acknowledged after committing the
receiver epoch and logical presentation size; old-epoch media is rejected.

Local verification:
- `cargo test --workspace --quiet`: passed, two existing ignored tests.
- `cargo test -p viewflowd --example raw_window_peer --quiet`: nine passed.
- `cargo clippy -p viewflowd --lib -- -D warnings`: passed.
- `cargo fmt --all -- --check`: passed.

Windows native build agent reported an offline locked release build passing
in 32.08 seconds. The previously reported E0499 is resolved.

- Source example SHA-256, also checked locally:
  `ffa7a98dc674cfa2f248dca64981aa152a4c79cd6f0141fc07128a5824fa68c0`
- Source archive SHA-256:
  `ae53d7cb2166199f21be1ca4bd44fb0f397c5258986097e7ca4a30390347b185`
- Windows EXE SHA-256:
  `593ca005513da6bf5e4019c355f2b599887a83c93bbf60a87641d479584906dd`
- EXE size: 3,181,568 bytes.
- EXE path:
  `C:\Users\wilf\AppData\Local\Temp\viewflow-raw-peer-resize-20260904-192609-C4oRua\source\target\release\examples\raw_window_peer.exe`

The build agent did not execute the EXE or change live services. This candidate
has not yet demonstrated corrected DPI, dynamic resize, full decorations,
physical display latency, or cross-machine dragging on the actual desktop.
