import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.rxze3ozy/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.rxze3ozy/hyprland.lua'])
