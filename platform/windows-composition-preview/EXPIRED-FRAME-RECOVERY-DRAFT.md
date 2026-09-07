# Explicit expired-frame disposition (next implementation gate)

r21 received 237 fresh presentation ACKs before a frame spent 14.896 ms in
assembly and left only 6.810 ms at the presenter writer. A terminal connection
failure on every such event prevents a robust stream. Reducing allocation work
alone cannot remove network/scheduling jitter.

Required recovery must not extend the original capture or native QPC deadline:

- Native may report an exact `Expired` disposition only when it has not bound
  that frame to the visual. Check before decode, before staging and immediately
  before binding. Discard an expired unbound candidate, erase only that frame's
  deadline, and never emit a Submitted acknowledgment for it.
- All other errors (malformed identity/record, frequency mismatch, decoder or
  device failure) remain terminal. Do not reinterpret unknown delivery as expiry.
- Rust must distinguish Presented, DecodeOnly and Expired rather than collapse
  expiry into an error string or successful ACK. Identity matching is exact.
- A separately bounded disposition wait may outlive a frame's freshness window,
  but cannot accept a late Presented as a fresh ACK. No next frame is queued
  while disposition is unresolved. Missing/ambiguous disposition stays terminal.
- Only an authoritative Expired result may become the existing cross-host
  REJECT, which already accepts late exact rejections and requests a new IDR.
  The next media must still pass the existing capture floor and IDR recovery
  gates. Cached independent alpha is not permission to reuse an old color frame.
- Default behavior stays unchanged unless both the receiver and native child
  explicitly select this capability. Require native v4 deadline enforcement.
- Test expiry before decode, after decode, after unbound copy, delayed Expired,
  late Presented, wrong identities, EOF/missing output, unchanged visible
  texture, and actual fresh-IDR resumption after a forced expired frame.

## Implementation status (2026-09-05)

Native and Rust source now implement the opt-in `--recover-expired-v4` path.
The flag requires compressed stdin and native v4 deadline enforcement. Native
reports exactly `rejected frame_identity=<u64> reason=expired`; Rust preserves
the original freshness deadline and allows only the disposition wait an extra
100 ms. Late Presented remains terminal. Before any pipe bytes are written,
local expiry may safely produce the same Expired outcome; partial writes may not.

The initial local peer tests (37) and Clippy passed; review then identified a
completion-already-present path that could bypass the disposition deadline.
The corrected r23b candidate checks the absolute deadline even for a populated
completion slot and rejects noncanonical Expired text. Windows tests 38/38 and
offline locked Release build passed before live use.
The native portable classification test passed, and source review checked all
three unbound rejection paths. Windows native Release and CTest 11/11 passed:
`viewflow-r23-native-20260905-V3M9/native-build/Release/viewflow_windows_composition_preview.exe`,
SHA256 `0fa352b0c9c7e40ffd8b81e34e6f083e175f10d6935dc3e30c7794b33c472b83`.
Its source archive SHA256 is
`df481c5726621e44920705b487914cc2c46cd96d0126c1c201eb0bbdbf5d57f7`.
Full integration verification remains incomplete. In
particular, the helper test is not proof of unchanged visible texture or actual
fresh-IDR resumption after post-copy expiry. No continuous-playback claim follows.

A distinct late-presented receipt protocol, if ever
introduced, requires its own explicit semantics; it must not silently relax the
current fresh-ACK rule. Physical scanout timing remains separately unproven.

## r23 bounded live trial

Windows receiver source SHA256:
`06bfa56fd3af000a12f93069c14bda5cbb983c0bec83f28149fcb5e41fea8b43`;
archive `4e6d648dd30b605977d32520d1f209cb1f10a47283c3006df8b96f936b639de9`;
EXE `3ee483d7981f1273d7e432725975a953019037753f2cbd9e58696bbae529883b`.
Linux sender EXE SHA256:
`5f883b2b7827f4a569c3d8467fc8e211c74086949b83061f0828d8eaf239aee4`.

At 09:14:07–09:14:12 UTC, the same decorated Dolphin stream completed three
decode-only warmups and sent 49 live frames: 25 fresh ACKs, 23 recoverable
REJECTs, and one terminal disposition. Receiver assembly/validation rejection
counters were zero. This exercises continued transmission across rejection,
but the logs do not distinguish pre-write expiry from each native expiry
stage; it is not a deterministic post-copy visual-preservation test.

Frame 161 failed closed on a late Presented ACK: assembly 12,298 us,
writer budget 7,938 us, writer elapsed 8,225 us. It was not converted to Expired.
Thus robust continuous streaming is still unproven; this trial does not relax
the deadline or claim physical scanout latency. Receiver PID 27220 exited 1
without the outer watchdog firing. Collector verified no diagnostic process,
no UDP 44339 endpoint, and removed only the r23 scheduled task.

Evidence in `/tmp/viewflow-warmup-three.7ETt2i/`:
- `terminal-r23.json` SHA256 `6fe0b2e7b1b4bb13fabd2ea47953f8e91328abeabc5b9daa0432f34a8d431267`.
- `sender-r23.stderr` SHA256 `09f0763790c2b5f148632c57fcdfb6c98eed2c2637917b5cecb39d376d2aad64`.

No VM NIC, physical network, original Deskflow, or persistent service changes
were needed for this trial.
