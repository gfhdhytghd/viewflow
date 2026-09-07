# macOS keyboard and mouse receiver

`viewflowd serve` and `viewflowd connect` now accept `--input-backend native`
on macOS (development baseline 13+). The implementation uses public Quartz
event APIs and the existing authenticated QUIC input/lease protocol. It does
not require a capture stream or screen-recording authorization.

Build on the Mac:

```sh
cargo build --locked -p viewflowd --bin viewflowd
./target/debug/viewflowd input-status
```

If the system developer path is broken but Xcode Beta is installed, prefix
build commands with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
This changes only the command environment, not the system developer selection.

Run from the logged-in Mac user's session, using your paired peer certificates:

```sh
./target/debug/viewflowd connect \
  --peer 192.0.2.10:44119 --server-name viewflow-peer \
  --cert /absolute/path/client.pem --key /absolute/path/client.key \
  --ca /absolute/path/ca.pem \
  --input-backend native --device-id 00000000000000000000000000000002
```

Replace the example address, certificate paths and device ID with the actual
pairing configuration. No test identity is installed as a production identity.
In System Settings → Privacy & Security → Device Control and Data Access
(macOS 27; called Accessibility on earlier releases), authorize the actual
receiver executable/launching application macOS attributes the request to.
SSH-launched and locally launched receivers may have different authorization
identities. Confirmed on the LAN Mac: SSH assigns the permission subject to
`/usr/libexec/sshd-keygen-wrapper`, so its false result does not contradict an
enabled `viewflowd` toggle. A one-shot LaunchAgent in `gui/501` running the same
binary returned true after the user's authorization. Run the receiver as a
LaunchAgent in the logged-in GUI session rather than granting control to SSH.
`input-status` runs in the actual daemon executable and never requests
permission or posts input; its result applies to that launch context.
Screen Recording and Input Monitoring are not requirements for this receive-only
backend. Relaunch after changing OS authorization if the OS caches the result.

Supported:

- Fractional relative movement and absolute Quartz desktop points; Retina
  backing-pixel scale is not applied again. Relative motion is clamped to active
  displays, including negative origins. Held buttons generate drag events.
- Five buttons, click counts using the global double-click interval (500 ms
  fallback), and two-axis pixel scrolling with fractional accumulation at
  40 points per detent. Positive protocol horizontal scroll maps to Quartz right.
- USB keyboard page letters, digits, punctuation, navigation, keypad, F1–F20,
  common ISO/JIS keys, Caps Lock, and left/right modifiers. GUI → Command,
  Alt → Option, Control → Control; character layout is selected on the Mac.
- Duplicate transition suppression, explicit repeat, ordered releases of
  remotely held buttons/keys, failed-release retention and bounded Drop retries.
  Events carry the `VFLW` source tag for future input capture loop filtering.

Consumer/media usages, F21–F24 and native multitouch contact frames return
unsupported rather than silently injecting a different key or gesture. The
standalone daemon's absolute-coordinate contract currently uses the native Mac
desktop origin; a shared-layout source must translate its global origin before
sending positions. The macOS atlas/video/display-layout integration is separate
and is not completed by this receiver.

There is no focus, screen-capture freshness or 33 ms check inside this backend.
It reports OS permission/event-creation errors without terminating the process;
the existing receiver retains authentication, lease, target and sequence checks.
The legacy daemon input protocol still performs its existing clock validation;
the atlas ordered path is separate. A successful Quartz post means submitted,
not proof that the target application consumed the input: `CGEventPost` has no
delivery-result return value. If macOS revokes posting permission while input is
held, the backend cannot guarantee OS release until permission becomes available.

## Validation and manual acceptance

```sh
cargo test --locked -p viewflow-platform macos_input --lib
cargo test --locked -p viewflowd --lib input_runtime::
```

These tests use recording sinks or create/read/dispose Quartz event objects.
They never call `CGEventPost`, move the cursor or change focus. Physical
acceptance remains user-operated: normal/shifted typing, Command shortcuts,
left/right modifiers, repeat, single/double click, drag with each button,
both scroll axes, display edges, reconnect and disconnect with held input.

2026-09-07: compiled on the LAN Mac mini (Darwin arm64, macOS 27.0 beta,
Rust 1.97.1, Xcode Beta SDK). Native event construction and receiver tests passed;
the read-only SSH permission probe reported `event_post_authorized: false`.
This is build/object-level validation, not live input acceptance or verification
of the oldest supported macOS version.

The built receiver is on that Mac at
`/Users/linhaikuo/viewflow-macos-input.5BIAFI/target/debug/viewflowd`.
Run that executable with `input-status` from the intended launch context before
the user-operated trial. [Build evidence](../../docs/evidence/macos-input-20260907.md)
records the tested binary and validation boundary.

Follow-up: the user authorized a bounded LAN live trial. Typing `vfTest`, Shift,
single/double click, dragging, both scroll axes and disconnect release passed in
a disposable AppKit window. See [live evidence](../../docs/evidence/macos-input-live-20260907/README.md).
macOS also required the user to approve Local Network access on the receiver's
first LAN connection. Device Control and Data Access alone does not grant that
network permission.

References: [Quartz keyboard events](https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:)),
[event-post permission](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()),
[click counts](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventclickstate).

Window capture and proxy presentation use the separate
[window-sharing setup](../../docs/macos-window-sharing.md).
