import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.o457l9uc/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.o457l9uc/hyprland.lua'])
