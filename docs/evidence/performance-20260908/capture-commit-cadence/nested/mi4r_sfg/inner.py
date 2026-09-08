import os,pathlib
pathlib.Path('/tmp/viewflow-commit-nested.mi4r_sfg/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-commit-nested.mi4r_sfg/hyprland.lua'])
