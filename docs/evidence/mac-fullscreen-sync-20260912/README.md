# Mac source fullscreen synchronization

Mac capture inventory reads AXFullScreen for the unique AX window matching
its pinned PID and current bounds. Queries run on the background inventory
worker at title-refresh cadence; failed/ambiguous queries preserve the last
known state. Changes mark the frame dirty and use existing tile flag 32.
Transient popup windows do not advertise fullscreen.

Linux applies source transitions through xdg_toplevel_set_fullscreen /
xdg_toplevel_unset_fullscreen. While fullscreen or waiting for compositor exit,
ordinary position/size synchronization is skipped to avoid feeding Linux output
size back into the Mac native window. Geometry synchronization resets on the
transition and resumes after the compositor exits fullscreen.

Validation: both native builds passed; Linux reverse_wire and reverse_geometry
passed (2/2); Mac codec/pixel self-test passed. Candidate and installed app deep
strict codesign validation passed. Installed helper SHA256:
23f158f62fbc23f44c1c71597796c429bee22d494b9d234c79e4602a803aabad

Mac source restarted as PID 98861 and Linux receiver presenter as PID 445293;
paired frames resumed. No mouse, keyboard, focus or fullscreen test input was
injected. Actual enter/exit-fullscreen behavior remains user-operated acceptance.
The feature synchronizes Mac to Linux; it does not add the opposite direction.
