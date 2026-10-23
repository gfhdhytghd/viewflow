# Windows virtual-display slowdown: read-only investigation

Observed 2026-09-14, approximately 20:08–20:14 America/New_York.
No display changes, driver reloads, input injection, or process termination.

## Conclusion and limits

The installed official MTT 24.12.24 driver contains a concrete multi-monitor
swapchain ownership defect. Both active virtual monitors share one device context
and one `m_ProcessingThread`. Assigning either monitor resets the other monitor's
processor; unassigning either also resets that shared processor. This is the
leading explanation for the reported slowdown after enabling virtual displays.
Upstream fixed this exact ownership issue in commit
`fc499471c1deaa70cae5af5cb25dd4a22b8269c9` (2026-04-11).

The running machine has the affected binary and two active virtual monitors.
Sustained handle growth supports a resource-lifecycle problem, but no ETW
swapchain trace or one-versus-two-monitor intervention was performed. Therefore
the defect's presence is confirmed; its share of this user's observed stutter
and the exact origin of growing handles remain unmeasured.

## Current identity and topology

- Windows 11 Pro 10.0.26100; last boot 2026-09-14 15:33:35 local.
- Intel Graphics driver 32.0.101.8860.
- MTT root device `ROOT\DISPLAY\0000`, INF `oem2.inf`.
- INF DriverVer `12/24/2024,11.30.4.434`.
- Loaded module `C:\Windows\System32\drivers\UMDF\mttvdd.dll` in WUDFHost PID 1216.
- Installed DLL SHA256:
  `c9ca837f57a98fbd43bc416a7f535a95843626e7759eaf85cf0cd7ce334dbb05`.
  This exactly matches MttVDD.dll read from the official
  `Signed-Driver-v24.12.24-x64.zip` release asset, downloaded for hash comparison
  only (not installed or executed).
- Native display utility enumeration: DISPLAY1 physical 3840x2400 at (0,0),
  primary; DISPLAY8 virtual 6144x3456 at (-6144,-780); DISPLAY9 virtual
  3078x2310 at (0,2400). Both virtual outputs are attached.
- VDD XML: monitor count 2, Intel Graphics preferred, both modes 60 Hz,
  HardwareCursor true, SDR10bit/HDRPlus/logging/debuglogging false.
- WinForms Screen enumeration from SSH Session 0 returned WinDisc 1024x768;
  that is not the interactive desktop and was excluded from topology evidence.

## Passive observations

Two sampling intervals, without generating mouse/keyboard activity:

| Local time | DWM PID 1540 handles | WUDFHost PID 1216 handles |
|---|---:|---:|
| 20:10:01.617 | 7529 | 4265 |
| 20:10:06.678 | 7589 | 4305 |
| 20:10:11.688 | 7649 | 4345 |
| 20:10:16.697 | 7709 | 4385 |
| 20:10:21.716 | 7769 | 4425 |
| 20:10:26.722 | 7829 | 4442 |
| 20:10:31.734 | 7889 | 4479 |

DWM grew by 360 handles in 30.117 seconds (~12/sec). Its private bytes stayed
near 581.27 MB decimal (~554 MiB), so this interval does not show a large private
memory leak. WUDFHost grew by 214 net handles with some interim reclamation.
An earlier interval also showed DWM +360 handles in about 30.6 seconds.

Six system samples from 20:09:09 to 20:09:39: CPU 5/24/16/9/18/7 percent;
available memory 13237–13265 MiB; pages input/sec 0; disk queue 0; DPC 0;
interrupt time 0–1 percent. Process CPU deltas over the sampling run were
WUDFHost 1.22% and Viewflow Windows source 0.15% of total logical CPU capacity.
No active clang/ninja compilation was found. This does not reproduce the older
compile-related CPU saturation incident.

GPU adapter shared allocation was approximately 2.13 GB. GPU engine counter
enumeration returned no instances, so GPU utilization is unavailable, not zero.
System warnings include a boot-time WUDFRd load warning for ROOT\DISPLAY\0000;
the device is currently OK with its driver loaded. That warning alone does not
establish current driver failure.

## Source mechanism and upstream status

In tag 24.12.24, Driver.cpp line 2417 assigns each monitor's context to `this`;
lines 2441–2460 reset the shared processor and initialize a fresh D3D device
twice before creating its replacement. Lines 2513–2517 reset the same processor
without a monitor argument. Driver.h line 99 has only one processor pointer.

Hardware cursor setup creates a named event on each assignment, retains no
owner for its handle, and only closes it on setup failure (lines 2463–2498).
This is a separate source-level handle-lifetime concern; process handle types
were not collected to prove which allocations caused the observed growth.

Upstream commit fc49947 stores processors per IDDCX_MONITOR and unassigns only
the specified monitor. It also reduces disabled-logging overhead and changes
idle buffer waiting. The hardware-cursor success-path ownership concern remains
in the inspected master source and deserves separate review before deployment.

GitHub latest-release API still reported 25.7.23 (published 2025-07-23).
The 25.7.23 source also has the shared processor; upgrading to that release
alone does not incorporate fc49947. No fixed signed package was verified.

## Next validation / repair

The shortest causal comparison is identical user-operated workload with two
versus one attached virtual monitors, then restoration of the exact saved
topology. It would interrupt part of the user's cross-screen setup and was not
performed during this read-only investigation. Capture DWM/WUDFHost handle
slopes and actual presentation timings, not just average CPU.

A lasting repair needs per-monitor swapchain ownership and explicit cursor-event
lifetime management in a normally signed driver package. Preserve current
resolution/scale/position when testing; lowering 6K resolution alone would
confound the ownership defect with pixel-load changes.

## Primary sources

- [Affected 24.12.24 source](https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/24.12.24/Virtual%20Display%20Driver%20%28HDR%29/MttVDD/Driver.cpp)
- [Official signed package](https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/tag/24.12.24)
- [Multi-monitor fix fc49947](https://github.com/VirtualDrivers/Virtual-Display-Driver/commit/fc499471c1deaa70cae5af5cb25dd4a22b8269c9)
- [Two-monitor lag issue 140](https://github.com/VirtualDrivers/Virtual-Display-Driver/issues/140)
- [Second-monitor slow rendering issue 445](https://github.com/VirtualDrivers/Virtual-Display-Driver/issues/445)
- [Multiple-monitor performance issue 449](https://github.com/VirtualDrivers/Virtual-Display-Driver/issues/449)
- [Microsoft IDD sample guidance](https://learn.microsoft.com/en-us/samples/microsoft/windows-driver-samples/indirect-display-driver-sample/)

## Update deployed at user request

User authorized updating the driver, including compiling it if necessary.
Backported per-monitor ownership onto tag 24.12.24 rather than adopting unrelated
master changes. Added one owned unnamed hardware-cursor event per monitor,
removed duplicate D3D initialization, and checked two XML getter results flagged
by the compiler. The exact built source and logs are in
`fix/build-and-observations.tar`; `fix/multi-monitor.patch` is relative to the tag.

Built Release x64 with VS 2022 / WDK 10.0.26100.0. Installed the missing VS ATL
component. Legacy static-analysis warnings remain in upstream code; `/WX-` lets
those remain warnings. The WDK MSBuild INF verifier DLL was unavailable, so
`SkipPackageVerification=true` was used; standalone Inf2Cat signability checks
passed with no errors/warnings. Final MSBuild exit code was zero.

Windows already had `testsigning Yes` before this work. Reused its existing
WDKTestCert private key and installed that public certificate in LocalMachine
Root/TrustedPublisher. No boot policy or Secure Boot change was made. DLL and
catalog signatures verified with signtool. This is a locally test-signed build,
not a Microsoft production-signed release.

Installed via pnputil onto the existing ROOT\\DISPLAY\\0000, without creating a
second adapter. Active version is **11.30.4.435**, INF **oem17.inf**, DLL SHA256
`b1decfadc04ed658162c21cde7e3894392360c01b7019439ac06b68c793c259d`.
WUDFHost PID changed from 1216 to 16820 and its module list contains the installed
DLL. DWM PID 1540 remained running.

Interactive-session readback confirms the physical primary monitor and both
virtual monitor positions/resolutions were retained. Windows changed the virtual
GDI display names: Linux target DISPLAY8 -> DISPLAY7; Mac target DISPLAY9 ->
DISPLAY8. Updated only `windows_virtual_display.device` in the Linux persistent
`desktop-source.json` to DISPLAY7. Its launcher rereads that template before
media activation, so no input-service restart was needed. VDD XML hash before
and after is identical. No mouse/keyboard input or focus change was generated.

Post-update 20:41:07–20:41:37, seven samples:

- DWM handles: 29707, 29707, 29707, 29704, 29704, 29704, 29704.
- WUDFHost handles: 392, 392, 392, 391, 391, 391, 391.
- A subsequent sample: DWM 29676; WUDFHost 391.
- DWM private memory was approximately 442 MiB; no forced DWM restart was done
  to discard old accumulated resources.

The previous continuous handle growth stopped with the updated driver and both
virtual displays still attached. This is runtime evidence of the lifecycle
repair; physical drag/animation smoothness still requires user acceptance.

Windows package, exact source, logs, original exported signed driver, unchanged
VDD XML, display-registry backup, and an explicit rollback script are retained
under `C:\Users\wilf\Viewflow\vdd-fix-20260914`. `rollback.ps1` forces the original
exported package onto the same hardware ID if rollback is needed; it was prepared
but not run. The driver update did not require a reboot.
