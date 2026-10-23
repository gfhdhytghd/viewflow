# Three simultaneous desktop input routes — 2026-09-13

Linux remains the physical input source. Windows and macOS now retain separate
paired QUIC cursor connections and native plugin sockets. The plugin reserves
one physical input owner from edge candidate through release; an idle route's
reconnect or teardown cannot release the other route. All virtual outputs are
included as local return destinations in each cursor peer's topology, allowing
Windows-to-Mac handoff through the compositor without switching services.

Observed logical topology:

| System | Origin | Size |
| --- | --- | --- |
| Linux DP-4 | 0, 0 | 3072 × 1728 |
| Windows HEADLESS-1 | 3072, 390 | 1920 × 1200 |
| Mac Sidecar via HEADLESS-2 | 3072, 1590 | 1539 × 1155 |

The Mac touches Windows along its top edge and Linux along the upper 138 points
of its left edge. Mac's main Sidecar display was verified using the live macOS
display inventory. Windows input retains its existing 3840 × 2400 wire mapping;
Mac uses display-local Quartz points and its separate native HID transport.

`tools/multiscreen-input-linux.py` prepares and supervises the added route.
`hl.plugin.viewflow.add_input_route("macos")` registers its private native socket;
`capture_status("macos")` observes that route, while the default query observes
the captured route or the primary instance. The HID forwarder accepts an
independent readiness file and named capture route. HDMI selection preserves
both input services while three-screen mode is active.

Live services use `viewflow-multiscreen-layout`, `viewflow-multiscreen-macos`,
`viewflow-multiscreen-windows`, and the existing Windows input, HID, Mac receiver,
clipboard and audio services. Window-sharing coordinates were aligned to the
new Mac origin. macOS Viewflow was normally quit and relaunched in the background
with its five components enabled. No synthetic input or focus test was used.

Validation: 10 C++ tests passed, including three-display seams and ownership
arbitration; 11 HID Python tests passed, including named-route readiness; three
HDMI orchestration tests passed. The existing keyboard-state test triggers GCC's
maybe-uninitialized warning for address-only sentinel variables; this build used
`-Wno-maybe-uninitialized`. Other warning/error settings were retained.

Both live QUIC connections exchanged successful clock probes. Passive logs
showed Mac capture activation, real Mac cursor feedback, native HID ownership
transitions and ordered release/reconnection after the Mac application restart.
Services and topology read-back establish startup; the user's visible cursor,
keys, gestures and window dragging remain the end-to-end acceptance boundary.

## Independent Windows and Mac window routes

Windows now owns two VDD outputs: Linux at physical `(-6144,-780)` with
`6144x3456` pixels, and Mac at `(0,2400)` with `3078x2310` pixels and 200% DPI.
The physical Windows panel remains `(0,0)` with `3840x2400` pixels. The Windows
Mac source uses capture bounds `(0,2400,3078,4710)` (left/top/right/bottom) and
connects to Mac port 44223. That receiver has scale 2 and origin `(0,-1200)`;
the Linux receiver retains its own port 44221 and origin `(-3072,-1590)`.

The signed Mac application supports optional per-source `windowReceivers`,
additional `windowParkingDisplays` with unique serials, and destination
`viewport` filters. Existing pairing files without these fields remain valid.
The Linux parking display is serial 1 at `(-3072,-1590)`, `3072x1728` points;
Windows is serial 2 at `(0,-1200)`, `1920x1200` points. Both reported native 2x
HiDPI backing sizes after installation. Nearest-display parking keeps window
placement independent of display enumeration order.

Mac Windows sources use H.264 at scale 2 and port 44221. The Windows presenter
uses scale 1 and origin `(0,2400)`, mapping this Mac viewport to the physical
Windows panel. Its scheduled receiver was restarted with the new arguments.
No window was dragged or focused by automation to validate this path.

The native helper compiled with warnings as errors. Parking placement and Swift
configuration/recovery/storage tests passed; the Swift app build retains its
existing Swift 6 isolation warning under Swift 5 mode. The installed bundle
passed `codesign --verify --deep --strict`. Backups remain on the Mac in
`~/viewflow-dual-parking-20260913/` and `~/viewflow-three-receivers-20260913/`.
Recreating parking displays can return existing shared windows to a physical
display; they then need to be dragged back into the desired remote viewport.

User-operated Messages popup 1188 reproduced the wrong-screen problem at the
pixel boundary: the independent window image contained the correct Chinese
menu, while both display scene and display-with-popup-excluded images contained
Sidecar UI. The transmitted material and Linux popup screenshot showed that
same unrelated content. Linux's returned underlay was independently checked and
contained the correct Linux desktop. SCK frame metadata then reported actual
`(0,0,1539,1155)` for a requested `(-3072,-1590,3072,1728)` display; WindowServer
also logged `WSDisplayStreamGetDisplay: display = NULL` for the virtual ID.

The native source now compares the captured frame's public
`SCStreamFrameInfoScreenRect` against the requested display geometry. A wrong
display clears only the auxiliary material/preview, leaving the independent
popup-window image usable. Independent popup capture starts without waiting
for a preview. The source session and input remain running. This fallback
retains the window's own appearance; it cannot reproduce display-composited
native backdrop color while SCK supplies the wrong display. The compiled,
signed helper is installed, and live logs confirm detection of the mismatch.
Final user-operated popup appearance after this change remains to be checked.

Distinct display serials with the same name initially left the second Mac
virtual display offline despite a live owner and valid mode. After assigning
the second display its own name (`Viewflow Remote Windows 2`) and recreating
only that display, CG read-back listed both Linux (ID 12) and Windows (ID 14)
online and active with the requested geometry. This is runtime evidence of
the recovered arrangement; a Mac window on the Windows receiver has not yet
been observed. A precise ARC lifetime also retains each virtual display across
its owner's run loop.

At the user's request, Escort Helper display 5 (serial 12401) was configured
as a mirror of Sidecar display 6 and saved permanently. Both then reported
`(0,0,1539,1155)`; Safari's window returned to the visible Sidecar area.
Finder's Linux proxy was found on workspace 1 while workspace 5 was current.
It was moved to workspace 5 with `follow=false`, retaining `(1330,675)` and
`920x436` geometry; focus read-back remained on ChatGPT. No mouse/keyboard
test was injected.

## Native window dragging and main receiver recovery

User-operated Finder dragging subsequently reached the Windows parking viewport.
The Mac source started its Windows route, and GUI-session enumeration found a
visible Windows native proxy at `(0,634,2100,1834)`, matching the source geometry.
This confirms routing and proxy creation, but not physical display appearance.

The Mac presenter now hands confirmed title-bar dragging to AppKit's native
window drag operation, releases the source-side drag first, and sends native
resize results back to the source. Posted input has a local movement fallback.
The installed signed helper passed native compilation and presenter self-test.
The Windows Mac-source presenter also accepts client-first drag candidates when
native decorations are absent; its rebuilt binary passed both CTest cases.
Destination-native edge tiling still requires user-operated acceptance.

At 19:17:34 the Windows main receiver exited with `atlas recovery request arrived
before its media fence`. Desktop geometry acknowledgements shared the native
control queue with input recovery but were incorrectly required to carry the
input recovery fence. They now retain sole-owner, between-frame pipe ordering
without requiring that unrelated fence. Their local write watchdog starts when
serviced, so time spent queued during a static scene does not expire the write.
Input recovery retains its existing fence behavior. The related 36 tests passed.

Both release peers were rebuilt. Windows installed SHA256:
`D053A2B8060E2B083002241EEB71295DD5647BA1A2889E6356E7490BFE3FF089`.
Linux installed SHA256:
`ac4e44ecc4e079790d21ccacb99197f7a04980d123ea31488f848fad9913b2a7`.
The Windows one-shot `main-session.ps1` was backed up and replaced with a
supervisor that retries exited receivers with 2–15 second backoff and retains
the preceding stdout/stderr logs. The current launcher and routing configuration
were preserved. New native frame commits confirm a restored media connection;
physical mouse crossing and drag acceptance remain user-operated.


### Native window drag, popup scheduling and destination shadows (September 13, late session)

Mac source geometry no longer acknowledges an AX operation before success. The
latest pending placement survives transient AX lookup failures; successful old
requests cannot acknowledge newer targets. Windows native presenters retain the
source drag hint across synthetic hover, and record handoff/drop diagnostics.
A once-consumed source drag seed and ordered inherited left-button handoff were
installed earlier in this session. User confirmed crossing into Windows, but
final mouse-release placement still needs physical acceptance of this build.

Windows sources now send body-only pixels without generated shadow padding.
Linux proxies preserve the full body extent and original alpha; Hyprland draws
local shadows, with contact radius estimated from actual alpha corners rather
than clipping all windows to one corner shape. Mac and Windows destinations draw
local normal-window shadows. IME/popups are excluded from local shadow and added
padding; Mac native popup animation is disabled. Windows and Mac source schedulers
prioritize new popup discovery/capture during active input without abandoning
in-flight frames or closing the session on timing misses.

Deployed and read back: Windows source SHA256
`98EBC2801A637D137D83AEE12564987549F5F00ACAC3AAF1F15A29C983E6A1B6`
(active for both Mac and Linux); Windows Mac-window presenter
`87E9B86C209B85559F5E8C3210F11D0DFC0111927B57ED06BFCE82E832AEC989`;
Mac signed helper `e871114246ab1a2eeabaa8e061deefbf0acbfe0e731a1d7607fce3161d0c9ae4`;
Linux receiver running executable
`d9c1ece89146de2d9a0df6b26fff0b7f325c30a65a67ee5adb8b1104f5429fb5`.
Mac window peers were restarted without restarting the app or parking displays.
Windows source passed 10 CTests, presenter 3, Linux receiver 5, Hyprland plugin 10.
Mac native build/presenter self-test and placement/scheduling C++ tests passed.

The Mac headless-output supervisor now restores geometry after plugin reload;
live readback was HEADLESS-2 3078x2310 scale 2 at (3072,1590). Idle/submit timings
observed earlier are not end-to-end latency or physical presentation proof.
Final drag/drop, IME appearance and shadow shape remain user-operated checks.


### Follow-up: rear-window activation and Windows IME codec churn

User reported that a rear Mac proxy on Windows could not be raised by clicking,
and Windows-origin IME was slow on both Mac and Linux. The presenter previously
put 108 source units of shadow padding inside the interactive HWND and relied
on HTTRANSPARENT, whose traversal is limited to the same thread. Each incoming
Mac stream has a separate presenter process. Shadows now have an independent
WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE window behind the body; the
interactive HWND region excludes exterior padding. Mouse activation explicitly
raises the clicked normal proxy. No live mouse/keyboard test was injected.

Windows source log for IME id=5 measured discovery-to-capture 55,535 us and
first submission 2,044,978 us, with codec recreations at widths 5760, 5824 and
5952 in between. Candidate width animation and disappearance changed the packed
atlas extent, forcing repeated hardware encoder initialization. Source now
reserves a separate 512-pixel popup band, rounds capacity growth, and retains
capacity during popup activity; unused capacity shrinks after 3 seconds stable
idle. New live initialization telemetry measured 532.115 ms for one recreation.
This explains substantial source-side delay but does not measure new end-to-end
IME latency; a user-operated candidate test is still required.

Windows native builds passed presenter 3/3 and source 11/11 tests, including
capacity retention across the recorded candidate-width sequence. Installed:
presenter SHA256 `3101500C69891BF27521F4A8103ED3DD4373A46CCB59B27A851AC4CD1169EC08`;
source SHA256 `01241EA1DAF1FB5516045B5356141BC63C79C769651B3DFC4BFCAD74C36B9026`.
New presenter frame statistics and Mac receive/decode statistics confirm transport
resumed. Exact input and visible shadow appearance remain user-operated acceptance.

Read-only GUI audit after deployment confirmed a body region `(108,108,1063,660)`
on ViewflowPortableWindow and a separate ViewflowPortableShadow with extended
style `0x82800A0` (layered, transparent, no-activate). No pointer/focus action was
used. The temporary audit scheduled task was removed.

During final readback, Linux/Windows desktop pairing expired at 2026-09-14
00:19:57 UTC. Renewed existing CA/source/receiver certificates for 365 days using
the same keys, subjects and extensions; old certificates are retained in
`before-renew-20260913` under the existing pairing directory. Restart exposed a
launcher schema bug: windows_virtual_display metadata was passed to vf-media-peer
and rejected as unknown. prepare() now strips that launcher-only field. After
restart, decoded/proxy-ready/copy-ready/committed frame=360 and both running
stable-ime source command lines confirm the Linux and Mac routes restored.
HEADLESS-1 and HEADLESS-2 positions remained (3072,390) and (3072,1590).


## 2026-09-14 01:04 UTC: Mac geometry, shadows and application icons

Mac presenter now constrains the visible window body during local movement,
excluding shadow padding. Authoritative source frames bypass AppKit screen
constraints; passive frame correction no longer emits source geometry, and
subpixel differences tolerate one backing pixel. Pointer hit regions exclude
local shadow padding. Linux initial workspace selection excludes outbound
parking displays and selects the physical display by overlap/distance. The
regression test includes the reported Word rectangle (2609,1730,1357,809).

Windows-on-Mac shadow uses the Linux power-four falloff. Native Windows corner
residue is removed outside a fitted source-alpha corner, retaining the corner
estimate across partial resident updates of an unchanged window size.

Application icons now travel once per source window in bounded PNG metadata.
Windows applies native HWND icons and AppUserModelID; Mac applies individual
miniwindow images and the active proxy icon to the shared receiver Dock item.
Linux applies xdg-toplevel-icon when available and writes an app-id-matched
desktop icon fallback (live compositor reports wayland=0). Runtime logs confirm
Mac Notes on Linux; Finder and Calculator on Windows; kitty, Chrome, Word and
Feishu on Mac; Windows CMD on Linux has its desktop entry and PNG installed.
Independent per-application Dock processes are not implemented.

Validation: Linux 5/5 CTests, Windows presenter 3/3 and source 11/11 CTests,
Rust native_window_wire tests and release build, and Mac GPU/presenter/shadow
self-tests passed. Windows source test initially used a stale native_touchpad.hpp;
synchronizing the dependency restored the expected pressure encoding test.

Installed hashes: Mac helper/presenters b284c73759561004cde6bef3b3cee9892767815ea1495894769bce9a212662c2;
Windows presenter FD235C31BAFBFF96E24E8D894E6904CE3D45272207755F69C12F4DC235CD8F1F;
Windows source 8BF37B621384B71A8B74B3AC1E191C7D0D132C06DCD6A7FE38C353031A14F149;
Linux receiver c2f1953b5885d8d22873e33eaf577db042a710fb95ae46f18e2d22bda9427e2a;
Linux source f0dd05c8ddf16bcb297e7ad38f6ea6c8752ccc0499fef5c1dfd11ffe2a0ef92d.
Both Windows source routes use icons-fast, which includes the separately measured
oneVPL fast-init patch. Restarted parent peers to reload cached executable paths.
Live input, top-edge dragging, return-to-Linux placement, raising overlapping
windows and final taskbar/Dock appearance remain user-operated acceptance.


Follow-up: user reported Windows proxies on Mac no longer draggable. The new
whole-window shadow passthrough could disable mouse receipt while a button was
held but source move confirmation had not yet arrived. Keep mouse receipt enabled
for the entire physical button hold, including that confirmation phase; restore
padding passthrough after release. Added mouse-down diagnostics for geometry
ownership. Mac build and no-input presenter/GPU self-tests passed. Installed
helper SHA256 3638daa883289be0939621bca1cf8b048591fa0c47cecb7a3f8dddc463291ff1.
Restarted only the Windows-to-Mac presenter. This addresses a concrete capture
lifetime defect; user drag acceptance and causal confirmation are still pending.

Second user retry still had no dragging and unusable input. Mouse-down diagnostics
confirmed clicks reached the Mac proxy; the capture-lifetime hypothesis alone
was insufficient. Removed dynamic ignoresMouseEvents from interactive proxies.
Pointer mapping now transforms the actual displayed body rectangle into source
tile coordinates, rather than assuming source geometry equals AppKit placement.
This retains correct pixel targeting after independent AppKit constraints; the
previous removal of passive source geometry correction exposed that assumption.
Build/self-tests passed; Windows-to-Mac presenter restarted. User input acceptance
is still pending. Shadow-only click-through needs a separate surface, rather than
changing mouse receipt on the interactive window.


## Input-only pause and restoration — 2026-09-14

After the reported Windows freeze, both new body-only receivers were stopped;
Linux's media peer and the Windows atlas receiver were rolled back to the prior
protocol/runtime. The body-only atlas experiment had repeatedly ended after 11
native submissions with a disposition pipe write timeout; its cause remains
unresolved and it is not the active receiver. The Mac-input complaint likewise
has no new user acceptance and is not marked fixed.

During the user-requested input-only interval, Windows VDD was disabled and Mac
parking displays, all window streams, audio and clipboard streams were stopped.
Linux's two headless outputs remained necessary for input coordinate routing.
Windows input startup exposed an expired certificate still loaded by its old
server; restarting only that server loaded the already-renewed on-disk identity.
Both cursor connections subsequently exchanged valid clock probes.

With the user's later restoration authorization and confirmation that last
night's physical display state was restored, Windows interactive-session
inventory showed physical DISPLAY1 at 0,0 3840x2400 and VDD DISPLAY8/9 at
-6144,-780 6144x3456 and 0,2400 3078x2310. The layout task now uses these current
IDs; both VDD DPI readbacks verified 200%. The Linux desktop-source configuration
was updated accordingly. Mac physical bounds returned to 1539x1155 and its
parking bounds were verified at -3072,-1590 3072x1728 and 0,-1200 1920x1200.
Mac currently starts with components input, hid, windowsReceive and windowsShare;
audio and clipboard remain paused.

The Windows sender integrates the performance task's
`integrated-from-icons-fast.patch` and `alpha-cpu-from-integrated.patch` on the
current source, preserving the input diagnostics. Its installed path is
`C:\Users\wilf\Viewflow\desktop-test\viewflow_windows_reverse-perf-input-20260914.exe`,
SHA256 `0DDF4CA35B5B01FD0F0F012418C67C16D0FD47333525F0ECEC7AD9BBA865C8EA`.
Both reverse directions use it. The fresh Windows build passed 12/12 CTests;
alpha encoding additionally matched the existing encoder byte for byte and
decoded correctly for tiny, boundary, long-run and dense inputs up to 11.8 MB.
The restored Linux-to-Windows receiver passed 600 native submissions without
the prior failure. This is runtime submission evidence, not physical input or
latency acceptance. Windows-to-Mac currently reports no admitted window after
the restart, so it still needs a user-placed source window for performance
measurement. No synthetic input or focus changes were used.
