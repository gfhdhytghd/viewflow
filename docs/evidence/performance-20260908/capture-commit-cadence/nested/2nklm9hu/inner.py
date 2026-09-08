import os,pathlib
pathlib.Path('/tmp/viewflow-commit-nested.2nklm9hu/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-commit-nested.2nklm9hu/hyprland.lua'])
