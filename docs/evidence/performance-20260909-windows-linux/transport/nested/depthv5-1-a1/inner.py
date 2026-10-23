import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.watjtfyo/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.watjtfyo/hyprland.lua'])
