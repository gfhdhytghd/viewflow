from pathlib import Path
import json,gzip,shutil,hashlib
out=Path('docs/evidence/performance-20260908/av1-window-codec');out.mkdir(exist_ok=True);raw=Path('/tmp/viewflow-integrated-pair');data=json.loads(Path('/tmp/viewflow-codec-split-comparison.json').read_text())
def save(src,name):
 src=Path(src);dst=out/name;dst.parent.mkdir(parents=True,exist_ok=True)
 if '.log' in src.name or src.suffix in ['.vfc','.obu','.csv']:dst.with_name(dst.name+'.gz').write_bytes(gzip.compress(src.read_bytes(),mtime=0))
 else:shutil.copyfile(src,dst)
for r in data:
 label=r['label'];d=out/label;d.mkdir(exist_ok=True)
 for n in ['source','receiver','desktop','runner','cleanup']:save(raw/f'{n}-{label}.log',Path(label)/(n+'.log'))
 save(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log'),Path(label)/'producer.log');save(raw/f'fixture-{label}.json',Path(label)/'fixture.json');save('/tmp/'+label+'.log',Path(label)/'driver.log')
 (d/'identity-pairs.json.gz').write_bytes(gzip.compress(json.dumps(r['identity_pairs']).encode(),mtime=0));(d/'summary.json').write_text(json.dumps({k:v for k,v in r.items() if k!='identity_pairs'},indent=2)+'\n')
(out/'comparison.json').write_text(json.dumps([{k:v for k,v in r.items() if k!='identity_pairs'} for r in data],indent=2)+'\n')
patterns=['summarize-codec-split.py','codec-split*','owned-output-codec-split*','restore-codec-split*','nvenc-split*','owned-output-nvenc-split*','restore-nvenc-split*','av1-window*','build-av1-window-receiver.py','validate-av1-window.py','av1-presenter*','build-av1-presenter.py','test-av1-presenter.py','start-integrated-receiver.py','observe-frames.py','full-resolution-trial.py','integrated-all-trial.py','save-codec-split-evidence.py','codec-final-state*']
for pattern in patterns:
 for p in Path('/tmp').glob('viewflow-'+pattern):
  if p.is_file() and p.suffix not in ['.tar','.gz']:save(p,Path('method')/p.name.removeprefix('viewflow-'))
for p in Path('/tmp/viewflow-nvenc-split-probe').iterdir():
 if p.is_file() and p.name not in ['encode','quality']:save(p,Path('nvenc-microbench')/p.name)
for mode in ['auto','four']:
 for p in Path('/tmp/viewflow-nvenc-split-av1-'+mode).iterdir():save(p,Path('sparse-fixtures')/mode/p.name)
for label in ['4k-nvenc-split-auto-a1','4k-codec-h264-a1','4k-codec-av1-auto-b1']:
 for p in raw.glob('*-'+label+'.*'):save(p,Path('excluded-runs')/label/p.name)
 for p in [Path('/tmp')/(label+'.log'),Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')]:
  if p.exists():save(p,Path('excluded-runs')/label/p.name)
for pattern in ['before-av1-window-*.rs','before-nvenc-split.cu','before-nvenc-split-sha256.json']:
 for p in Path('/tmp').glob('viewflow-'+pattern):save(p,Path('source-before')/p.name.removeprefix('viewflow-'))
for n in ['tools/profile_atlas_timeline.py','tools/summarize_desktop_markers.py','tools/windows_frame_observer.cpp','tools/windows_observer_timer.h','platform/nvenc-encoder/gpu_dmabuf_encoder.cu','platform/nvenc-encoder/gpu_sparse_encoder_test.cpp','crates/viewflowd/src/atlas_peer.rs','crates/viewflowd/src/atlas_presenter_child.rs','crates/viewflowd/src/atlas_receiver_presenter.rs','platform/windows-video-compositor/ffmpeg_decoder.cpp','platform/windows-video-compositor/ffmpeg_decoder.h','platform/windows-composition-preview/CMakeLists.txt']:
 save(n,Path('source')/n)
s=json.loads(Path('/tmp/viewflow-codec-split-state.json').read_text());assert s['configs_restored'] and s['restore_task_removed'] and s['restored']['priority']==s['initial']['priority'] and all(t['priority']=='TimeCritical' for t in s['restored']['threads']);assert len(s['phases'])==6 and all(p['exit']==0 and all(p[k]['priority']=='Normal' and p[k]['other_critical']==0 and all(t['priority']=='Normal' for t in p[k]['threads']) for k in ['before','after']) for p in s['phases'])
s=json.loads(Path('/tmp/viewflow-owned-output-codec-split-state.json').read_text());assert s['before_monitors']==s['after_monitors'] and not s['remaining_owned_output_clients'];assert all(s[k].get('address')==s['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
for n,h in json.loads(Path('/tmp/viewflow-codec-split-trial-source-sha256.json').read_text()).items():assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h
print('all six controls and restoration verified; evidence saved')

for n in ['av1-presenter-source.tar.gz','av1-window-source.tar.gz']:save('/tmp/viewflow-'+n,Path('source')/n)
