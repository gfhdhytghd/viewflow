# Windows move/resize recovery wait fix — 2026-09-09

User reported Win+drag snapping back and Win+Shift+drag resize failing after the control queue change. The next captured receiver failure was `atlas clock worker ended: deadline has elapsed`, with a control send delayed by 9.28 seconds and a native disposition timeout. These logs alone do not prove the root cause of every failed gesture.

A concrete recovery dependency defect was found: `AtlasInputRecoveryFence::arm()` waited on the media gate while the gate also covered waiting for a not-yet-admitted frame. Recovery could therefore wait for idle media while preview controls accumulated. Arming now wakes the media receive wait. Interruption occurs only around the next transport receive, preserving the owned partial reliable read. Disposition writes and already-admitted native submissions run to completion. The existing media loop handles the fence by serving recovery requests.

Added native gesture boundary, queued wait state, send and ACK diagnostics. No physical input or focus was synthesized. Source timing logging was enabled for the restarted Linux service process through its manager environment; it is not a persistent configuration change.

Validation: 174 atlas-related Rust tests passed, including a paired QUIC idle-fence/resume regression and the admitted-forward ownership test. After the additional queue-state diagnostics, 15 preview tests passed. Windows release build and receive configuration validation passed. The deployed receiver hash and running process paths are recorded in installed.json and runtime.json. Presenter remains the separately deployed modal-timer fix.

The connection was restored and frames were committed after deployment. Actual Win+drag and Win+Shift+drag behavior still requires user-operated acceptance; source geometry changes were not claimed as verified.
