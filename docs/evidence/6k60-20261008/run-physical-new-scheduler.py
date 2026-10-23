import subprocess,importlib.util,json,os
from pathlib import Path
root=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('fusion',root.parents[2]/'tools/windows-fusion.py');fusion=importlib.util.module_from_spec(spec);spec.loader.exec_module(fusion)
env=fusion.hyprland_env()
def option():return json.loads(subprocess.check_output(['hyprctl','-j','getoption','render:new_render_scheduling'],env=env))
def set_scheduler(value):
 out=subprocess.check_output(['hyprctl','eval','hl.config({render={new_render_scheduling='+('true' if value else 'false')+'}})'],env=env).decode()
 if 'ok' not in out.lower():raise RuntimeError(out)
 if bool(option()['bool'])!=value:raise RuntimeError('Scheduler read-back mismatch')
original=option();(root/'physical-new-scheduler-before.json').write_text(json.dumps(original,indent=2))
try:
 set_scheduler(True)
 subprocess.run(['python',str(root/'run-physical-motion.py')],env=os.environ|{'MOTION_TAG':'physical-new-scheduler'},check=True)
finally:
 set_scheduler(bool(original['bool']))
 (root/'physical-new-scheduler-after.json').write_text(json.dumps(option(),indent=2))
