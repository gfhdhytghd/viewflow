import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.u5s8iez7/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.u5s8iez7/hyprland.lua'])
