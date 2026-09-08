from pathlib import Path
import json,gzip,shutil,hashlib,subprocess
# Refuse to overwrite the tested snapshot after source restoration.
for n,h in json.loads(Path('/tmp/viewflow-commit-cadence-trial-source-sha256.json').read_text()).items():
 assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h,n
out=Path('docs/evidence/performance-20260908/capture-commit-cadence');out.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');data=json.loads(Path('/tmp/viewflow-commit-cadence-comparison.json').read_text())
def save(src,name,compress=False):
 src=Path(src);dst=out/name;dst.parent.mkdir(parents=True,exist_ok=True)
 if '.log' in src.name or compress:dst.with_name(dst.name+'.gz').write_bytes(gzip.compress(src.read_bytes(),mtime=0))
 else:shutil.copyfile(src,dst)
assert len(data)==4
for r in data:
 label=r['label'];d=out/label;d.mkdir(exist_ok=True)
 for n in ['source','receiver','desktop','runner','cleanup']:save(raw/f'{n}-{label}.log',Path(label)/(n+'.log'))
 save(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log'),Path(label)/'producer.log');save(raw/f'fixture-{label}.json',Path(label)/'fixture.json');save('/tmp/'+label+'.log',Path(label)/'driver.log')
 (d/'identity-pairs.json.gz').write_bytes(gzip.compress(json.dumps(r['identity_pairs']).encode(),mtime=0))
 (d/'summary.json').write_text(json.dumps({k:v for k,v in r.items() if k!='identity_pairs'},indent=2)+'\n')
 assert not r['clock_and_stages']['invalid_exchanges']
 assert not r['missing_capture_marker'] and not r['bounds']['expired_clock_mapping'] and not r['bounds']['negative_upper_bound']
 assert r['readback']['abandoned']==0 and r['readback']['pending_peak']==2
 assert not r['malformed_encoder_rows'] and not r['malformed_wire_rows']
 assert (raw/f'runner-{label}.log').read_text().find('receiver_exit=1 watchdog=0')>=0
 assert 'source_exit 124' in Path('/tmp/'+label+'.log').read_text()
(out/'comparison.json').write_text(json.dumps([{k:v for k,v in r.items() if k!='identity_pairs'} for r in data],indent=2)+'\n')
for name in ['commit-cadence-configure.log','commit-cadence-build.log','commit-cadence-tests.log','commit-cadence-build-final.log','commit-cadence-tests-final.log','commit-cadence-trials.py','commit-cadence-state.json','restore-commit-cadence.ps1','commit-cadence-trial-source-sha256.json','commit-cadence-final-state.py','commit-cadence-final-state.json','commit-cadence-analysis.log','commit-nested-driver.py','commit-nested-driver-headless-failed.py','commit-nested-ab.py','commit-cohort-smoke.py','commit-full-resolution-trial.py','prepare-commit-ab.py','prepare-commit-final-state.py','summarize-commit-cadence.py','capture-phase-baseline.json','start-integrated-receiver.py','observe-frames.py','integrated-all-trial.py','save-commit-cadence-evidence.py']:
 save('/tmp/viewflow-'+name,Path('method')/name)
save('/tmp/viewflow-commit-hyprctl-shim/hyprctl',Path('method/hyprctl-shim.py'))
for p in Path('/tmp').glob('viewflow-before-commit-cadence-*'):
 if p.is_file():save(p,Path('source-before')/p.name.removeprefix('viewflow-before-commit-cadence-'))
for p in Path('platform/viewflow-capture').rglob('*'):
 if p.is_file() and not any(x in p.parts for x in ['build','.git']):save(p,Path('source-prototype')/p)
for n in ['tools/profile_atlas_timeline.py','tools/summarize_desktop_markers.py','platform/linux-frame-fixture/main.cpp','platform/linux-frame-fixture/CMakeLists.txt']:
 save(n,Path('source-prototype')/n)
for p in sorted(Path('/tmp').glob('viewflow-commit-nested.*/state.json')):
 s=json.loads(p.read_text());d=Path('nested')/p.parent.name.removeprefix('viewflow-commit-nested.')
 assert s.get('nested_stopped') and s['before_monitors']==s['after_monitors'] and s['before_focus']==s['after_focus'] and s['before_plugins']==s['after_plugins'] and not s['remaining_clients']
 for f in p.parent.iterdir():
  if f.is_file() and f.name not in ['first-frame.ppm'] and not f.name.startswith('rpc-'):save(f,d/f.name)
 if (p.parent/'first-frame.ppm').exists():save(p.parent/'first-frame.ppm',d/'first-frame.ppm',compress=True)
 sig=s.get('signature')
 if sig:
  log=Path(s['runtime'])/'hypr'/sig/'hyprland.log'
  if log.exists():save(log,d/'hyprland.log')
 # Earlier startup failure registered no instance in state; still retain its complete log.
 else:
  for log in (Path(s['runtime'])/'hypr').glob('*/hyprland.log'):save(log,d/'hyprland.log')
s=json.loads(Path('/tmp/viewflow-commit-cadence-state.json').read_text());assert s['configs_restored'] and s['restore_task_removed'] and s['restored']['priority']==s['initial']['priority'] and all(t['priority']=='TimeCritical' for t in s['restored']['threads'])
assert len(s['phases'])==4 and all(p['exit']==0 and all(p[k]['priority']=='Normal' and p[k]['other_critical']==0 and all(t['priority']=='Normal' for t in p[k]['threads']) for k in ['before','after']) for p in s['phases'])
for n,h in json.loads(Path('/tmp/viewflow-commit-cadence-trial-source-sha256.json').read_text()).items():assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h,n
# Snapshot the actual complete tested plugin input and diagnostics before restoring production source.
print('four AB controls, nested cleanup and tested source verified; prototype evidence saved',out)
