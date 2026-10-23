import os,pathlib
pathlib.Path('/tmp/viewflow-mode-import-nested.i0fpidhe/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-mode-import-nested.i0fpidhe/hyprland.lua'])
