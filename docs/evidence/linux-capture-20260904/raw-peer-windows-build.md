# Raw peer native Windows build

2026-09-04: fresh temporary source staging over SSH to `wilf@172.16.105.70`.
No example execution, service/task/firewall change, or installed-file replacement.

Staging root:
`C:\Users\wilf\AppData\Local\Temp\viewflow-raw-peer-build-20260904-174422-VQD3sI`

Both commands passed natively under Windows using existing offline dependencies:

```text
cargo check --offline --locked -p viewflowd --example raw_window_peer
cargo build --offline --locked -p viewflowd --example raw_window_peer
```

Build output: `source\target\debug\examples\raw_window_peer.exe`, 6802944 bytes.

```text
source.tar SHA256:
eeff1626dd791fa3ea35f697ca5ce19fc950d00db4c4a1150821f4b30150a0c1
raw_window_peer.rs SHA256:
7fc7c13e2b9d83ffa75fbcf2be9268a2889b98a6c7e85e16a0115c3b8ee37ed9
raw_window_peer.exe SHA256:
a5962e496122061ad243f0bbca191e2134d054300085700569b40b74528467e0
```

The same example passed its two staged-file unit tests on Linux. Both existing
QUIC media integration tests also passed. This is build/test evidence only;
interactive-session native receive and real cross-host transmission remain
unverified. The binary is a debug diagnostic, not a release or performance build.
