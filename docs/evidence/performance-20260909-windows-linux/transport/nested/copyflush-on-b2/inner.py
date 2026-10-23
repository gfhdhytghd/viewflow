import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.k3crcdrt/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.k3crcdrt/hyprland.lua'])
