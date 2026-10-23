import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.xx0k9ck4/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.xx0k9ck4/hyprland.lua'])
