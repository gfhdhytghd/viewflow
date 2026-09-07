# Windows native proxy submission check

On 2026-09-04, the native proxy source was built offline on
`wilf@172.16.105.70` using its Windows MSVC Rust toolchain. The independent
probe was run in interactive user Session 1 by a temporary scheduled task.

Successful second run:

- Process 9180, exit code 0, scheduled task result 0.
- HWND creation and three `UpdateLayeredWindow` submissions succeeded.
- Submitted sizes: 180×120, 240×140, 180×120.
- Positions: (80,80), (120,100), (80,80).
- Buffers contained transparent, half-transparent, and opaque premultiplied pixels.
- The probe dropped its window/resources and exited. A subsequent process
  census found no `proxy_smoke.exe`. Both temporary probe tasks were removed.
- Existing Viewflow process 27480 remained running. Deployment services and
  the operation-902 quarantine marker were not changed by this check.

`native-report.jsonl` and `outcome.json` are downloaded original second-run
outputs. They establish native API success, **not** visual verification,
compositor presentation timestamps, hardware decode, blur, or two-frame latency.

Build provenance:

```text
native source SHA256:
e7a31ceb4cf91163af7f726e75fbdc6478f7b214dd098df70a8ae9a40a5c9538
probe example SHA256 at build:
fdd78d423f330c00c8110fa7402415979fd122a37fc766f3659095eb3e9dac35
source archive SHA256:
55dbb4f1fa0ed172cf792556f98c78299a3cd1f5a95473f59db7f5b99384719e
proxy_smoke.exe SHA256:
35495a730655d9d3b96795a3d5dbf56c7d8a04cf73674c24e974dac4786c1c94
```

The first run also wrote three submissions and a completion record, but its
PowerShell wrapper obtained a null exit code. The wrapper was corrected to
open the child process handle before waiting. The second run used the same
hashed executable and new output paths. Neither first-run evidence nor the
binary was overwritten. The example subsequently gained a `cfg(windows)` on
its explicit drop to satisfy Linux-only linting; native proxy source is unchanged.

Remote artifacts are retained in these exact temporary directories:

```text
C:\Users\wilf\AppData\Local\Temp\viewflow-native-proxy-jPVZOB
C:\Users\wilf\AppData\Local\Temp\viewflow-native-proxy-jPVZOB-r2
```

The first contains the hashed source archive, build tree, and original outputs;
the second contains the copied binary and successful outputs. There is no
background task or persistent service associated with these directories.
