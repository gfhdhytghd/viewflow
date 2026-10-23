import os,pathlib
pathlib.Path('/tmp/viewflow-performance-mode-nested.2ticgscv/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-performance-mode-nested.2ticgscv/hyprland.lua'])
