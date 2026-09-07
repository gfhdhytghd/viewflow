# Windows proxy transitions (2026-09-07)

Set `DWMWA_TRANSITIONS_FORCEDISABLED=TRUE` immediately after creating each
atlas proxy HWND, before any show. This includes reserved/pool proxies.
Failure emits a diagnostic rather than terminating streaming. The setting is
per proxy window. API reference:
https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute

Built Release x64 with MSVC 19.44 and the existing FFmpeg distribution in
`C:\Users\wilf\Viewflow\no-animation-build-20260907`. The isolated source was
copied from the presenter-native-src associated with the currently deployed
binary, with only this transition change applied. Original deployed and
presenter-native-build hashes matched:
`F6DA1B93BCB9D85232D9317AEA762B62E1A156D306E33BA699A1BDA115FFFBDC`.

Five selected native tests passed: desktop layout, frame bindings, decode
identities, stacking, and hidden frameless windows. No input/focus test was run.
Deployed presenter SHA256 (verified against build):
`37EA2B4101180476A25E3F246146AA7E4345D7FF8BC496462C940A6007AD9F64`.
Backup suffix: `.before-no-animation-20260907-170832`.

During restart, the Linux target/release binary had been independently rebuilt
at 17:07:52. The new sender repeatedly rejected the existing receiver's warmup
acceptance. The working source includes a new sparse_patch_version field.
To restore the session without overwriting that build, copied the existing
16:06 compatible binary from `/tmp/viewflow-atlas-growth-target/release/vf-media-peer`
to `/home/wilf/.local/lib/viewflow/desktop/vf-media-peer-compatible-20260907`.
Temporary user-systemd override:
`/run/user/1000/systemd/user/viewflow-desktop.service.d/90-compatible-runtime.conf`.
It replaces ExecStart's peer path only. Remove this override and daemon-reload
when the newer Linux and Windows protocol builds are deployed together. The
override is runtime-only and does not persist across reboot.

Restarted Windows ViewflowMain-Active and Linux viewflow-desktop.service.
Presenter PID 1860 committed frame 120; Linux was active/running with peer
probes continuing. No automated input or focus change was used.

A read-only interactive query found eight proxy HWNDs, but Windows returned
E_INVALIDARG for DwmGetWindowAttribute on this set-only transition attribute.
That query cannot establish the effective value. Its temporary scheduled task
was removed. Actual disappearance of the animation remains user visual
acceptance; successful build/deployment and resumed frames are verified.
