import os,pathlib
pathlib.Path('/tmp/viewflow-production-pair-nested.7fs1f09s/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-production-pair-nested.7fs1f09s/hyprland.lua'])
