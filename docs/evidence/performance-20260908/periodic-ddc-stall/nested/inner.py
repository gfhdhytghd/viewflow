import os,pathlib
pathlib.Path('/tmp/viewflow-ddc-stall-nested.9yxz64d1/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-ddc-stall-nested.9yxz64d1/hyprland.lua'])
