# Mac proxy secondary-click ownership

The user reported that two-finger taps and short physical two-finger clicks open
and immediately dismiss context menus, while longer holds keep them open.
Source diagnostics showed one forwarded BTN_RIGHT pair per attempt and menu
disappearance 0.4–0.6 seconds after release, without intervening AXRaise. The
bounded native event tap did not overlap those attempts, so it did not establish
a second native event pair.

At the user's explicit direction, secondary clicks now belong to native HID
whenever the Mac proxy reports HID ready and a touchpad is available. The Linux
receiver no longer forwards that BTN_RIGHT down; releases still complete any
button previously admitted before HID became available. HID-unavailable fallback
retains ordinary Wayland button forwarding.

Raw touchpad snapshots now include actual physical BTN_LEFT edges and resync
that state. With exactly two admitted contacts the native report carries the
physical click bit and pressure120; release restores measured pressure. This
lets both tap and physical click use native recognition, without delaying
clicks, changing global preferences or filtering global macOS events. The Mac
assembler accepts the already-supported ABI2 physical button bit.

Updated Mac source helpers were signed and reconnected before installing the
Linux receiver. Four Linux CTests and the strict touchpad-slot test passed.
Regressions cover physical down/up without motion, report deduplication,
pressure restoration, button-bearing reassembly and dropped-input snapshots.
Mac warnings-as-errors build and deep/strict signature verification passed.
User-operated light-tap, short-press and long-press acceptance remains pending.
