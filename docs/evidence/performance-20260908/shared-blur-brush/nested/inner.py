import os,pathlib
pathlib.Path('/tmp/viewflow-shared-blur-nested.r55ydf63/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-shared-blur-nested.r55ydf63/hyprland.lua'])
