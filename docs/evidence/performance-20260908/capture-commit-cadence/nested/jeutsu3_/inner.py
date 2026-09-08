import os,pathlib
pathlib.Path('/tmp/viewflow-commit-nested.jeutsu3_/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-commit-nested.jeutsu3_/hyprland.lua'])
