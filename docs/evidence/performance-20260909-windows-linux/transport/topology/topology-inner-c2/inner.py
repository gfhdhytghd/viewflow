import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.mnjstcp7/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.mnjstcp7/hyprland.lua'])
