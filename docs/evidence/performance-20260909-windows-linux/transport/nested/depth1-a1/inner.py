import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.5v3b80ty/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.5v3b80ty/hyprland.lua'])
