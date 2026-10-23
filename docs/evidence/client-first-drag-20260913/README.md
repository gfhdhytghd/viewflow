# Client-first window dragging across desktops

The receiver owns the visible window position while the user is dragging it.
Geometry follows on the ordered connection; stale source snapshots cannot undo
local motion or the final released position. No elapsed-time cutoff transfers
ownership to a stale source frame.

For captured titlebars inside window content, the receiver first forwards the
held click until a same-size native source translation confirms that the app
interpreted it as a window move. It then sends source button-up and continues
locally at the original grab offset. Content clicks, selection and resize are
not classified from a guessed titlebar strip. Existing local modifier drags
remain available.

- Mac -> Linux: existing confirmed native takeover retained.
- Windows -> Linux: enabled the same takeover with non-Mac tile dimensions.
- Linux/Windows -> Mac: added confirmed takeover, event-loop geometry coalescing,
  and queued/pending receipt protection through mouse-up and output congestion.
- Mac -> Windows: added confirmed takeover, native modal-loop frame processing,
  geometry streaming during move, adjacent-only output coalescing, and retry of
  a final geometry that could not enter the output queue.
- Linux -> Windows: native move keeps local ownership through release. VFGP
  v10 carries the validated drag/sequence receipt through the sole media-pipe
  owner. A matching source frame already cached before the receipt is applied
  immediately, including static windows and rejected/returned geometry.

Validation so far: Linux receiver build and 4 CTests passed; macOS strict native
build, presenter/Metal self-test, and deep/strict application signature passed.
Linux both live receiver executable hashes match the build; macOS active
Windows receiver private helper hash matches the signed app helper. Existing
Mac main app and parking-display owners remained running during helper updates.

Physical drag acceptance is user-operated, as required by AGENTS.md. No mouse,
keyboard or focus input was injected for testing.

Final validation: Windows native forward build and 36 CTests passed (including
message-only modal-loop exit, parser/receipt, and ordered-queue coverage);
Windows portable presenter build and 2 CTests passed. Rust receiver-state 11,
receipt encoding 1, and source-input 9 tests passed. Linux NVENC-enabled and
Windows vf-media-peer release builds completed. Both forward endpoints were
installed and reconnected; Windows logs show new native commits and Mac logs
show continued presentation. No Hyprland plugin reload was required.

Deployment fingerprints (SHA256):

- Linux native receiver, both routes: daa4f5d6942dcc64d1f35271483bae7d91ea6c97f54ef2ed93f02db395d985de
- Linux active media peer: 6c60535eec5f632ea869084d69012c93134e2fa50d5f089ceb4e5cc35c9f0723
- Mac signed helper and active private presenter: b08c11f094732d36fdab1dc27e10fff9dc06fbcaea762fb0b113e93db979828c
- Windows Mac presenter: 7B4598A9B9BBCBB9BDE67C8C7F4C7B92093D4CB154E6234299749340609B6800
- Windows media peer: 900C3BD76F4640227A61C474EDB7EBA007404DFF9364D30B5ACF61EBEBB2A975
- Windows forward presenter: B57C96DF5F835B9AE61BF292EC2800D9EDE0545415242A15B8B67023B233DB59

The forward source waits for capture_monotonic_ns strictly newer than completed
native End before returning actual bounds. If capture stops, a 5-second
operation watchdog rejects only this geometry hold; the session remains. A
subsequent source-side drag operation can wait behind that receipt (normally
one captured frame, up to 5 seconds with absent capture); the destination
window remains locally responsive throughout. This is not a physical latency
measurement or a claim that every manual direction has been accepted.
