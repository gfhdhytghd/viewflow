import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.v3pr9xiw/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.v3pr9xiw/hyprland.lua'])
