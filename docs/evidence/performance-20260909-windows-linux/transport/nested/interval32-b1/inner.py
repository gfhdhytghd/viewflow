import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.139v8gg1/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.139v8gg1/hyprland.lua'])
