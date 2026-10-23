"""Pin only the nonactivating performance fixture; never focus or move workspaces."""
import importlib.util,subprocess,os
from pathlib import Path
root=Path(__file__).resolve().parent;repo=root.parents[2]
s=importlib.util.spec_from_file_location('fusion',repo/'tools/windows-fusion.py');f=importlib.util.module_from_spec(s);s.loader.exec_module(f);env=f.hyprland_env()
def ctl(*a):return subprocess.check_output(['hyprctl',*a],env=env,text=True)
if ctl('repl','return type(_viewflow_perf_rule)').strip()!='nil':raise RuntimeError('temporary rule already exists')
original_errors=ctl('configerrors')
try:
 result=ctl('eval','_viewflow_perf_rule=hl.window_rule({name="viewflow-performance-fixture-temporary",match={class="^ViewflowReverse-WindowsNative-.*$",title="^Viewflow 6K performance fixture$"},float=true,pin=true,no_focus=true,no_anim=true,monitor="DP-4"})')
 if result.strip()!='ok' or ctl('configerrors')!=original_errors:raise RuntimeError('temporary rule validation failed')
 subprocess.run(['python3',str(root/'run-copy-dynamic-pinned.py')],check=True)
finally:
 ctl('eval','if _viewflow_perf_rule then _viewflow_perf_rule:set_enabled(false); _viewflow_perf_rule=nil end')
 (root/'copy-dynamic-pinned1-rule-cleanup.txt').write_text(ctl('repl','return type(_viewflow_perf_rule)')+ctl('configerrors'))
