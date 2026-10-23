import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.dhoml5u0/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.dhoml5u0/hyprland.lua'])
