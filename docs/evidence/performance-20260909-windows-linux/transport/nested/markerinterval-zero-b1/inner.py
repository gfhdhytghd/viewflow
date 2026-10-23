import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested._mcuzigq/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested._mcuzigq/hyprland.lua'])
