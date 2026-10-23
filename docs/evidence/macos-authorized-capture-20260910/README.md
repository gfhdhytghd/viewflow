# Mac permission grant and real Windows presentation

The user enabled Screen Recording for the existing
`/Users/linhaikuo/Applications/Viewflow Window Sharing.app`.

Live investigation found that direct execution under the transport process still
reported Screen Recording denied, while a normal Launch Services launch of the
same unchanged, signed app reported Screen Recording allowed. Restarting the
supervisor alone did not resolve that launch-context difference.

`tools/macos-window-app.py` now launches the authorized app using `open -n -g -j`
and carries native stdin/stdout/stderr through private bounded FIFOs. Source
instances use `-W` for ownership and orderly framed shutdown. Short inventory
and permission probes drain their output without `-W`, avoiding the launcher's
fast-exit process-wait race. The app is launched hidden and in the background;
no desktop focus or input event is synthesized. Its executable and signature
were not replaced, and no TCC database or OS permission was changed programmatically.

The live Mac source template and prepared Mac-to-Linux template now use this
launcher. The existing Mac window supervisor automatically enrolled real windows.
The Windows interactive desktop contains three visible `ViewflowPortableWindow`
proxies, including a **1480x1250** window. The passive inventory program and its
result are included. The inventory's temporary scheduled task was deleted after
readback. These windows are created by the Windows presenter's decoded-frame
path, not by the inventory program or a generated fixture.

Under the actual app launch context, Screen Recording is now **true**, while
event-post authorization is **false**. The earlier direct-SSH event-post readback
was a different launch context and does not prove permission for this app.
Windows-to-Mac mouse/keyboard control therefore still requires the same app's
Accessibility authorization and user-operated acceptance. No input was injected.


The FIFO exit probe exposed that closing the last writer alone did not wake the
existing native reader on this Mac. The adapter now forwards complete input
records under a lock and appends a zero-length terminal record on EOF/termination.
The native reader rejects that length and follows its input-ended cleanup path,
releasing held input and stopping capture. It is a transport termination marker,
not a mouse, keyboard, focus or other input event. Incomplete incoming records
are never partially forwarded ahead of that marker. The allocation ceiling
matches the native 96 MiB framed-record limit.

A real selected-window capture test received a nonempty tile, closed its upstream
input without sending input events, and observed exit code 0. The native's
expected terminal-framing diagnostic is preserved in `wrapper-drain.json`.
The old test source and the first deployed adapter instances were explicitly
closed; the supervisor was restarted with the corrected adapter.
