# Transient virtual-output mode candidate

Compiled candidate. MSVC Release build passed on 2026-10-09; no deployment,
mode test or mode change was performed for this implementation. Existing `configure`, `primary`, DPI,
and refresh command behavior is unchanged; new commands use a separate helper.

New commands (arguments below illustrate a later operator-owned test, not actions
performed by this agent):

```powershell
viewflow_virtual_display.exe transient-backup '\\.\DISPLAY6' 'C:\Temp\display6-before.vfdmode'
viewflow_virtual_display.exe transient-test 'C:\Temp\display6-before.vfdmode' 6144 3180 6144 3456 60
viewflow_virtual_display.exe transient-apply 'C:\Temp\display6-before.vfdmode' 6144 3180 6144 3456 60
viewflow_virtual_display.exe transient-restore 'C:\Temp\display6-before.vfdmode'
```

Confirm the actual executable target/path before running. Root must inspect
whether the selected output contains user windows before deciding to apply.
This utility never performs input/focus operations, relocates windows directly,
changes the primary output, or writes display settings to the registry.
The OS may relocate windows as a consequence of a mode change; window management
is outside the utility and should be considered by the caller before applying.

The backup is a CREATE_NEW, flushed, versioned Windows-local binary file. It
contains all active outputs' complete public DEVMODE values plus DisplayConfig
source/target adapter LUIDs, IDs, monitor device path, GDI name and primary state.
Private driver bytes are explicitly rejected if reported; they are not silently
truncated. Cloned active paths cannot identify one unique target and are reported
as unsupported. No D3D/DXGI capture dependency is added to the display utility.

The selected output must be an active non-primary virtual adapter. Before test
or apply, every saved identity and current display mode must still match the
baseline. CDS_TEST is checked for success and for an unchanged layout. Apply uses
ChangeDisplaySettingsEx with flags 0 on the selected output only. Readback checks
position, dimensions, bpp, refresh, orientation, fixed output and display flags;
other saved outputs must remain unchanged. It does not infer fractional pixel
clock accuracy from DEVMODE's integer refresh field.

On apply/readback failure, restore attempts the selected mode first and any
collaterally changed non-primary output afterwards, each with flags 0. It never
sets primary or replaces an output whose identity changed. Restoration validates
the entire saved layout. A topology or primary change that prevents exact restore
is explicitly reported as failure rather than claimed as recovery. The backup
file remains available after both success and failure.

Static validation performed locally:

- `git diff --check` passed for the helper and command dispatcher.
- Audited all three ChangeDisplaySettingsEx calls in the new helper: only
  CDS_TEST or flags 0; no UPDATEREGISTRY, NORESET or SET_PRIMARY path.
- Command argument counts and numeric ranges checked; invalid/trailing numeric
  characters and malformed/truncated backup records produce nonzero status.

Pending Windows runtime verification (no results asserted): backup
and load a real output; prove CDS_TEST leaves all modes unchanged; exercise a
supported transient mode and exact restore; try an unsupported mode and check no
layout mutation; simulate identity mismatch with a copied/edited test backup and
confirm rejection before apply. Actual output modes and ownership remain runtime
facts, not source/build proof.

Fixed compiled artifact: `build-16k/Release/viewflow_virtual_display.transient.exe`, SHA256 `4D604E0AE79D5DB81301CC1ECACF5F5C67282015AB3B2817E0BD489DAEDA90F7`. GPU occupancy reached 100%, so all runtime display/capture testing was deferred; only compilation ran.

## Rollback review correction

Every individual restore step now rechecks the freshly enumerated complete
output identity before either skipping an equal mode or issuing a mutation.
This prevents reuse of the same DISPLAYn between restore steps from redirecting
a write. Immediately before apply, the whole baseline is checked again; if it
changed before any apply call, no rollback is performed against that externally
changed layout. Win32 does not provide an atomic identity-and-mode transaction
through ChangeDisplaySettingsEx; the immediate check and subsequent readback do
not claim to eliminate the remaining OS hotplug race inside that API call.

Restoration explicitly sets the public display dmFields bits (position, width,
height, bpp, flags, refresh) while preserving original optional fields. Backup
payload sizing is checked before allocation/casts against DWORD I/O limits,
exact file length, nonempty count and valid selected index. Duplicate output
names in a backup are rejected rather than hiding a missing output.

Pure CPU C++20 test compiled with `-Wall -Wextra -Werror` and passed on Linux:
`platform/windows-reverse/virtual_display_transient_checks_test.cpp`. It covers
same-name identity replacement between writes, primary identity changes, missing
outputs, truncated/trailing data, multiplication overflow, invalid selection,
and preservation/addition of restore field-mask bits. These checks are called
by the production helper; the test does not call any Windows display API.

The corrected helper also passed the Windows MSVC Release build on 2026-10-09.
Fixed artifact: `build-16k/Release/viewflow_virtual_display.transient-v2.exe`,
SHA256 `8C584B306C723B8FB219D4F31FA9B3DF00E1569FBA3A19986C61659C96ADDA4C`.
This supersedes the first candidate for future tests; neither candidate has
changed a display mode. Runtime verification remains deferred while the host
GPU is saturated.

## Live mode transaction, 2026-10-10

With host GPU occupancy 6%, the fixed transient-v2 executable backed up all
three active outputs and passed CDS_TEST for DISPLAY6 at 6144x3456@60. A separate
owned hidden task applied that mode at (6144,3180), verified all other outputs
unchanged, and immediately restored DISPLAY6 to 3078x2310@60. Apply and restore
both returned 0; full-layout restore verification passed. DISPLAY5 remained the
primary 6144x3456 output and DISPLAY1 remained 3840x2400. No registry writes,
input injection or explicit focus changes were performed. The output had only
the desktop and secondary taskbar in the preceding visible-window inventory.

Evidence: `build/ivshmem-backup/fullscreen-output-inventory/test-mode.log` and
`apply-restore.log`. Windows-local backup retained at
`C:\Users\wilf\Viewflow\dd-mode-before-20261010.vfdmode`.
This proves this real supported mode transaction only; malformed backup,
identity replacement and failure recovery scenarios still have CPU/source
coverage rather than a live hotplug test. DD capture performance is not proven
by the successful mode transaction.
