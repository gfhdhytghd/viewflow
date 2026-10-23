import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.0cp77wpy/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.0cp77wpy/hyprland.lua'])
