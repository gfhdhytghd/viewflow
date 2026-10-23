# Windows proxy resize timer regression

User reported that resizing a Linux window on Windows temporarily stretches the proxy and then restores its old size.

The modal media pump and cached background refresh both used HWND timer ID `0x5646`. The background handler returned before the modal handler, so an active background cache swallowed resize-loop pump messages. Entering resize also replaced the background timer, and exiting resize removed it.

The modal timer retains `0x5646`; the background timer now uses `0x5647` consistently for dispatch, creation, error cleanup and destruction. A compile-time assertion prevents the IDs from colliding.

Validation: Windows Release build with the existing FFmpeg AV1 decoder succeeded. All 34 existing CTests passed. The new `atlas_modal_timer` test passed using the actual production window procedure on a message-only HWND: it verifies independent callback dispatch, both native timers running together, and background refresh surviving modal-timer cancellation. It creates no visible window and injects no mouse/keyboard input.

Deployed presenter SHA-256: `E4C27F472008E9657C515C9256E6152469C6A2316FB1806542C9E53CCB7A1935`. The running executable path and hash were re-read, and native presentation advanced beyond frame 780 after reconnecting. The current Linux peer and reverse executable were retained. Only DP-4 and existing HEADLESS-13 remained.

Earlier logs also contained a shared-control queue saturation disconnect; this timer fix does not independently prove recovery for every queue-saturation case. Physical drag/resize acceptance remains user-operated and pending.
