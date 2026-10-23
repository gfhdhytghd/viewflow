import os,pathlib
pathlib.Path('/tmp/viewflow-esrv-hyperv-nested.sx42kl7d/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-esrv-hyperv-nested.sx42kl7d/hyprland.lua'])
