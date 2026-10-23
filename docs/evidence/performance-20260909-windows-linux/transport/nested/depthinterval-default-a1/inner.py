import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.n3hv6965/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.n3hv6965/hyprland.lua'])
