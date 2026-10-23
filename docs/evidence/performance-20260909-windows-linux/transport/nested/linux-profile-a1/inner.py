import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.7rtme1gx/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.7rtme1gx/hyprland.lua'])
