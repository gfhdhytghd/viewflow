import os,pathlib
pathlib.Path('/tmp/viewflow-gpu-poll-nested.ymbbovxe/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-gpu-poll-nested.ymbbovxe/hyprland.lua'])
