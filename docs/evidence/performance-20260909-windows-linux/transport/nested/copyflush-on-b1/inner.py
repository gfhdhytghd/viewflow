import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.0fe4_5zq/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.0fe4_5zq/hyprland.lua'])
