# Mac source windows displayed at half size on Linux

Live evidence before repair: the source sent 1480x1250 pixels with logical
geometry 740x625 and pixel scale 2. Hyprland showed a
ViewflowReverse-WindowsNative proxy sized 370x313 on DP-4 (scale 2).
The generated Linux receiver component omitted VIEWFLOW_REVERSE_MAC_SHADOW,
selecting the Windows physical-pixel convention for Mac logical-point metadata.

pairing_profiles.py now sets the existing Mac mode on Linux receivers whose
remote platform is macos. Windows receivers retain their previous convention.
A platform-pair regression checks both cases; a real three-member loopback group
test ensures the mode survives composition and is isolated to the Mac peer.
All nine profile tests passed.

The rebuilt Linux package was installed and the application restarted after its
managed process groups exited. Live read-back confirms the persisted component
has VIEWFLOW_REVERSE_MAC_SHADOW=1, the class is now ViewflowReverse-MacNative,
and the same system-settings window has geometry 740x625 at the same position.
The installed bundle's integrity check passed. No pointer/key event or focus
change was injected to test this repair.
