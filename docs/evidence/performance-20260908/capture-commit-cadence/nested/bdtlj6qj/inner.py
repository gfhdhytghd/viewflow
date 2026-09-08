import os,pathlib
pathlib.Path('/tmp/viewflow-commit-nested.bdtlj6qj/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-commit-nested.bdtlj6qj/hyprland.lua'])
