from pathlib import Path
import json,gzip,shutil,hashlib
out=Path('docs/evidence/performance-20260908/inplace-surface-rejected');out.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');data=json.loads(Path('/tmp/viewflow-inplace-comparison.json').read_text())
def save(src,name):
 src=Path(src);dst=out/name;dst.parent.mkdir(parents=True,exist_ok=True)
 if '.log' in src.name:dst.with_name(dst.name+'.gz').write_bytes(gzip.compress(src.read_bytes(),mtime=0))
 else:shutil.copy(src,dst)
for r in data:
 label=r['label'];d=out/label;d.mkdir(exist_ok=True)
 for n in ['source','receiver','desktop','runner','cleanup']:save(raw/f'{n}-{label}.log',Path(label)/(n+'.log'))
 save(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log'),Path(label)/'producer.log');save(raw/f'fixture-{label}.json',Path(label)/'fixture.json')
 (d/'identity-pairs.json.gz').write_bytes(gzip.compress(json.dumps(r['identity_pairs']).encode(),mtime=0));(d/'summary.json').write_text(json.dumps({k:v for k,v in r.items() if k!='identity_pairs'},indent=2)+'\n')
 assert all(x['present_source_upper_ns']<=x['source_clock_mapping_valid_until_ns'] for x in r['identity_pairs'])
(out/'comparison.json').write_text(json.dumps([{k:v for k,v in r.items() if k!='identity_pairs'} for r in data],indent=2)+'\n')
for n in ['inplace-trials.py','inplace-state.json','inplace-trial-source-sha256.json','restore-inplaces.ps1','owned-output-inplace.py','owned-output-inplace-state.json','owned-output-inplace.log','summarize-inplace.py','inplace-comparison.log','save-inplace-evidence.py','backup-before-inplace.py','before-inplace-binaries.json','build-inplace.py','build-inplace.log','build-inplace-pixels.py','build-inplace-pixels.log','inplace-pixels.log','inplace-pixel-test.cpp','stable-surface-layout-test.cpp','build-inplace-runners.py','inplace-runners-build.cmd','inplace-runners-build.log','inplace-0-runner.cpp','inplace-1-runner.cpp','inplace-experiment-binaries.json','restore-inplace-source.py','inplace-restored-binaries.json','inplace-final-state.py','inplace-final-state.json','start-integrated-receiver.py','observe-frames.py','full-resolution-trial.py','integrated-all-trial.py']:
 save('/tmp/viewflow-'+n,Path('method')/n)
for src,name in [('/tmp/viewflow-inplace-main-experiment.cpp','main.cpp.experiment'),('/tmp/viewflow-before-inplace-main.cpp','main.cpp.restored'),('/tmp/viewflow-inplace-stable_surface_layout.h','stable_surface_layout.h.experiment'),('/tmp/viewflow-before-inplace-pixel-test.cpp','sparse_coalesce_capture_test.cpp.restored')]:save(src,Path('source')/name)
for n in ['tools/profile_atlas_timeline.py','tools/summarize_desktop_markers.py','platform/windows-composition-preview/atlas_frame_bindings.h','platform/windows-composition-preview/atlas_record.h','platform/windows-composition-preview/sparse_shared_visuals.h','platform/windows-composition-preview/sparse_visual_reference.h']:save(n,Path('source')/n)
s=json.loads(Path('/tmp/viewflow-inplace-state.json').read_text());assert s['restore_task_removed'] and s['restored']['priority']==s['initial']['priority'] and all(t['priority']=='TimeCritical' for t in s['restored']['threads']);assert len(s['phases'])==4 and all(p['exit']==0 and all(p[k]['priority']=='Normal' and p[k]['other_critical']==0 and all(t['priority']=='Normal' for t in p[k]['threads']) for k in ['before','after']) for p in s['phases'])
s=json.loads(Path('/tmp/viewflow-owned-output-inplace-state.json').read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
ledger=json.loads(Path('/tmp/viewflow-inplace-trial-source-sha256.json').read_text())
for n,h in ledger.items():
 p=Path('/tmp/viewflow-inplace-main-experiment.cpp') if n.endswith('/main.cpp') else Path('/tmp/viewflow-inplace-stable_surface_layout.h') if n.endswith('/stable_surface_layout.h') else Path(n)
 assert hashlib.sha256(p.read_bytes()).hexdigest()==h
assert Path('platform/windows-composition-preview/main.cpp').read_bytes()==Path('/tmp/viewflow-before-inplace-main.cpp').read_bytes();assert Path('platform/windows-composition-preview/sparse_coalesce_capture_test.cpp').read_bytes()==Path('/tmp/viewflow-before-inplace-pixel-test.cpp').read_bytes()
print('all 4 controls and restoration checks passed; evidence saved')
