# macOS native input build and non-injecting verification

Date: 2026-09-07. LAN machine discovered via mDNS and reached over existing SSH
key authentication as `linhaikuo`. Platform: Mac mini, Darwin arm64, macOS 27.0
build 26A5425a; Rust 1.97.1; Xcode Beta MacOSX SDK.

The global command-line tools selection points to a missing installation.
Builds set `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` only
in their environment. No system developer selection, desktop focus, OS privacy
database or existing remote-control service was modified.

Build directory on the Mac:
`/Users/linhaikuo/viewflow-macos-input.5BIAFI`.
The directory contains a workspace source snapshot, compiled receiver, and
`macos-input-tests.log`, `input-runtime-tests.log`, `build-final.log`.

| Verification | Result |
| --- | --- |
| `cargo test --locked -p viewflow-platform macos_input --lib` on Mac | 10 passed, 0 failed |
| `cargo test --locked -p viewflowd --lib input_runtime::` on Mac | 17 passed, 0 failed |
| `cargo build --locked -p viewflowd --bin viewflowd` on Mac | Passed; Mach-O arm64 executable |
| `viewflowd input-status` over SSH | `event_post_authorized: false`, `input_injected: false` |
| Recording-sink macOS tests on Linux | 7 passed |
| Linux receiver/window-input filter | 68 passed |
| Changed-file whitespace and new Rust source formatting | Passed |

Binary: `target/debug/viewflowd` in the Mac build directory.
SHA-256: `ce2a408dbef7a4daeb4b31eebe09abc0ea3ef70bd875d6d1cb4e318c3f02401b`.

Native tests only allocate/read/dispose Quartz event objects. They cover modifier
flags, autorepeat, source tags, all five buttons, click down/up event-number
pairing, double-click counts, wheel direction and last-position routing. The
portable state-machine tests cover duplicate suppression, both modifier sides,
fractional deltas, negative coordinates, drag type selection, Caps Lock, invalid
input, failure bookkeeping, ordered cleanup and Drop retry. Receiver tests
include native construction/empty cleanup, target/lease/sequence checks and the
existing ordered-input behavior. No test posts an event to the system or moves
the cursor. There was no live keyboard/mouse acceptance trial.

The new macOS module produced no warnings in the native Clippy pass before the
final click-pairing addition. Repository-wide `-D warnings` is not clean: existing
protocol documentation/cast warnings and Windows input warnings remain. Native
daemon builds also report existing unused-code/parenthesis warnings.

The workspace was being edited concurrently for Windows touchpad/atlas work.
The final Mac snapshot includes the touchpad enum and explicitly rejects native
touchpad frames in the macOS keyboard/mouse backend. Legacy sidecar tests were
updated to clone wire events now that the wire type contains a vector. Results
above describe the copied snapshot and binary hash, not later unrelated edits.

Remaining acceptance: grant Accessibility/event-post access to the actual launch
identity, start a paired peer session and perform the user-operated checklist in
[the setup guide](../../deploy/macos/README.md). Media keys, F21–F24, native
multitouch and macOS video/atlas integration are not implemented by this change.

## Follow-up: authorization confirmed in GUI session

After the user enabled `viewflowd` under macOS 27's **Device Control and Data
Access**, direct SSH still returned false. Read-only `tccd` logs identified
`com.apple.sshd-keygen-wrapper` as the responsible process and
`/usr/libexec/sshd-keygen-wrapper` as the permission subject; `viewflowd` was only
the requesting process. This was launch attribution, not a missing user toggle.

A temporary, non-persistent `org.viewflow.input-status-check` LaunchAgent in
`gui/501` ran the exact same executable with `input-status`, producing:

```json
{"backend":"macos-quartz","event_post_authorized":true,"input_injected":false}
```

The one-shot job exited and was removed with `launchctl bootout`. No permission
database, focus or input was changed. GUI-session event-post authorization is
now confirmed; physical input acceptance remains user-operated. The earlier
false result above is retained as evidence of the SSH launch context only.

## Follow-up: user-authorized live trial

The user subsequently authorized simple assistant-operated live tests.
[LAN live evidence](macos-input-live-20260907/README.md) confirms typing, Shift,
click counts, dragging, both scroll axes and held-input release on disconnect in
a disposable target application, using the same receiver binary hash.
