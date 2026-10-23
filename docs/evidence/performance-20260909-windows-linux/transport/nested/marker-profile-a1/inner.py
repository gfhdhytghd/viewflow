import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.0c3uh0vg/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.0c3uh0vg/hyprland.lua'])
