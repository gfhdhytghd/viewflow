import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.67t5bca_/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.67t5bca_/hyprland.lua'])
