# Mac titlebar dragging on Linux: native-body mapping regression

The native-decorated (`flags & 16`) branch in `platform/linux-reverse/main.cpp`
converted the current Wayland surface point using the last video tile's origin.
It returned before the existing compositor desktop-pointer path. As the proxy
moved, its relative pointer coordinates could combine with an older Mac window
origin and feed that movement back into the next native drag event.

On button press this branch now anchors the source point, desktop pointer and
display-to-source scale. While held, it uses only compositor desktop-pointer
displacement against that anchor. Delayed tile origins and proxy movement no
longer enter the held-pointer calculation. Ordinary unheld body hit mapping
and its current display scale are preserved.

The Linux build and both CTest cases (`reverse_wire`, `reverse_geometry`)
passed, including delayed-geometry and scaled-pointer regression assertions.
The receiver service was restarted and reconnected. Both observed presenter
processes matched the new executable SHA-256:
`2066665e10f9228f7a63c93677a08f71f3b04e2e8fffd61e59c0669e36e85140`.

No mouse input or focus changes were injected for testing. Actual titlebar
dragging remains a user-operated acceptance check; build/runtime identity
verification is not proof that every source of visible jitter is eliminated.

## Follow-up: local compositor movement

After the user reported that jitter appeared resolved but dragging still felt
slow, the Linux presenter gained native-move takeover. A held left click first
follows the existing Mac input path. An actual translated Mac window rectangle
with unchanged size/geometry receipt confirms that native dragging has begun.
Content clicks, resizing and echoes of Linux geometry requests do not trigger
takeover. This initial confirmation still depends on the first returned frame.

The presenter aligns the proxy to the original grab offset, sends the source
left-button release, and starts `xdg_toplevel_move` using that physical press's
Wayland serial. Hyprland then moves the existing surface at compositor speed;
subsequent video frames are not required for local movement. Geometry is sent
back to Mac on a 16 ms polling cadence during the drag. Receipt ordering keeps
old frames from undoing local motion or the final placement after release.

`Mac titlebar local requested`, `active`, and `end` diagnostics distinguish the
request from observed compositor drag ownership. Synthetic tests cover native
move confirmation, resize/receipt rejection, cancellation and delayed final
receipts. Both Linux CTest cases passed. The service was restarted and a running
presenter matched build SHA-256
`2cec81e2f703f6703d6737d61483f714b440894cdda4e7f033c1a6bfe5067c1a`.
Physical drag/settling acceptance remains user-operated.
