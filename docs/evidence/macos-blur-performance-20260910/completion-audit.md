# Completion audit: incomplete, awaiting deferred Mac authorization

| Requirement | Current authoritative evidence | Result |
| --- | --- | --- |
| Mac background blur implementation | Passive masked AppKit backdrop in window_presenter.mm; crop/cache/passive-hit tests in final-validation.log | Implemented and deployed; physical appearance unaccepted, exact Windows shader parity not claimed |
| Mac performance optimization | Final binary SHA a1af12856f5e9d5dde9ea1294ae75b6fe2acc3ea2784b48046df022ff3a5bc83 matches current readback; stage ABBA results, current 60 GPU completions/s, alpha 0.045 ms sample | Verified for measured stages and workload; not end-to-end scanout proof |
| Recovery and lifetime behavior | Twelve capture reconnect probes, QUIC idle test, native codec/mask tests, actual presenter EOF in both modes with zero input | Covered by bounded tests; real gesture acceptance remains user-operated |
| Windows to Mac | Real WGC/native-window fixture decoded; persistent tasks and actual presenter enabled | Network/media path verified; desktop visual/input acceptance pending |
| Mac to Windows | Generated H.264 network/resize validation; exact source app currently reports screen_recording_authorized=false and supervisor permission_required | Incomplete: real Mac capture cannot be accepted yet |
| Three-system preparation | Common leaf identities/CA verified, Mac-to-Linux generated media decoded on NVIDIA, three target-side configuration validations | Prepared; unenabled routes and physical coordinate/input acceptance are explicitly documented |
| Persistent startup | Windows task XML verifies logon triggers, unlimited execution, battery settings and failure retries; Mac RunAtLoad/KeepAlive readback | Configuration verified; no reboot/login was synthesized |

The user explicitly deferred the source app Screen Recording grant and requested
other optimization first. That work continued through receiver/cache/run-loop
optimization and Windows startup correction. The same missing OS authorization
has remained across those goal turns and this final live audit. It is a system
capture requirement, not a new Viewflow authorization restriction. The source app
and waiting supervisor remain installed; the receiving paths remain running.

The complete objective is not achieved. Remaining real Mac capture and physical
desktop acceptance require user action. Repeating generated fixtures or changing
unrelated code would not prove those requirements. No additional permission
request, input injection, focus change, login or reboot was performed.
