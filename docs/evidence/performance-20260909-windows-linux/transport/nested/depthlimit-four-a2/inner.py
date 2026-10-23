import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.3qe6574f/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.3qe6574f/hyprland.lua'])
