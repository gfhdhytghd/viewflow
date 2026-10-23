"""Power DP-4 for measurement; restore its power state without input/focus."""
import subprocess,importlib.util,json,time,os
from pathlib import Path
root=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('fusion',root.parents[2]/'tools/windows-fusion.py');fusion=importlib.util.module_from_spec(spec);spec.loader.exec_module(fusion)
env=fusion.hyprland_env()
def monitors():return json.loads(subprocess.check_output(['hyprctl','-j','monitors','all'],env=env))
def target():return next((m for m in monitors() if m['name']=='DP-4'),None)
def power(state):
 # DPMS can trigger a brief connector reprobe. Await authoritative read-back;
 # do not interpret a temporarily absent output as successful restoration.
 for attempt in range(2):
  out=subprocess.check_output(['hyprctl','dispatch','hl.dsp.dpms({action="'+('on' if state else 'off')+'",monitor="DP-4"})'],env=env).decode()
  if 'ok' not in out.lower():raise RuntimeError(out)
  stable=0
  for _ in range(15):
   time.sleep(.2);current=target()
   stable=stable+1 if current and current['dpmsStatus']==state else 0
   if stable>=5:return
 raise RuntimeError('DP-4 power read-back mismatch after connector settling')
if target() is None:raise RuntimeError('DP-4 is not connected')
original=target()['dpmsStatus'];tag=os.environ.get('MOTION_TAG','physical-overlap')
(root/f'{tag}-power-before.json').write_text(json.dumps(monitors(),indent=2))
try:
 if not original:power(True)
 subprocess.run(['python',str(root/'run-motion.py')],env=os.environ|{'MOTION_TAG':tag},check=True)
finally:
 try:
  if not original:power(False)
 finally:
  (root/f'{tag}-power-after.json').write_text(json.dumps(monitors(),indent=2))
