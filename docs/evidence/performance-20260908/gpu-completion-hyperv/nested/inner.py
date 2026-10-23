import os,pathlib
pathlib.Path('/tmp/viewflow-gpu-completion-nested.8uifbici/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-gpu-completion-nested.8uifbici/hyprland.lua'])
