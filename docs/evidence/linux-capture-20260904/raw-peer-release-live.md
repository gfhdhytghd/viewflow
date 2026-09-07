# Successful cross-host native submission

2026-09-04: Linux 172.16.105.62 sent the same decorated-window.vfbg to
Windows 172.16.105.70:4433 with fresh test mTLS credentials. Both programs used
release builds. Receiver PID 17328, Session 1, exited 0. The original Deskflow
GUI/core (6388/8868) remained running. No deployment service was replaced.

Sender exit 0, exact output:

```text
receiver accepted and submitted the raw BGRA frame: receiver_received_ns=1704174050 receiver_native_submission_ns=1705692440; clock_rtt_ns=1472233 uncertainty_ns=736117. This is native submission only, not physical-display or end-to-end latency proof.
```

Receiver output:

```text
submitted one raw BGRA frame to the native proxy and pumped it for up to two seconds; this does not prove physical display presentation
terminal control receipt was finished; sender acknowledgement did not arrive within 250 ms
{"visual_verified":false,"pid":17328,"session":1,"exit_code":0}
```

The receiver retained the 33,333,333 ns admission budget. Its receipt-to-native
submission interval was 1,518,390 ns. RTT was 1,472,233 ns; estimated clock
uncertainty 736,117 ns. These are NOT capture-to-display measurements. Source
capture was a previously staged file and the HWND API does not return physical
presentation time. Visual confirmation was requested from the user and is not
yet established at the time of the run. The bounded receipt drain timed out, but the sender explicitly
received and parsed completion and exited successfully.

```text
example source SHA256:
174f1fb3c69882c580981564a373e48f22d01b5e19cd825b352146e7ec3f4436
Linux release executable SHA256:
69d76c6d1144febd887fb7c48865d6094fbce069a9d8b9c955521719bc4519fe
Windows release executable SHA256:
a8a808144b770afc61d59621de1e9f9619b71e9a03f64e8e6e24af32de77b554
Windows source archive SHA256:
9463e76c898b5a48ea9f707f2703d288422157cfdb728170b978a396a1ff8206
```

Windows native offline release build took 27.41 seconds and produced 3,137,536
bytes under `C:\Users\wilf\AppData\Local\Temp\viewflow-raw-peer-release-20260904-180905-it2TqC\source\target\release\examples\raw_window_peer.exe`.
Runtime evidence remains in `C:\Users\wilf\AppData\Local\Temp\viewflow-raw-live-pTgxe7-r3`.
Temporary task `Viewflow Raw Test pTgxe7-r3` was removed after terminal state;
raw_window_peer process census was empty. User-managed firewall settings were
not changed. This is one-frame submission, not continuous streaming, dragging,
resizing, blur, or two-frame end-to-end acceptance.

## User visual feedback

The user confirmed the diagnostic appeared, but reported approximately 2x
size and blur / incorrect scaling. Thus visible appearance is confirmed while
scaling correctness is explicitly FAILED. The capture has 564x262 physical
pixels for a 282x131 logical decorated frame. The diagnostic currently sends
only pixel dimensions, so receiver placement lacks source logical geometry;
Windows DPI awareness/resampling also requires verification. Do not cite this
run as correct native-scale rendering.
