import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.i3icvs3e/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.i3icvs3e/hyprland.lua'])
