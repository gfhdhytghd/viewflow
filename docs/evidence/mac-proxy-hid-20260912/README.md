# Proxy multitouch alongside desktop HID

Enabled the existing two-to-five-contact native HID route for Mac proxies on
Linux. The presenter had explicitly disabled physical capture in Mac shadow
mode. The native encoder still excludes single-finger contacts and physical
button reports; normal motion/clicks remain on the existing window input route.

The Mac GUI host now accepts multiple ordered socket streams. An idle persistent
desktop connection no longer blocks proxy connections. Each receiver releases
DriverKit ownership after all-up, without closing its stream. Contention retries
on subsequent physical snapshots. Idle EOF cannot release another producer.

## Validation

- Linux Release presenter build and reverse CTests: 2/2 passed.
- Native Mac Swift socket/stream tests passed with injected fake driver calls:
  persistent idle desktop plus two proxy streams; later desktop acquisition;
  simultaneous idle shutdown; exclusive-owner recovery; EOF during a gesture.
  Test OS input submissions: zero.
- Full Swift app compiled; existing Swift 6 isolation warnings remain in the
  permissions delegate under Swift 5 mode.
- Existing provisioned app identity and unchanged DEXT retained. GUI-session
  signing succeeded; strict deep verification passed. Temporary signing agent
  was unloaded. No keychain ACL or driver activation changes were made.
- `git diff --check` passed.

## Deployment and readback

Linux presenter PID 2425648 opened `/dev/input/event17`, reported native HID
physical capture available, and matched SHA-256
`3d2a5ad56fddaa5e9eec1d72afe3ccc887ab39513d54bb9fd4b507520d24b39c`.
Both the configured build path and the bundled Linux executable were updated.

Mac GUI PID 69445 runs `/Applications/Viewflow.app`. Its executable matches the
signed staging app, SHA-256
`453ff1a8a4505d5b8033b80dfc99a9c38e025f805a6568631b80379fee4af9ea`.
Previous app retained at `~/viewflow-proxy-hid-20260912/previous.app`.
The old GUI drained child processes but did not complete its exit callback;
it was terminated before the verified app replacement and background relaunch.

The active Mac source log reported `window HID capability=1` and
`window HID stream opened window=1`. Driver submitted count rose from 83214 to
83867 during user activity, with errors 0 and no held contacts/buttons at final
readback. Desktop HID, Mac input and Mac proxy receiver services are active.
No automated mouse/keyboard/focus tests were performed; visual gesture behavior
still requires user confirmation. This proxy path remains evdev-to-ABI-2
reconstruction, not generic raw HID passthrough.
