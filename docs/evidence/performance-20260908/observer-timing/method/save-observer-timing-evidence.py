from pathlib import Path
import json,gzip,shutil,hashlib
out=Path('docs/evidence/performance-20260908/observer-timing');out.mkdir(exist_ok=True)
raw=Path('/tmp/viewflow-integrated-pair')
def save(src,dst):
 src=Path(src);dst=out/dst;dst.parent.mkdir(parents=True,exist_ok=True)
 if '.log' in src.name:
  dst=dst.with_name(dst.name+'.gz');dst.write_bytes(gzip.compress(src.read_bytes(),mtime=0))
 else:shutil.copy(src,dst)
window=json.loads(Path('/tmp/viewflow-window-observer-analysis.json').read_text());desktop=json.loads(Path('/tmp/viewflow-observer-timer-comparison.json').read_text())
for result in window+desktop:
 label=result['label'];kind='window' if result in window else 'desktop';p=out/label;p.mkdir(exist_ok=True)
 for n in ['source','receiver','runner','cleanup',kind]+(['desktop'] if label=='4k-dual-observer-a' else []):save(raw/f'{n}-{label}.log',Path(label)/(n+'.log'))
 save(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log'),Path(label)/'producer.log')
 save(raw/f'fixture-{label}.json',Path(label)/'fixture.json')
 pairkey='pairs' if kind=='window' else 'identity_pairs'
 (p/'identity-pairs.json.gz').write_bytes(gzip.compress(json.dumps(result[pairkey]).encode(),mtime=0))
 (p/'summary.json').write_text(json.dumps({k:v for k,v in result.items() if k!=pairkey},indent=2)+'\n')
 if kind=='window':assert result['summary']['abandoned']==0 and result['negative_capture_to_render_upper']==0 and result['negative_commit_to_render']==0
 else:assert result['readback']['abandoned']==0 and all(x['present_source_upper_ns']<=x['source_clock_mapping_valid_until_ns'] for x in result[pairkey])
for name,data,key in [('window-comparison.json',window,'pairs'),('desktop-comparison.json',desktop,'identity_pairs')]:
 (out/name).write_text(json.dumps([{k:v for k,v in r.items() if k!=key} for r in data],indent=2)+'\n')
dual=json.loads(Path('/tmp/viewflow-dual-observer-comparison.json').read_text());(out/'dual-pairs.json.gz').write_bytes(gzip.compress(json.dumps(dual.pop('pairs')).encode(),mtime=0));(out/'dual-comparison.json').write_text(json.dumps(dual,indent=2)+'\n')
methods=['analyze-window-observer.py','analyze-dual-observer.py','summarize-observer-timers.py','save-observer-timing-evidence.py','observe-frames.py','observe-both.py','integrated-all-trial.py','full-resolution-trial.py','start-integrated-receiver.py','build-window-observer.py','build-window-observer.log','build-window-observer-final.log','build-observer-timers.py','build-observer-timers.log','window-observer-smoke-source.cpp','before-observer-timer-windows_frame_observer.cpp','before-observer-timer-windows_window_frame_observer.cpp','restore-window-observer-control.ps1','restore-observer-timers.ps1','restore-window-timers.ps1','observer-final-state.json','owned-output-window-observer.py']
for group,suffix in [('window-observer','.smoke'),('window-observer','.dual'),('observer-timer',''),('window-timer','')]:
 for name in [f'{group}-trials.py',f'{group}-state.json',f'{group}-trial-source-sha256.json',f'owned-output-{group}-state.json',f'owned-output-{group}.log']:methods.append(name+suffix)
 if not suffix:methods.append(f'owned-output-{group}.py')
 state=json.loads(Path('/tmp/viewflow-'+group+'-state.json'+suffix).read_text());assert state['restore_task_removed'] and state['restored']['priority']==state['initial']['priority'] and all(t['priority']=='TimeCritical' for t in state['restored']['threads'])
 assert all(p['exit']==0 and all(p[k]['priority']=='Normal' and p[k]['other_critical']==0 and all(t['priority']=='Normal' for t in p[k]['threads']) for k in ['before','after']) for p in state['phases'])
 own=json.loads(Path('/tmp/viewflow-owned-output-'+group+'-state.json'+suffix).read_text());assert own['before_monitors']==own['after_monitors'] and not own['remaining_owned_output_clients'];assert all(own[k].get('address')==own['before_focus'].get('address') for k in ['after_create_focus','after_focus'])
for n in methods:save('/tmp/viewflow-'+n,Path('method')/n)
for n in ['tools/windows_frame_observer.cpp','tools/windows_window_frame_observer.cpp','tools/windows_observer_timer.h','tools/profile_atlas_timeline.py','platform/windows-composition-preview/CMakeLists.txt','platform/windows-composition-preview/timer_resolution_guard.h']:save(n,Path('source')/n)
ledger=json.loads(Path('/tmp/viewflow-window-timer-trial-source-sha256.json').read_text());assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in ledger.items())
f=json.loads(Path('/tmp/viewflow-observer-final-state.json').read_text());assert f['owned_tasks']==0 and f['owned_processes']==0 and f['priority']=='High' and all(t['PriorityLevel']==15 for t in f['threads'])
print('archived',len(window)+len(desktop),'trials;',len(list(out.rglob('*'))),'entries; all restoration and source checks passed')
