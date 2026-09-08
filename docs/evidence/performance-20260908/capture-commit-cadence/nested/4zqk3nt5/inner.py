import os,pathlib
pathlib.Path('/tmp/viewflow-commit-nested.4zqk3nt5/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-commit-nested.4zqk3nt5/hyprland.lua'])
