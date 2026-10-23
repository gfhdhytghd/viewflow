import os,pathlib
pathlib.Path('/tmp/viewflow-commit-wakeup-grace-nested.52re22dg/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-commit-wakeup-grace-nested.52re22dg/hyprland.lua'])
