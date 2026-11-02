# Proxy window lifecycle

Date: 2026-11-01. Branch: `proxylife`.

已完成：双向冻结逻辑、关闭请求路由和离线验证。
未验证：用户操作的双机窗口交互。构建结果不代表交互验收。

## Design and decisions

Window ownership and pixel residency have different lifetimes. Visibility is an
**enrollment** condition for a new source, not a withdrawal condition for an
existing source. Existing Linux identities use address + PID + stable ID. Mac
identities use CGWindowID + PID. A complete inventory without that identity
withdraws the source. A failed inventory retains it. Explicit disconnection,
removal of a destination, and actual process/connection failure still release
owned proxies and held input. There is no frame-age/session-exit timer.

A paused source keeps its receiver window, last pixels, and receiver placement.
An empty resident rectangle carries source membership without pixels. Both
presenters ignore its geometry as well as its pixel update: returning a source
to its physical screen must not push the frozen proxy off the receiving screen.
Negotiated activity membership includes dormant windows. Background-lane
throttling may omit pixel tiles without withdrawing those members.

The Mac presenter now keeps a complete CIImage per proxy. A partial rectangle
replaces only its own pixels, including transparent pixels; omitted rectangles
retain their old RGBA. Partial updates materialize a snapshot to bound the Core
Image dependency graph. Linux already has per-window retained GL color and alpha
snapshots. Decoder reset does not destroy those snapshots or their native
windows. New allocation/letterbox clearing does not clear the retained body.
Retaining old pixels costs one full snapshot per established proxy; no snapshot
is evicted merely because the source becomes invisible. Partial-update latency
and peak memory under a full set of 8 large windows remain unmeasured.

On Mac source suspension, retain the last capture sample instead of releasing
it. Publish empty residency while suspended. On resume, keep empty residency
until a complete ScreenCaptureKit sample arrives, then force a keyframe. On
Linux source suspension, keep the capture registration and skip rendering.
The first capture after skipped attempts forces an IDR. Receiver decoder errors
keep existing native surfaces and request keyframes through existing negotiated
feedback. Neither receiver clears its window before successful decode.

Close is a request to the owning application. The Mac delegate returns `NO`
after sending `InputKind::close`. The Linux xdg-toplevel close callback only
sends that request. Neither callback destroys its proxy. The Linux helper calls
`hl.dispatch(hl.dsp.window.close({window=w}))`, with exact address/PID/stable ID
validation. This close command also permits an existing unmapped window; other
input commands retain their mapped-target check. The Mac helper presses the
pinned native AX close button. It handles close before the dormant-input and
CG event-post permission gates, because AX close is independent of pixel capture
and pointer posting. The application may cancel close or show a save dialog.
Only subsequent source disappearance removes the proxy.

The Mac proxy's yellow button uses normal AppKit minimization. Live source
raise updates do not unminimize it. Its separate shadow stays hidden while the
proxy is minimized. No new minimize/close wire message was introduced.

## Protocol compatibility

No wire version, message kind, or capability was added. This change reuses the
existing resident-rectangle tile extension and existing negotiated activity
membership. Without activity negotiation, the source publishes an explicit
empty-residency tile instead of omitting an existing window. Activity omission
is used only when its complete membership mechanism was negotiated.

Old peers still parse the existing format and close kind. Full freeze behavior
requires the updated presenter and supervisor; an older receiver can retain its
older clearing behavior. Deploy this commit's source, presenter, supervisor and
Mac application together for the complete semantics. Hyprland plugins still
require a build matching the installed Hyprland ABI; this work does not change
that requirement.

## Audit table

Locations refer to this commit's source. “保留” means no additional change was
needed after source inspection; it does not claim live interaction validation.

| Direction / path | Source location | Result |
|---|---|---|
| Linux → Mac: viewport/workspace/hidden filter removed live children | `tools/macos-window-share-linux.py:50`, `:120`, `:135` | Changed: filters enroll new windows; every established exact identity remains until absent. |
| Linux → Mac: hidden/unmapped/missing-surface/no-monitor capture returned false and retired stream | `platform/viewflow-capture/src/window_renderer.cpp:283`; callers `platform/viewflow-capture/src/main.cpp:104`, `:241` | Changed: pause/retry; invisible workspace also skips capture. Actual missing window and identity replacement remain terminal. |
| Linux → Mac: receiver visibility crop, including zero area | `crates/viewflowd/src/bin/vf-hyprland-windows.rs:274`, `:539` | 保留：empty source-read list can encode metadata-only tile; receiver freezes it. |
| Linux → Mac: capture resumes after skipped attempts | `crates/viewflowd/src/bin/vf-hyprland-windows.rs:463`, `:484` | Changed: sequence gap forces IDR. Encoder resize and failed encode already force IDR. |
| Mac → Linux: Python on-screen/remote-viewport selection retired source | `tools/macos-window-source.py:63`, `:139` | Changed: retain existing CGWindowID/PID, including minimized, hidden and parked windows. Invalid inventory retries. |
| Mac → Linux: Swift selection and per-destination viewport filter stopped worker | `platform/macos-app/Sources/Configuration.swift:109`, `:292`; `platform/macos-app/Sources/AppModel.swift:325`, `:330` | Changed: retain existing normal window and its existing destination worker. New identities still use eligibility/viewport rules. |
| Mac → Linux: CG inventory visibility | `platform/macos/window_source.mm:125`, `:892`, `:936` | Changed: off-screen means pause; unavailable inventory does not prove destruction. Successful absent identity still closes source. |
| Mac → Linux: SCK recovery enumeration omitted window | `platform/macos/window_source.mm:748` | Changed: retry locally; SCK omission no longer withdraws a CG-live window. |
| Mac → Linux: parking/physical-display return, capture stop and latest sample release | `platform/macos/window_source.mm:698`, `:959` | Changed: retain sample and zero residency. Native stream can stop while source ownership remains. |
| Mac → Linux: resume before a new sample | `platform/macos/window_source.mm:79`, `:984`, `:1372` | Changed: wait for complete sample, then force keyframe. |
| Mac → Linux: idle/incomplete SCK sample | `platform/macos/window_source.mm:1306` | 保留：only complete samples replace capture pixels; idle/incomplete samples leave the previous sample. |
| Mac → Linux: material/backdrop cache suspension | `platform/macos/window_source.mm:866`, `:966`, `:988` | 保留：these are source helper caches; receiver snapshots remain. |
| Mac → Linux: activity/background throttling omitted tile or dormant member | `platform/macos/window_source.mm:1047`, `:1069`, `:1162` | Changed: dormant windows stay in complete membership. Negotiated omitted background tiles retain proxy ownership. |
| Mac → Linux: atlas capacity eviction and canvas shrink | `platform/macos/window_source.mm:1100`, `:1125` | Changed: eviction emits empty residency, instead of dropping the window tile. Canvas replacement does not clear retained receiver snapshots. |
| Linux → Mac: partial/empty crop reconstructed a clear image | `platform/macos/window_presenter.mm:636`, `:733`; `platform/macos/window_retained_image.hpp:8` | Changed: zero crop preserves window and placement; partial crop retains old pixels outside the patch. Transparent received pixels still replace old alpha. |
| Linux → Mac: cropped alpha disabled existing backdrop | `platform/macos/window_presenter.mm:548` | Changed: empty crop preserves backdrop state; partial crop conservatively retains translucency until complete replacement. |
| Mac → Linux: zero crop updates source geometry | `platform/linux-reverse/main.cpp:968` | Changed: metadata-only tiles retain both snapshot and local geometry. No blank proxy is created before first pixels. |
| Mac → Linux: color/alpha clear on crop or resize | `platform/linux-reverse/retained_surface.hpp:25`, `:43`, `:48`, `:80`; `platform/linux-reverse/main.cpp:744` | 保留：received rectangle replaces pixels; overlap survives resize. Only new storage and presentation letterbox bands clear. |
| Both: negotiated activity lane omission/epoch migration | `platform/reverse-common/activity_presentation.hpp:13`, `:33` | 保留：complete membership owns lifetime; omitted tile alone is not destruction. Old epochs cannot replace migrated proxy. Added pause/destruction regression assertions. |
| Both: queue pressure/idle/congestion pauses | `platform/reverse-common/activity_frame_queue.hpp:17`; `platform/macos/window_source.mm:1069`; `crates/viewflowd/src/bin/vf-window-peer.rs:53` | 保留：queues wait for keyframe after prediction-chain drop; background cadence and QUIC keepalive do not destroy windows for inactivity. |
| Linux → Mac: decoder reset | `platform/macos/window_presenter.mm:1163` | 保留：replace decoder only; existing proxies/images remain until a newly decoded frame presents. |
| Mac → Linux: decoder/progressive-lane reset | `platform/linux-reverse/main.cpp:1376`, `:1496` | 保留：decoder state resets; per-window retained surface remains. |
| Both: actual membership removal / source destruction | `platform/macos/window_presenter.mm:756`; `platform/linux-reverse/main.cpp:1024` | 保留：release input and erase only withdrawn source windows. Correct real-close completion path. |
| Both: native receiver teardown / broken connection | `platform/macos/window_presenter.mm:211`, `:766`; `platform/linux-reverse/main.cpp:220`, `:1550` | 保留：final resource teardown closes owned surfaces. Not a visibility optimization. |
| Mac proxy shadow hide/close | `platform/macos/window_presenter.mm:570`, `:579`, `:766` | Changed: local minimize also hides separate shadow. These paths never hide/clear the body proxy. |
| Mac proxy red/yellow buttons | `platform/macos/window_presenter.mm:649`, `:739`, `:1024` | Red requests real close and returns NO. Yellow remains native local minimize; source raise does not restore it. |
| Linux proxy close → Mac AX | `platform/linux-reverse/main.cpp:564`; `platform/macos/window_source.mm:482` | Changed: dormant source accepts AX close without event-post gate; no eager proxy/source removal. |
| Mac proxy close → Linux native dispatch | `platform/linux-window-input/main.cpp:226`; `platform/linux-window-input/window_identity.hpp:14` | Changed: exact existing target accepts graceful close even when unmapped; no process kill. |
| Native transient menus | `platform/macos/window_source.mm:794` | 保留：dismissed owned menu ends its transient source lifetime. A dismissed menu is not a minimized normal window. |
| Pairing routes / component stop / app stop | `tools/paired-linux-session.py:74`; `platform/desktop-app/runtime.py:276`; `platform/macos-app/Sources/AppModel.swift:133`, `:201` | 保留：explicit route/component/layout lifecycle, not per-window visibility. No new restrictions or timers. |
| Parking-display helper | `platform/macos/window_parking.mm:117` | 保留：owns virtual display lifetime, not receiver windows. Pixel suspension is handled by source residency. |
| Hyprland desktop ownership / recall | `platform/hyprland-plugin/src/desktop_window_controller.cpp:260`, `:275`, `:302`; `platform/hyprland-plugin/src/window_recall.cpp:61` | 保留：ownership record release/recall does not close or clear either native presenter. No edits in these agents' areas. |
| Rust atlas allocation / dynamic discovery | `crates/viewflowd/src/atlas_growth.rs:72`; `crates/viewflowd/src/gpu_atlas_device.rs:408`, `:787`; `crates/viewflowd/src/desktop_source.rs:690`, `:812` | Audited separate Linux→Windows atlas path: allocation/membership and full mapped inventory are distinct. Linux↔Mac uses `vf-window-peer` native backends (`platform/desktop-app/pairing_profiles.py:82`), not this Windows presenter path. No change to Windows semantics in this task. |

## Verification

Evidence: [`evidence/proxy-window-lifecycle/`](evidence/proxy-window-lifecycle/).
Stored transcripts normalize trailing whitespace; test messages are unchanged.
All native execution below used help, synthetic frames, codecs, policy tests,
EGL pbuffers, or Swift configuration tests. No live input, focus change, window
move/minimize/close, plugin load/unload, or service restart was performed.

| Check | Result | Evidence |
|---|---|---|
| `cargo test -p viewflowd` | 已验证：630 passed, 0 failed, 3 ignored across 19 result blocks; library 604 passed / 2 ignored. | `rust-test.txt` |
| `cargo test -p viewflowd --features native-gpu-nvenc --bin vf-hyprland-windows` | 已验证：1 passed; compiles the modified native source. No GPU capture started. | `rust-native-test.txt` |
| `cmake --build /tmp/viewflow-proxylife-linux -j 6`; `ctest --test-dir /tmp/viewflow-proxylife-linux --output-on-failure` | 已验证：17/17. Includes real off-screen retained RGBA/alpha tests, wire and activity membership. | `linux-ctest.txt` |
| `cmake --build /tmp/viewflow-proxylife-capture -j 4`; corresponding `ctest --output-on-failure` | 已验证：8/8; plugin compiled, never loaded. | `capture-ctest.txt` |
| `cmake --build /tmp/viewflow-proxylife-input -j 4`; corresponding `ctest --output-on-failure` | 已验证：2/2. Lua mock executes exact production graceful-close command; rejects PID/identity mismatch and accepts existing unmapped target. | `input-ctest.txt` |
| `cd platform/desktop-app && QT_QPA_PLATFORM=offscreen /tmp/viewflow-hid-ui-venv/bin/python -m unittest discover -p 'test_*.py'` | 已验证：76 run, 74 passed, 2 skipped. | `python-unittest.txt` |
| `python tools/tests/macos-window-source-test.py`; `python tools/tests/macos-window-share-test.py` | 已验证：selection/identity/hidden/workspace/off-screen retention, destruction and new-window eligibility assertions. | `source-selection.txt`, `linux-selection.txt` |
| Mac `cmake -S macos -B build -DCMAKE_BUILD_TYPE=Debug`; `cmake --build build -j 4`; `ctest --test-dir build --output-on-failure` | 已验证：30/30. Includes new actual CI pixel replacement/freeze/resume test and hardware H264/HEVC codec tests. | `macos-ctest.txt` |
| Mac `xcrun swiftc -parse-as-library macos-app/Sources/Configuration.swift macos-app/Tests/ConfigurationTests.swift -o configuration-tests`; `./configuration-tests` | 已验证：configuration, hidden-source retention, destination retention and destruction assertions. | `swift-test.txt` |
| Same Swift compile/run with `GroupConfigurationTests.swift` | 已验证：group configuration tests. | `swift-group-test.txt` |
| Full Mac Swift application compile/link with `Sources/*.swift`, `TrackpadBridge.swift` and embedded menu-backdrop object | 已验证：`Viewflow-test` built; never launched. Existing deprecation and actor-isolation warnings remain. | `swift-build.txt` |
| `git diff --check` | 已验证：no whitespace errors. | Working tree before commit. |

The capture build uses
`cmake -S platform/viewflow-capture -B /tmp/viewflow-proxylife-capture -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS=-Wno-error=maybe-uninitialized`.
GCC diagnoses existing address-only test locals in `ime_popup_scope_test.cpp`
as maybe-uninitialized under `-Werror`. This configuration downgrades that
warning without changing unrelated test/source files. The first compile also
caught the wrong workspace API name; the final plugin uses this checkout's
`Workspace::CHLWorkspace::visible()` and builds successfully.

Mac execution used only the newly created directory
`/Volumes/MoveDATA/viewflow-wifi-test/codex-proxylife/`, over
`ssh -o BatchMode=yes linhaikuo@10.42.0.125`. Native tools use
`/Volumes/MoveDATA/viewflow-wifi-test/tools-venv313/bin` on PATH.
No installed application, user configuration, service or running Viewflow was
changed. No production deployment was requested by this task.

## User-operated acceptance checklist

未验证：the following checks require the user's real desktop actions.
Use disposable application windows, including one with an unsaved document.

1. Share a Linux window to Mac. Minimize/hide it at the source, then move it to
   an inactive normal/special workspace. Confirm the Mac proxy remains visible
   at its last position with its last pixels. Move/focus that proxy locally.
2. Show the source again. Confirm live pixels resume in the same proxy without
   an empty/black intermediate frame. Repeat while source capture is throttled.
3. Share a Mac window to Linux. Minimize it to Dock and hide its application.
   Confirm the Linux proxy remains visible, movable and focusable. Restore the
   source and confirm the same proxy resumes without a flash.
4. Return the Mac source to its physical display, outside the remote viewport.
   Confirm its frozen Linux proxy stays at the receiver's last position. Move
   the source back into the remote viewport and confirm resume.
5. Partly cover/move a proxy off-screen, then reveal it. Confirm unsent areas
   keep their old pixels until replaced. Test a transparent window so received
   transparent pixels erase old content only inside the received rectangle.
6. In a test session, throttle the background lane, pause capture, resize an
   atlas, exhaust atlas pixel capacity and force decoder recovery. Confirm
   established proxies retain pixels, geometry and normal native interaction.
7. Click the Mac proxy's red button for an unsaved Linux document. Confirm the
   real Linux application offers its normal save dialog. Cancel it. Confirm
   the original source and proxy remain. Close again and accept; confirm the
   proxy disappears only after the source window disappears.
8. Close a Linux proxy for an unsaved Mac document through Hyprland. Check the
   symmetric save/cancel/accept behavior. Repeat while the source is paused.
9. Click the Mac proxy's yellow button. Confirm only that local proxy minimizes.
   Confirm source frames/raise updates do not restore it. Restore it locally.
10. Close one source while another stays paused. Confirm only the destroyed
    source's proxy disappears. Disconnect the actual link and confirm held
    keys/buttons release normally.

Do not treat these unchecked steps, or performance/memory targets, as passed.
