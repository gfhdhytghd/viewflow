"""Temporary standalone scheduler experiment; no input/focus operations."""
import os,sys,json,subprocess,importlib.util
from pathlib import Path
root=Path(__file__).resolve().parent;repo=root.parents[2]
spec=importlib.util.spec_from_file_location('fusion',repo/'tools/windows-fusion.py');fusion=importlib.util.module_from_spec(spec);spec.loader.exec_module(fusion)
env=fusion.hyprland_env()
enabled=len(sys.argv)>1 and sys.argv[1]=='enabled'
lead=float(sys.argv[2]) if len(sys.argv)>2 else 3.
if not 0<lead<16:raise ValueError('experiment lead must be under one refresh period')
tag='physical-deadline-'+(str(lead).replace('.','p') if enabled else 'baseline')
suffix=os.environ.get('DEADLINE_RUN_SUFFIX','')
if suffix:
 if not all(c.isalnum() or c=='-' for c in suffix):raise ValueError('invalid run suffix')
 tag+='-'+suffix
plugin=str(repo/'build/hyprland-deadline-experiment/viewflow-deadline-experiment.so')
def ctl(*args):return subprocess.check_output(['hyprctl',*args],env=env,text=True,timeout=10)
(root/f'{tag}-plugins-before.txt').write_text(ctl('plugin','list'))
if 'viewflow-deadline-experiment' in (root/f'{tag}-plugins-before.txt').read_text():raise RuntimeError('experiment already loaded; inspect before changing')
loaded=False
try:
 out=ctl('plugin','load',plugin)
 if out.strip()!='ok':raise RuntimeError(out)
 loaded=True
 (root/f'{tag}-plugin-before.json').write_text(ctl('repl','return hl.plugin.viewflow_deadline.status()'))
 out=ctl('eval','hl.plugin.viewflow_deadline.set("DP-4",'+('true' if enabled else 'false')+','+str(lead)+')')
 if out.strip()!='ok':raise RuntimeError(out)
 subprocess.run(['python3',str(root/'run-pixel-host-bands-deferred.py')],check=True)
 (root/f'{tag}-plugin-after.json').write_text(ctl('repl','return hl.plugin.viewflow_deadline.status()'))
finally:
 if loaded:
  try:ctl('eval','hl.plugin.viewflow_deadline.set("DP-4",false,3)')
  finally:(root/f'{tag}-unload.txt').write_text(ctl('plugin','unload',plugin))
 (root/f'{tag}-plugins-after.txt').write_text(ctl('plugin','list'))
