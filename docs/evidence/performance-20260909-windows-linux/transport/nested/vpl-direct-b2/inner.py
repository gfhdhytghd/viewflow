import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.xr9t77xi/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.xr9t77xi/hyprland.lua'])
