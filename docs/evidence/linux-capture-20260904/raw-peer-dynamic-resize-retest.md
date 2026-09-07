# First dynamic-resize-candidate native retest

2026-09-04. One static decorated frame was attempted; no live capture/plugin
reload was involved. Source physical dimensions were 564x262 and the sender
explicitly negotiated logical 282x131. This does not exercise dynamic resizing.

Linux release SHA-256:
`80ccd2657a7a9d00888c307fbee1e892fdd9c55184978ecbc8d50b10ced9352c`

Windows release SHA-256:
`593ca005513da6bf5e4019c355f2b599887a83c93bbf60a87641d479584906dd`

Sender exited 1 with `frame receipt wait elapsed`, caused by
`deadline has elapsed`. No completion or explicit rejection reached the sender.
Receiver PID 19224, Session 1, exited 0; its only output reported processing one
frame attempt. Stderr was empty. Because receiver exit 0 also covers rejected
attempts, this evidence cannot establish native submission or visual success.

The source uses 100ms both for receiver frame acquisition and sender terminal
receipt waiting. That creates a possible timeout-receipt race, not a proven
explanation for this run. Per-frame receiver diagnostics and distinct control
receipt waiting are required; media freshness must not be relaxed to hide it.

The exact task `Viewflow Raw Visual Retest 20260904-1929` was removed after
terminal state; the build agent verified no raw peer process remained and the
original Deskflow GUI/core remained Session 1 (PIDs 6388/8868 at that check).
Logs were retained under
`C:\Users\wilf\AppData\Local\Temp\viewflow-raw-visual-test-20260904-1929`.

## Follow-up diagnostic candidate and native submission

Sender terminal-receipt waiting is now 1 second, separate from 100ms receiver
frame collection and unchanged 33.333ms media freshness. Receiver terminal
decisions are logged before writing receipts; summary counts native submissions.
The existing middle-rejection test now delays its receipt 120ms and passes;
all nine example tests remain present and pass.

Exact source SHA:
`8739b5e21db289804eb4197906e753f1f4a11a952b6b4103550ae1a258c24162`

Linux release SHA:
`2ae0f159dff81145981a92a526d021cd975c77a10c9d2f9ead5a23fe54b24b0b`

Native Windows build agent reported offline locked release success (29.28s),
archive SHA `8ec30799b5e888586cbffc87b3ffb158c138eef738e2b487a4ec5fa7d25dd1da`,
EXE SHA `784d197d029e42a671bab4d16d9fdbc86fd4655f8cb8bb7c6e0d1e7be116fa50`,
size 3,182,080 bytes, at
`C:\Users\wilf\AppData\Local\Temp\viewflow-raw-peer-final-20260904-193237-GjHVPt\source\target\release\examples\raw_window_peer.exe`.
These changes improve observability; they do not establish why the prior run
timed out or prove successful display.

The follow-up receiver was then executed once via task
`Viewflow Raw Visual Retest 20260904-1940`. Sender exited 0:

```text
queued_packets=456 queue_elapsed_ns=360387 terminal_elapsed_ns=64756995
path_rtt_ns=2598066 cwnd=41636 lost_packets=1 congestion_events=1
receiver_received_ns=399457430 receiver_native_submission_ns=433272220
clock_rtt_ns=865376 uncertainty_ns=432688
```

This establishes native submission of one staged frame, not capture or actual
scanout. Receive-to-native-submit was 33.814790ms; terminal receipt elapsed
64.756995ms. The two-frame end-to-end target is not established. User visual
confirmation was requested. The user reported that edges/window decorations
looked problematic and asked for a longer display period to inspect them.
Do not treat the visual result as accepted; the two-second display was too short
for the requested inspection.

Receiver PID 19060 (Session 1) logged `receiver_terminal=presented` and exactly
one native submission, then exited 0. The exact 1940 test task was removed;
no raw peer remained and original Deskflow PIDs 6388/8868 were preserved.
