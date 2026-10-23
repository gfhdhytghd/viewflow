import os,pathlib
pathlib.Path('/tmp/viewflow-phase-follow-nested.b1j4agyr/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-phase-follow-nested.b1j4agyr/hyprland.lua'])
