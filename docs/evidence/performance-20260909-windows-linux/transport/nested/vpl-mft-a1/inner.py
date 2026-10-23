import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.sp5b__8p/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.sp5b__8p/hyprland.lua'])
