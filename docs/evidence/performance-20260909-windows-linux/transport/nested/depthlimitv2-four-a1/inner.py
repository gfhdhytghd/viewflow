import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.g6tah7if/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.g6tah7if/hyprland.lua'])
