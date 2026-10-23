import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.8ctujnab/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.8ctujnab/hyprland.lua'])
