from pathlib import Path
import json,gzip,shutil,hashlib
out=Path('docs/evidence/performance-20260908/capture-readiness');out.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');data=json.loads(Path('/tmp/viewflow-capture-ready-comparison.json').read_text())
def save(src,name):
 src=Path(src);dst=out/name;dst.parent.mkdir(parents=True,exist_ok=True)
 if '.log' in src.name:dst.with_name(dst.name+'.gz').write_bytes(gzip.compress(src.read_bytes(),mtime=0))
 else:shutil.copyfile(src,dst)
for r in data:
 label=r['label'];d=out/label;d.mkdir(exist_ok=True)
 for n in ['source','receiver','desktop','runner','cleanup']:save(raw/f'{n}-{label}.log',Path(label)/(n+'.log'))
 save(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log'),Path(label)/'producer.log');save(raw/f'fixture-{label}.json',Path(label)/'fixture.json');save('/tmp/'+label+'.log',Path(label)/'driver.log')
 for key in ['identity_pairs']:(d/(key.replace('_','-')+'.json.gz')).write_bytes(gzip.compress(json.dumps(r[key]).encode(),mtime=0))
 (d/'summary.json').write_text(json.dumps({k:v for k,v in r.items() if k not in ['identity_pairs']},indent=2)+'\n')
(out/'comparison.json').write_text(json.dumps([{k:v for k,v in r.items() if k not in ['identity_pairs']} for r in data],indent=2)+'\n')
for pattern in ['capture-ready-*','owned-output-capture-ready*','restore-capture-ready*','summarize-capture-ready.py','save-capture-ready-*','start-integrated-receiver.py','observe-frames.py','full-resolution-trial.py','integrated-all-trial.py']:
 for p in Path('/tmp').glob('viewflow-'+pattern):
  if p.is_file() and 'vf-media-peer' not in p.name:save(p,Path('method')/p.name.removeprefix('viewflow-'))
for p in Path('/tmp').glob('viewflow-before-capture-ready-*'):
 if p.is_file() and 'vf-media-peer' not in p.name:save(p,Path('source-before')/p.name.removeprefix('viewflow-before-capture-ready-'))
for n in ['crates/viewflowd/Cargo.toml','crates/viewflowd/src/atlas_source.rs','crates/viewflowd/src/gpu_atlas_capture.rs','crates/viewflowd/src/gpu_atlas_device.rs','crates/viewflowd/src/gpu_atlas_session.rs','crates/viewflowd/src/hyprcapture_gpu_socket.rs']:
 save(n,Path('source')/n)
 save('/tmp/viewflow-capture-ready-tested-'+Path(n).name,Path('source-tested')/n)
for n in ['tools/profile_atlas_timeline.py','tools/summarize_desktop_markers.py']:save(n,Path('source')/n)
s=json.loads(Path('/tmp/viewflow-capture-ready-state.json').read_text());assert s['configs_restored'] and s['restore_task_removed'] and s['restored']['priority']==s['initial']['priority'] and all(t['priority']=='TimeCritical' for t in s['restored']['threads']);assert len(s['phases'])==4 and all(p['exit']==0 and all(p[k]['priority']=='Normal' and p[k]['other_critical']==0 and all(t['priority']=='Normal' for t in p[k]['threads']) for k in ['before','after']) for p in s['phases'])
s=json.loads(Path('/tmp/viewflow-owned-output-capture-ready-state.json').read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
for n,h in json.loads(Path('/tmp/viewflow-capture-ready-trial-source-sha256.json').read_text()).items():
 candidate=Path('/tmp/viewflow-capture-ready-tested-'+Path(n).name) if n.startswith('crates/viewflowd/') else Path('/tmp/viewflow-capture-ready-vf-media-peer') if n=='target/release/vf-media-peer' else Path(n)
 assert hashlib.sha256(candidate.read_bytes()).hexdigest()==h
print('all four controls and restoration verified; evidence saved')
