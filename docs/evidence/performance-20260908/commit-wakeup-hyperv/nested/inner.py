import os,pathlib
pathlib.Path('/tmp/viewflow-commit-wakeup-nested.fex_v4u4/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-commit-wakeup-nested.fex_v4u4/hyprland.lua'])
