import os,pathlib
pathlib.Path('/tmp/viewflow-import-hv-ddc-nested.jgfh9cb2/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-import-hv-ddc-nested.jgfh9cb2/hyprland.lua'])
