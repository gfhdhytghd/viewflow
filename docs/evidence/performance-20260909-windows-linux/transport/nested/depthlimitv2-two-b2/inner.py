import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.tisozeqw/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.tisozeqw/hyprland.lua'])
