import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.nyy31ud4/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.nyy31ud4/hyprland.lua'])
