import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.a9o58taw/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.a9o58taw/hyprland.lua'])
