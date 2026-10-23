import os,pathlib
pathlib.Path('/tmp/viewflow-mmcss-canonical-nested.k1vvy9rq/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-mmcss-canonical-nested.k1vvy9rq/hyprland.lua'])
