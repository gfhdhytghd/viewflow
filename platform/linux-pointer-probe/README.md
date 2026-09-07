# Owned Linux pointer witness

Build with CMake and Qt 6 Widgets. Run with `QT_QPA_PLATFORM=wayland` and one
absolute, nonexistent JSONL log path in an owner-only directory. The widget
requests no activation, grabs no input, records only its own mouse-move events,
plus press/release events, and exits after 90 seconds or 4096 records. Clicking
this witness performs no action beyond recording its local position and Qt
button code. Existing logs are never overwritten.
Motion and button records also contain `qt_buttons`, the current held-button
mask, so an in-widget held-button movement can be distinguished from hovering.

Use its verified live PID/window address as the explicit capture/input target.
Compare recorded widget-local positions with the authenticated preview-to-source
geometry mapping. Native ACKs alone do not prove these application-side events.
The default witness does not log keyboard input. For an explicit isolated
keyboard trial, append a label and `--keyboard`: this enables key press/release
records only on the owned widget, including its native scan code, Qt modifiers,
text and repeat flag. It does not install a global keyboard hook or perform any
action. This opt-in is not source IME or application drag/drop acceptance and
does not authorize input to another application.

For an isolated source-input-method trial, use `--ime` instead of `--keyboard`.
This adds an owned Qt line editor with a 4096-character limit and logs delivered
`ime` events (preedit, commit, replacement range and attribute geometry),
`editor_text` changes and editor focus transitions. A cleared preedit without a
commit can witness cancellation, but should be interpreted together with the
preceding event. Qt handles editing and input-method queries; the logger does not
insert composed text. Keyboard events are also recorded. Clipboard shortcuts,
middle-button paste, context menus and drag/drop are disabled; use only disposable
text, never secrets, and an isolated compositor/input-method instance.

`ctest` runs an offscreen test that sends synthetic Qt input-method events through
the real editor and checks the JSONL and committed text for preedit, Chinese
commit, replacement and cancellation. These are explicitly **not** Wayland,
Fcitx, cross-device or physical-keyboard evidence. The existing default and
`--keyboard` modes still have no text editor. Native candidate-popup rendering
must be observed separately; application input-method events do not prove it.

For a compositor-local reproduction with an already isolated Fcitx instance,
`window_keyboard_native_probe ADDRESS COMPOSITOR_PID PROBE_PID NATIVE_SOCKET ime`
requires this exact owned executable with `--ime`, binds its captured native
identity, sends `nihao Space` as HID usages and then a motion at `(200, 300)`.
It never sends composed text. Each native request retains its own deadline.
The editor JSONL, not the helper's ACKs, proves composition; this mode is not a
substitute for the cross-device trial in `docs/window-ime-integration.md`.
