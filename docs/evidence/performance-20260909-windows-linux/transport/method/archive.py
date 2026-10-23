from pathlib import Path
import json,hashlib,subprocess,shutil,base64,re
b=Path(__file__).resolve().parent.parent;parent=b.parent
labels=['baseline','dd-a1','waitable-50-a1','waitable-0-b1','waitable-0-b2','waitable-50-a2']
if (b/'runs/stats-0-a1/status.log').exists():labels+=['stats-0-a1']
for label in ['direct-off-a1','direct-on-b1','direct-on-b2','direct-off-a2','alpha-off-a1','alpha-on-b1','alpha-on-b2','alpha-off-a2','mmcss-off-a1','mmcss-on-b1','mmcss-on-b2','mmcss-off-a2','alpha-render-off-a1','alpha-render-on-b1','alpha-render-on-b2','alpha-render-off-a2','alpha-direct-off-a1','alpha-direct-on-b1','alpha-direct-on-b2','alpha-direct-off-a2','integrated-off-a1','integrated-on-b1','integrated-on-b2','integrated-off-a2','queue-1-b1','queue-4-a1r','queue-4-a2','queue-1-b2','priority-off-a1','priority-on-b1','priority-on-b2','priority-off-a2','root-frame-a1','root-latency-b1','root-latency-b2','root-frame-a2']:
 if (b/'runs'/label/'status.log').exists():labels.append(label)
comparisons={}
for label in labels:
 subprocess.run(['python',str(b/'method/analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 p=b/'runs'/label;s=json.loads((p/'state.json').read_text());nested=Path(s['nested_state']['root']);dest=b/'nested'/label;dest.mkdir(parents=True,exist_ok=True)
 for name in ['state.json','hyprland.lua','compositor.log']:
  shutil.copy2(nested/name,dest/name)
 n=json.loads((dest/'state.json').read_text());assert n['nested_stopped'] and n['transport_trial']=='passed'
 fields=['name','width','height','x','y','scale','transform','disabled']
 geom=lambda rows:sorted([tuple(row[k] for k in fields) for row in rows])
 assert geom(n['before_monitors'])==geom(n['after_monitors'])
 assert n['before_plugins']==n['after_plugins']
 assert n['after_focus'].get('pid')!=n['pid']
 assert s['before']['installed']==s['after']['installed'] and s['before']['main']==s['after']['main']
 assert not s['after']['processes'] and not s['after']['port'] and not s['remaining_proxies']
 assert s['observer_exit']==s['client_exit']==s['task']['result']==0
 status=(p/'status.log').read_text();assert 'watchdog=1' not in status
 if 'native_hash_before' in s:assert s['native_hash_before']==s['native_hash_after']
 lines=(p/'source.log').read_text(errors='replace').splitlines()
 if 'direct_single_surface' in s:
  route=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in lines if line.startswith('profile_direct ')]
  assert route and all(x['used']==s['direct_single_surface'] and x['tiles']==1 for x in route)
 if 'alpha_summary' in s:
  route=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in lines if line.startswith('profile_alpha_summary ')]
  assert route and all(x['opaque']==s['alpha_summary'] for x in route)
  if s['alpha_summary']:assert any(line.startswith('reverse_alpha_summary enabled=1 ') for line in lines) and all(x['bytes']==0 for x in route)
 if 'capture_changes' in s:
  changed=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in lines if line.startswith('profile_capture_changes ')]
  assert changed and all(x['enabled']==s['capture_changes'] for x in changed)
  if not s['capture_changes']:assert all(x['unchanged_skips']==0 for x in changed)
 if 'mmcss' in s:
  sched=s['scheduling'];assert sched['process_priority']=='BelowNormal' and sched['task_priority']==7
  assert sched['base_priority']==(19 if s['mmcss'] else 6)
  assert f"requested={s['mmcss']} registered={s['mmcss']} priority_set={s['mmcss']}" in sched['registration'] and 'error=0' in sched['registration']
 if 'max_pending' in s:
  prefix='reverse_performance ' if 'performance_mode' in s else 'reverse_max_pending '
  events=[{k:v for k,v in re.findall(r'(\w+)=([^ ]+)',line)} for line in lines if line.startswith(prefix)]
  assert len(events)==1 and int(events[0]['max_pending' if 'performance_mode' in s else 'value'])==s['max_pending']
  if 'performance_mode' in s:
   assert events[0]['mode']==s['performance_mode'] and s['mode_selected']['mode']==s['performance_mode']
   assert s['mode_restored']['mode']==s['mode_before']['mode']
  submissions=[int(re.search(r'pending=(\d+)',line).group(1)) for line in lines if line.startswith('profile_submit ')]
  assert submissions and max(submissions)<s['max_pending']
  from collections import Counter
  (p/'pipeline-occupancy.json').write_text(json.dumps({'before_submit':dict(sorted(Counter(submissions).items())),'configured_max':s['max_pending']},indent=2)+'\n')
 if 'normal_priority' in s:
  sched=s['native_scheduling'];enabled=s['normal_priority'];assert sched['task_priority']==7 and sched['base_priority']==(8 if enabled else 6) and sched['process_class']==('Normal' if enabled else 'BelowNormal')
  events=[line for line in lines if line.startswith('reverse_process_priority ')];assert len(events)==1
  assert f'requested={enabled} applied=1 before=16384 after={32 if enabled else 16384} thread=0 error=0' in events[0]
 comparisons[label]=json.loads((p/'summary.json').read_text())
(b/'comparison.json').write_text(json.dumps(comparisons,indent=2)+'\n')
# The earlier source runs hashed these native executables before all transport
# trials. Check the same files again; label this a bracketing audit, not an
# executable-memory hash or a fabricated per-run sample.
expected={}
for name in ['mft-inspection','mft-speed0']:
 s=json.loads((parent/name/'method/run-state.json').read_text())
 for row in s['binaries']:
  if row['path'].endswith('viewflow_windows_reverse.exe'):expected[row['path']]=row['hash']
script="$ErrorActionPreference='Stop';@("+','.join("'"+k+"'" for k in expected)+")|ForEach-Object{[pscustomobject]@{path=$_;hash=(Get-FileHash $_).Hash}}|ConvertTo-Json"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,check=True,timeout=30)
actual={x['path']:x['hash'] for x in json.loads(r.stdout)};assert actual==expected
(b/'method/native-bracketing-audit.json').write_text(json.dumps({'scope':'source-run pre-transport hashes compared with current post-trial files; no native rebuild between trials','expected_before':expected,'actual_after':actual},indent=2)+'\n')
for source,target in [('/tmp/viewflow-reverse-quality-configure.log','quality/method/configure.log'),('/tmp/viewflow-reverse-quality-build.log','quality/method/build.log'),('/tmp/viewflow-reverse-quality-rebuild.log','quality/method/rebuild.log'),('/tmp/viewflow-reverse-observer-configure.log','transport/method/observer-configure.log'),('/tmp/viewflow-reverse-observer-build.log','transport/method/observer-build.log'),('/tmp/viewflow-reverse-perf-peer-linux-build.log','transport/method/linux-perf-build.log')]:
 p=Path(source)
 if p.exists():shutil.copy2(p,parent/target)
assert (b/'source/vf-window-perf-peer.rs').read_bytes()==Path('crates/viewflowd/src/bin/vf-window-perf-peer.rs').read_bytes()
for name in ['mft-inspection','mft-speed0']:
 p=parent/name
 manifest=json.loads((p/'method/source-sha256.json').read_text());assert manifest==json.loads((p/'method/remote-source-sha256.json').read_text())
 assert all(hashlib.sha256((p/'source'/rel).read_bytes()).hexdigest()==h for rel,h in manifest.items())
 s=json.loads((p/'summary.json').read_text());assert s['marker_validation']['decoded']==s['source_frames'] and s['marker_validation']['regressions']==0 and s['run_qualified']
for name in ['mft-inspection','mft-speed0','quality','transport']:
 p=parent/name
 files=sorted(f for f in p.rglob('*') if f.is_file() and '__pycache__' not in f.parts and f!=p/'sha256.json')
 manifest={str(f.relative_to(p)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}
 (p/'sha256.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print(name,len(manifest))
print('archive and source/topology/cleanup verification passed')
