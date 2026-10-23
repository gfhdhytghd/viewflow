import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.z0zm85_v/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.z0zm85_v/hyprland.lua'])
