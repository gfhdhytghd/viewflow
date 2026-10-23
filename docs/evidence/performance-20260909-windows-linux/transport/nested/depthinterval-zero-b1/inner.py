import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.9ruk4vx3/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.9ruk4vx3/hyprland.lua'])
