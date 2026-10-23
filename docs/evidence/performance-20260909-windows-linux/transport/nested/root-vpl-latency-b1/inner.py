import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.yzls1f6f/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.yzls1f6f/hyprland.lua'])
