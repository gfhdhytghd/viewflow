import subprocess,importlib.util,json,os
from pathlib import Path
root=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('fusion',root.parents[2]/'tools/windows-fusion.py');fusion=importlib.util.module_from_spec(spec);spec.loader.exec_module(fusion)
env=fusion.hyprland_env()
def option():return json.loads(subprocess.check_output(['hyprctl','-j','getoption','debug:vfr'],env=env))
def set_vfr(value):
 out=subprocess.check_output(['hyprctl','eval','hl.config({debug={vfr='+('true' if value else 'false')+'}})'],env=env).decode()
 if 'ok' not in out.lower():raise RuntimeError(out)
 if bool(option()['bool'])!=value:raise RuntimeError('VFR read-back mismatch')
original=option();(root/'physical-vfr-before.json').write_text(json.dumps(original,indent=2))
try:
 set_vfr(True)
 subprocess.run(['python',str(root/'run-physical-motion.py')],env=os.environ|{'MOTION_TAG':'physical-vfr'},check=True)
finally:
 set_vfr(bool(original['bool']))
 (root/'physical-vfr-after.json').write_text(json.dumps(option(),indent=2))
