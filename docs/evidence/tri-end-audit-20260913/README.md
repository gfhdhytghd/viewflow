# Three-end passive audit — 2026-09-13

Initial audit at approximately 16:17–16:25 EDT, before repairs or new deployment.
No synthetic input, focus changes, window moves, service changes, clipboard
writes or audio playback were performed by this audit.

| Window direction | Observed state |
| --- | --- |
| Mac → Linux | Active native frames and popup creation in Linux receiver logs; three Mac source/presenter pairs running. |
| Windows → Mac | Active paired stream; Mac presented-frame counter passed 233,520 and continued increasing. Two proxies, render completion rate around 45–47/s combined. |
| Linux → Mac | Source supervisor and Mac listener running; no enrolled source process at audit time. Historical frame log exists, followed by connection closure. Current six-way acceptance cannot be inferred from this idle route. |
| Mac → Windows | Windows receiver listener running on 44221; no active source/presenter. Last Mac source ended with SIGINT when window left this destination. Present configuration is prepared, but no current frame proof. |
| Linux → Windows | Not active. `viewflow-desktop.service` stopped; Windows `ViewflowMain-Active` is Ready, not Running. |
| Windows → Linux | Not active. This reverse stream belongs to the stopped duplex desktop route. |

Linux has DP-4 at (0,0), HEADLESS-1 at (3072,390), HEADLESS-2 at
(3072,1590). The dormant desktop service refers to absent HEADLESS-13; its
source config still names Windows 172.16.105.70 rather than the live discovered
172.16.105.131. Its configuration lacks the discovery block used by the working
cursor service. These are concrete stale configuration issues, not a network
reachability failure.

The dedicated Windows cursor service conflicts with the duplex desktop service.
Restoring the latter must account for that ownership switch. Source inspection
finds that `AtlasSourceInput` already uses native raw touchpad packets and the
shared cursor handoff implementation. The Windows scheduled main script enables
`VIEWFLOW_WINDOWS_INPUT_SERVICE=1`. Desktop auto-enrollment requires its input
lane, so deleting pointer configuration is not a valid video-only configuration.

## Other configured routes

- Linux → Windows and Linux → Mac cursor QUIC connections both continuously
  accept clock probes. Mac HID logs record real ownership changes and recovery.
  These establish control-channel health, not user-visible cursor or gesture
  acceptance. Physical input origin remains Linux; direct Mac-origin and
  Windows-origin physical input services were not observed.
- Mac → Linux and Windows → Linux audio block counters increase about 1,000
  blocks per five seconds. Mac blocks were silent (peak 0), Windows peak 1 in
  this sample. No configured reverse audio or Mac ↔ Windows audio route was
  observed, and audibility was not tested.
- Linux ↔ Mac clipboard peers are running; Linux logged a real installed
  clipboard payload at 16:02:45. No Windows clipboard peer process was found.
  No clipboard content was captured or changed during this audit.
  The stopped Linux/Windows atlas session includes its own automatic clipboard
  lane; restoring it should restore that pair without a standalone duplicate.

## Optimization application and version drift

- Windows → Mac source logs confirm `reverse_direct_single_surface enabled=1`,
  `reverse_capture_changes enabled=1`, hardware VPL encoding, a pooled encoder,
  and `reverse_alpha_summary enabled=1`.
- Mac → Linux source logs confirm the worker pipeline, HEVC, requested native
  scale 2 and 60 FPS target, and unchanged-frame skips. Static-content completion
  rates must not be interpreted as a 60 FPS animation benchmark.
- All three live Linux Mac presenters match current
  `build/window-mesh-linux/viewflow_linux_reverse`, SHA-256
  `ed9c1a7a0a421b15f583155a34c34c171a3fd49847ff9477e2e21e3d76839a78`.
  The dormant desktop reverse executable differs:
  `6dcc581c8d9db42088dfbabd86fe6d934655bfdfcf2fb9b3ff95ba6fc214464d`.
- Installed Mac helper and active Finder source helper match SHA-256
  `e71e12328b77ff7f4cb4d51f85e864e292428fa8eb09e09a013ca3d5d64fa352`.
  Active Windows → Mac presenter uses its previous session copy, SHA-256
  `2fbd5b4b2f8fc4eeb7b011464479a4de61df0682f3e836e87160e2392f466fcf`.
  Therefore installation alone did not update every running component.
- Linux → Mac installed capture helper differs from the unified-app payload
  (`f381e86a...` versus `655f5f99...`); a different hash alone does not establish
  which source optimizations differ.

This initial snapshot does **not** support a claim that all six window routes
are active, all optimization changes are running, or all input/audio/clipboard
directions are supported and accepted. Subsequent repair and deployment should
be recorded separately from this baseline.

## Windows Rust build prepared after audit

Current workspace `Cargo.toml`, `Cargo.lock`, `crates/`, and `protocol/` were
copied to the existing Windows `unified-app-20260910/source` tree. The x64
Visual Studio build environment and existing Cargo target cache built
`cargo build --locked --release -p viewflowd --bin vf-media-peer` successfully.
The result at `C:\Users\wilf\Viewflow\unified-app-20260910\target\release\vf-media-peer.exe`
has SHA-256 `8C15216A32EE2B5EBF56563EDAA50035B9BA03BE33DC69E633F4C4636B20F841`.
Its `validate-receive` check passed against the existing Windows desktop
receiver configuration. This audit agent did not install the executable or
restart the stream. Validation output is in `windows-rust-build.txt`.

## Current Windows native builds prepared

Current composition/video-compositor source, reverse source, window presenter,
capture source and shared reverse headers were staged under the independent
`C:\Users\wilf\Viewflow\composition-audit-20260913` directory. The final shared
residency header and Windows source/presenter hashes were rechecked against the
Linux workspace after the last source sync. No live files or services changed.

| Relative artifact under stage directory | SHA-256 | Registered tests |
| --- | --- | --- |
| `build\Release\viewflow_windows_composition_preview.exe` | `A3EA79850447862901154CFE62849170BDF1275E67C230989EA5A0D97B35A205` | 35 passed |
| `build-reverse\Release\viewflow_windows_reverse.exe` | `4A6215E7C1E37632CED557BC96E9469794E90DC763030250E0D48A8323BBE8F9` | 7 passed |
| `build-presenter\Release\viewflow-windows-windows.exe` | `9B4CBDBF6017A6DD497BF507928FFE631FF887C2125A0A905D54F5348480738C` | 2 passed |

Composition enables the existing FFmpeg shared 8.1 distribution for AV1.
The first all-target build exposed an omitted observer helper header in the
staging archive; copying that current header resolved the staging error.
Final logs are `windows-composition-build-final.txt`,
`windows-reverse-build-final.txt` and `windows-presenter-build-final.txt`.
Only registered tests ran; manual GPU/desktop window probes were not executed.

The subsequent zero-resident capture-version guard update rebuilt Windows
reverse at the same artifact path, replacing its earlier build hash with
`2F0D6274AD730EE8D092EF7EB57166EB8DA6BBFEA18ECC2F19E7DB72E6048221`.
All seven registered tests passed again. Remote `main.cpp` matches local
SHA-256 `C450A7D332594DAE0AFBF50CB05D87EEE279F2BD0F332DDB09DAFE5DAB457E6F`.
See `windows-reverse-build-zero-resident.txt`. This build was not deployed by
the audit agent.

## Windows per-window silhouette and shadow source update

The source now keeps the captured per-window alpha shape and adds a GPU-derived
soft black shadow around that shape. It does not impose a common corner radius.
DWM corner preference is cached for diagnostics only: the documented preference
is a hint, and actual DWM rounding can differ in maximized/snapped/VM contexts.
See [Microsoft's rounded-corner guidance](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-rounded-corners).
Opaque captured body pixels remain unchanged. The shadow is a generated effect
based on the captured silhouette, not a claim of pixel-identical native DWM
shadow capture. Maximized windows and composition-disabled contexts add no
shadow padding. Per-window DPI controls the 24-DIP padding.

Existing flags16 carries body geometry: `tile.x/y` remains the physical Windows
body origin, body/logical dimensions remain physical capture pixels,
`pixel_scale=1`, and body offsets identify padding. Receivers must apply their
configured output scale to these Windows physical dimensions; Mac source point
coordinates retain their separate existing contract. The frame-change tracker
now includes body/logical/scale metadata in its change decision.

GPU commands are recorded on a deferred context and submitted as one command
list with immediate-context state restoration, avoiding capture/encoder render
state interference. Runtime has no new CPU pixel readback. A WARP test uses only
owned offscreen textures to check distinct square and differently rounded alpha
shapes, opaque color preservation, and nonzero black shadow outside the body.
All nine registered Windows reverse tests pass. User-visible cross-host corner
appearance and sustained performance remain live acceptance checks.

Final source artifact at the same reverse build path has SHA-256
`2A11E6FBFC77EE636B4CD219556F06C28EDB4F92C1241C5CC678AD702EB93189`.
See `windows-reverse-build-decoration-final.txt`. No deployment was performed
by this agent.

### Follow-up: same custom shadow recipe as the Mac path

The final follow-up replaces the initial silhouette blur with the Mac custom
shadow recipe from `platform/hyprland-plugin/src/macos_shadow.cpp`:
range/inset/offset/radius/opacity `(88,13x14,17.5,35.5,0.233)` and
`(74,0x0,19,27,0.107)`, plus a two-point contact lobe at opacity 0.32.
The broad lobes use analytic rounded-rectangle distance and power-four falloff;
they require no texture convolution. Only the two-DIP contact boundary samples
source alpha. Body RGBA, including its individual actual corners, is returned
unchanged. Shadow padding is now 108 DIP (scaled by the source window DPI).
This draws a Viewflow shadow instead of forwarding a native Windows shadow.

If the WGC extent matches `GetWindowRect`, exact DWM extended-frame bounds
identify and remove exterior native frame padding before drawing. No guessed
texture origin is used when these dimensions differ; the ordinary WGC body
capture retains its existing coordinates.

The WARP GPU oracle checks the broad-lobe profile against the Mac recipe to
one alpha byte, distinct captured corner shapes, body color preservation, and
generated black exterior shadow. Nine CTests pass. A separate hardware-D3D
owned-texture benchmark rendered 60 frames of 1920x1080 body content with
108-pixel padding in 29.257 ms total, 0.488 ms/frame amortized including command
submission and completion. This is an isolated effect throughput measurement,
not a capture-to-display or per-frame latency measurement. No desktop window,
focus change or input injection was used.

Frozen unique artifact:
`C:\Users\wilf\Viewflow\composition-audit-20260913\build-reverse\Release\viewflow_windows_reverse-mac-shadow.exe`,
SHA-256 `59D4B4BDA7C3A7C9684420FE21948A8551E70DD213AB3C606046874967A01230`.
See `windows-reverse-build-mac-shadow-final.txt`. The source remains undeployed
by this audit agent.

### Final correction: body-only source, destination-owned shadows

The user's screenshot rejected source-rendered shadow pixels as part of the
window tile. The final Windows source therefore removes all shadow composition
and extra padding. Its executable no longer links the shadow GPU helper.
Only the unchanged captured body alpha/color is copied, with the proven DWM
extended-frame crop retained. Existing flags16 now carries zero body offsets,
full-body logical/physical dimensions and `pixel_scale=1`. Local receiver or
compositor decorations own shadows. The earlier shader helpers/tests remain
available but are not used by the production source executable.

Nine registered tests pass, including body-only metadata validation. Frozen
artifact `C:\Users\wilf\Viewflow\composition-audit-20260913\build-reverse\Release\viewflow_windows_reverse-body-only.exe`
has SHA-256 `8C32EBAB8E8E0611A82BDAC5414E90A1A985854308734AED35483C36AAEEA5DB`.
See `windows-reverse-build-body-only.txt`. No deployment was performed by this
audit agent.

### Body-only source: IME scheduling follow-up

The initial source enumerated windows every 50 ms unless a native move was
active, did not wake discovery after key/button delivery, and scheduled the
first candidate frame on the ordinary 60 Hz grid. Frame-rate mode admitted up
to four pending frames. The follow-up adds a 500 ms preference after delivered
key/button events or IME show/hide notifications: discovery at 8 ms intervals,
candidate capture startup before ordinary new windows, and one newly admitted
pending frame while existing work completes. Event-triggered discovery is
also bounded to one scan per eight milliseconds. IME show/hide events cover
first candidate appearance when keyboard input uses the separate cursor lane.

A candidate's first captured frame may bypass one ordinary frame-grid wait;
the notification remains pending while encoder capacity is unavailable. Normal
body windows remain in the same atlas and continue receiving service. The
source neither changes system/thread priority nor disables Windows menu
animations. Body-only geometry and source-alpha preservation remain unchanged.
Logs `reverse-ime-first-capture` and `reverse-ime-first-submit` report elapsed
microseconds since source discovery. No actual user input was injected, so no
end-to-end IME latency improvement is claimed from these build checks.

Ten registered tests pass. Frozen unique source artifact
`C:\Users\wilf\Viewflow\composition-audit-20260913\build-reverse\Release\viewflow_windows_reverse-body-only-ime.exe`
has SHA-256 `98EBC2801A637D137D83AEE12564987549F5F00ACAC3AAF1F15A29C983E6A1B6`.
See `windows-reverse-build-body-only-ime.txt`. Deployment remains with the main
agent.

## Repairs and final installed state

The desktop source now resolves Windows through its existing stable discovery
configuration and reuses HEADLESS-1. Current native-GPU-enabled Linux and current
Windows media peers replaced the dormant copies. The combined desktop service
now owns the Windows input route (raw touchpad + Windows input service); the
conflicting cursor-only service is disabled, and desktop startup is ordered
after the three-screen layout. Mac HID remains on its independent route.

Current Windows composition, reverse and window-presenter executables were
built and installed. The reverse helper uses an explicit versioned filename
because the old executable was still mapped; both configured source routes
now point to that new file. Current Mac helper was signed in place and every
active source/presenter was reconnected with the new helper, without restarting
the parking-display owners or injecting input. Both Linux reverse installation
paths now use the same current receiver.

Final passive evidence:

- Linux→Windows: 6,000+ completed frame identities after the final restart;
  sparse logs show 4,496,192 input pixels, 3,995,072 resident pixels, 500,736
  occluded and 384 empty pixels omitted. Import cache has 5,997 hits/6,000
  imports in the sample. Windows decoder/compositor completion logs match.
- Windows→Linux: paired reverse source/presenter running, hardware VPL depth2
  selected. Its current window belongs beyond the physical Linux viewport;
  visibility feedback shrank the encoded atlas from 2368×1408 to the 192×192
  codec floor, retaining window metadata. This is actual invisible-pixel
  reduction, not a claim that this offscreen proxy is physically displayed.
- Mac→Linux: active source and GPU presenter pairs, HEVC, native scale2,
  unchanged-frame skipping and residency counters. Current visible main
  windows correctly retain their full resident rectangles.
- Windows→Mac: active completed frames after final reconnect; latest sample
  ~50.85 render completions/sec across two proxies. This is aggregate
  completion rate, not per-window physical refresh acceptance.
- Linux→Mac and Mac→Windows: paired listeners/supervisors and matching new
  binaries installed, but no currently enrolled source window. User-operated
  dragging is still needed for final live frame/appearance acceptance.
- Both audio-to-Linux services, Mac clipboard, combined Windows desktop and
  independent Mac HID/input services remain active. Windows clipboard uses
  the restored atlas lane. Native paste/audibility were not injected or tested.

The menu budget is now 30 capture pairs/sec shared by menus in one source,
with one pair in flight. No user-opened menu sample from the final version was
available, so 30 is a tested limit, not a measured sustained menu rate.

Residency covers viewport clipping, zero-pixel retention, inactive workspaces/
Spaces/minimized proxies, known outgoing Viewflow displays, and bounded edge
prefetch. It does not implement forward-atlas multi-patch alpha-cell or
opaque-overlap/prerender policies on the four Mac-related routes. The detailed
parity matrix is in docs/occlusion-and-transparency.md.

Validation: Linux CTest4/4, Windows composition35/35, Windows reverse7/7,
Windows presenter2/2, Rust wire/crop tests and native GPU empty-atlas checks
passed. Mac warnings-as-errors build and deep/strict signature verification
passed. The 30FPS budget test and git diff whitespace check passed.
