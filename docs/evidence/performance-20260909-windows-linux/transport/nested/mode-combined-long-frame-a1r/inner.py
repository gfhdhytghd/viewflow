import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.a0zl6cmr/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.a0zl6cmr/hyprland.lua'])
