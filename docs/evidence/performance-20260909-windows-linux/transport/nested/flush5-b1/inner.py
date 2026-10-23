import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.x3uozr7s/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.x3uozr7s/hyprland.lua'])
