# Dolphin visual test, pending acceptance

User explicitly selected the Dolphin on the current workspace. Read-only
Hyprland inspection found exactly one mapped, nonhidden `org.kde.dolphin`
on workspace 5, address `0x56057975e2b0`, PID 137195. No files were opened or
manipulated and no plugin was reloaded.

Loaded HyprCapture own-interface one-shot capture returned visible geometry
(612,1247,760,626), full decorated geometry (603,1238,778,650), and physical
1556x1300. VFBG file `dolphin-window-1950.vfbg` is 8,091,220 bytes, mode0600,
SHA256 `5a9f4d17f3c9f429428a49fcf27eb37fbf55a0dd0abef7c96ef43e12b4286547`.

One bounded raw transport attempt used logical778x650 and16MiB byte budget.
Windows candidate SHA `a678ae63526059e0ee6e0aa8931604b1a287901f6e286a4479f7308897ce1ac4`.
Sender exited1, explicit late rejection: code2, packets595, chunk705/5941,
normalized source age34,433,936ns, uncertainty1,044,724ns. Queued1518 packets;
terminal47,910,300ns. This frame was not submitted for display. A30-second
visibility option does not override freshness rejection.

Receiver PID18508/Session1 confirmed `dropped(Late)` at35,026,370ns and
zero native submissions. It exited0 (attempt processed, not display success).
The exact task `Viewflow Raw Visible Retest 20260904-1945` was removed after
exit; raw peer processes were absent and Deskflow6388/8868 remained untouched.

Next diagnostic is local-only native preview of this exact transferred file,
to separate decoration/rendering inspection from the failed transport test.
It must not be reported as successful cross-host streaming or latency proof.

## Local native preview completed

The exact snapshot was copied to the user's Windows private test directory;
its SHA matched. Native preview EXE SHA was
`425633ed4ccd8f32116a2d08b11a2ae742da548957b5df23fa02488e3e203a96`.
Task `Viewflow Raw Window Preview 20260904-1955` ran PID10940/Session1 and
reported input1556x1300, logical778x650, proxy DPI192, submission27,348,610ns,
then pumped the HWND for30,000ms and exited0. At DPI192 the target equals the
source pixel dimensions, so the present_logical path does not resample here.
The user subsequently confirmed semitransparency looked normal, but backdrop
blur was absent. This confirms the missing blur path, not complete visual
acceptance. Current per-pixel alpha blending is not destination backdrop blur.

The exact task was removed, preview process absent, Deskflow6388/8868 preserved.
Logs remain under
`C:\Users\wilf\AppData\Local\Temp\viewflow-raw-window-preview-test-20260904-1955`.

A subsequent profiled local preview (PID1828/Session1, exit0) measured:
resample0ns, DIB allocation386,900ns, pixel copy3,892,610ns,
UpdateLayeredWindow25,486,400ns; total29,820,290ns. This single sample places
most measured submission time inside the Win32 call, not resampling. It does
not establish steady-state cost or physical scanout timing. The exact profiled
test task was removed, process absent, original Deskflow preserved.
