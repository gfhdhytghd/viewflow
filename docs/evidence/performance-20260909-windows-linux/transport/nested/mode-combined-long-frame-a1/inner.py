import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.v12zg2lj/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.v12zg2lj/hyprland.lua'])
