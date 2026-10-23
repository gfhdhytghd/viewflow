import os,pathlib
pathlib.Path('/tmp/viewflow-reverse-transport-nested.vqq_qh82/pid').write_text(str(os.getpid()))
os.execv("/usr/bin/Hyprland",["Hyprland","--config",'/tmp/viewflow-reverse-transport-nested.vqq_qh82/hyprland.lua'])
