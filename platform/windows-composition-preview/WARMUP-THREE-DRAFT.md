# Explicit three-picture startup warmup (diagnostic)

This is an opt-in experiment, not evidence of live presentation or a changed
latency budget. The default remains one optional native VFGP v3 picture.

All three processes must select `--warmup-frames 3`. Only the exact values `1`
and `3` are accepted. The cross-host sender/receiver additionally exchange an
explicit count plan and acknowledgment before warmup in three-picture mode;
default mode retains its existing record order. Native records remain v3:
the local command-line option explicitly changes the admitted startup count.

The same encoder produces three real captured pictures, without restarting or
discarding an encoded reference picture. Only the first is a keyframe. Geometry,
codec generation and session identity remain fixed. Each picture must receive
its exact decode-only completion before the next is sent. One startup deadline
covers the entire exchange; each frame does not obtain a new startup timeout.

Native three-picture mode requires three completed unbound GPU copies before
any live input is admitted. It rejects a fourth picture, overlapping pending
warmups, mismatched completion, duplicate/non-increasing warmup identity, early
live input, warmup after live, and incomplete warmup at EOF. Rejection is
terminal. Normal parser identity and size bounds remain in force.

No warmup is bound to the composition visual or reported as a live submitted
frame. READY is sent only after all exact completions; the sender's subsequent
capture floor excludes pre-READY pictures. All live pictures retain original
capture timestamps and the existing two-frame freshness checks, including
opt-in native v4 QPC admission. This does not prove a physical scanout deadline.

Native admission has a portable executable test registered in CTest. Windows
build and cross-host runtime results must be recorded separately; source tests
alone do not establish working multi-picture streaming.

## First cross-host trial: r18

Linux sender SHA256:
`1c1f08665e7eaf45190d7f474b9ab4d574eb303b54454c5903031ba4cb3243a0`.
Windows receiver SHA256:
`bfa077100ded1ba9171599fd8d47fbc1aab2375686964e6ca43d1ca0d33d3725`
(32 Windows tests passed; source archive
`43cc92c03c60bb80503cfb9f22abb238104dc2594332b5c21dd4848a9d5a2902`).
Native presenter SHA256:
`f0bf051d3f6a6d116bf06a5c1abec5c7adba51216d856a7f432534c7382ae10d`
(10 Windows CTest tests passed).

At 2026-09-05 08:18 UTC, the first real warmup (identity 5) completed natively
and was acknowledged. The second was rejected by receiver metadata validation,
before reaching native Submit. The added equality check between color and alpha
keyframe flags was incorrect: production GPU encoding sets color from the
actual IDR status, while independent VFAR alpha is always a keyframe. No live
media was sent, and this trial does not validate completion of three warmups.
The receiver exited without timeout; the sender reported warmup ACK timeout
after receiver rejection. The trial task was removed and diagnostic processes
and UDP port 44339 were confirmed absent.

Private local evidence: `/tmp/viewflow-warmup-three.7ETt2i/terminal-r18.json`
and `sender-r18.stderr`. Fix and a specific color-nonkeyframe/alpha-keyframe
regression test are required before repeating the trial.

## Corrected cross-host trial: r19

The invalid cross-plane keyframe equality was removed; each plane still binds
its configuration generation to the frame identity, and color reference-chain
checks remain unchanged. A regression accepts color non-keyframe plus independent
alpha keyframe, and rejects either plane's wrong configuration generation.
Linux example tests 31/31 and Clippy with warnings denied passed. Windows
example tests 32/32 passed, with a fresh release built using a copied dependency
cache in a new target; the previous candidate was not modified.

Peer source SHA256:
`2115713aa7eab7009e17d0b69f089f950f8c8d86f10b64fbcc9a1c2218faf514`.
Linux sender SHA256:
`fa3c31862165b2b6de43cb97f48683029058fd3c0ca1d5f06cdd14f5c35bdf55`.
Windows receiver SHA256:
`6d1aeeae2637bdd274c92065cc3fd60d10521082dd27e0a2538878fa65d810f6`
at `C:\Users\wilf\AppData\Local\Temp\viewflow-warmup-r18-20260905-4B7D\target\release\examples\coded_window_peer.exe`.
Source archive SHA256:
`40ba064d9ea2f8aa274f7de65fc98d7aba428a865b0dadad6355cffa067f17cb`.
Native presenter remained the r17b candidate identified above.

At 2026-09-05 08:26 UTC, all three real warmups (identities 56, 93, 101)
completed native Submit with HRESULT 0/completed_delta=1, copied to an unbound
surface, and received exact acknowledgments before READY. Native host Submit
times were 486.779 / 43.101 / 4.316 ms; alpha reuse was false/true/true.
No warmup was counted as a live frame.

Live identity 103 reached native Submit and returned HRESULT 0 with one decoded
output, but did not receive a live presentation acknowledgment within its budget.
Sender capture age at send was 6.540 ms; payload was 155 color bytes plus
138,721 alpha bytes. Receiver assembly was 10.098 ms, leaving 14.326 ms;
validation/queue took 0.801 ms. The writer reported 13.363 ms before its work,
0.223 ms writing and an ACK timeout after 12.441 ms. Native parser was 1.154 ms;
Submit was 10.592 ms (MF output 4.481 ms; resource creation 5.459 ms).
There is no successful live ACK or proof of physical presentation. Three-frame
warmup alone therefore did not meet the unchanged 33,333,333 ns live budget.

Receiver PID 23620 exited without the runner's outer timeout. The r19 task was
removed and no diagnostic processes or UDP 44339 listener remained. Private
evidence is `/tmp/viewflow-warmup-three.7ETt2i/terminal-r19.json` and
`sender-r19.stderr`. No persistent service, physical network configuration or
Hyprland configuration was changed by these trials.
