import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.w4n0tir9/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.w4n0tir9/hyprland.lua'])
