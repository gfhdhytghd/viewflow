import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.gd09c9n7/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.gd09c9n7/hyprland.lua'])
