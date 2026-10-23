import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.pfq_3ae8/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.pfq_3ae8/hyprland.lua'])
