import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.8g3o_yy8/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.8g3o_yy8/hyprland.lua'])
