from pathlib import Path
import re,json
b=Path(__file__).resolve().parent.parent;p=b/'runs/integrated'
def rows(name,prefix):
 result=[]
 for line in (p/name).read_text(errors='replace').splitlines():
  if line.startswith(prefix+' '):result.append(dict(re.findall(r'(\w+)=([^ ]+)',line)))
 return result
frames=rows('decode.log','lifecycle_frame');tiles=rows('decode.log','lifecycle_tile');decoded=rows('decode.log','lifecycle_decoded');phases=rows('fixture.log','lifecycle_phase');windows=rows('fixture.log','lifecycle_window');sources=rows('source.log','profile_capture_changes');routes=rows('source.log','profile_direct')
by_pts={f['pts']:f for f in frames};assert len(by_pts)==len(frames)==len(decoded)
for f in frames:f['tile_list']=[t for t in tiles if t['pts']==f['pts']];assert len(f['tile_list'])==int(f['tiles'])
def matches(f,phase):
 t={t['title']:t for t in f['tile_list']}
 if phase==6:return not t
 first='lifecycle-original' if phase==0 else 'lifecycle-renamed'
 if set(t)!={first,*(['lifecycle-second'] if phase in [3,4] else [])}:return False
 a=t[first];w,h=(320,256) if phase>=4 else (256,192);x,y=(-6016,-684) if phase>=2 else (-6080,-716)
 if [int(a[k]) for k in ['width','height','x','y']]!=[w,h,x,y]:return False
 if phase in [3,4]:
  a=t['lifecycle-second'];return [int(a[k]) for k in ['width','height','x','y']]==[128,192,-5568,-652]
 return True
coverage=[]
for i,event in enumerate(phases):
 phase=int(event['phase']);lo=int(event['at']);hi=int(phases[i+1]['at']) if i+1<len(phases) else 2**63-1
 seen=[f for f in frames if int(f['pts'])<hi and matches(f,phase)];assert seen,phase
 coverage.append({'phase':phase,'matching_frames':len(seen),'first_frame_pts_minus_post_action_log_ms':(int(seen[0]['pts'])-lo)/10000})
assert any(int(r['used'])==1 and int(r['tiles'])==1 for r in routes)
assert any(int(r['used'])==0 and int(r['tiles'])==2 for r in routes)
assert sum(int(r['periodic']) for r in sources)>=3 and max(int(r['unchanged_skips']) for r in sources)>0
assert all(r['foreground_initial']==r['foreground_now'] for r in phases)
state=json.loads((p/'state.json').read_text());assert state['before']==state['after'] and not state['after']['processes'] and state['native_hash_after']==state['expected_native_hash'] and state['task']['result']==0
text=(p/'source.log').read_text(errors='replace');assert text.count('resize_pending=1')==1
assert 'gl_error=0 fixture_alpha=verified' in (p/'decode.log').read_text()
summary={'scope':'owned Windows source -> recorded HEVC/exact alpha -> Linux NVDEC/CUDA/GLES upload; includes resizing and window metadata, excludes live Wayland proxy and physical input acceptance','frames':len(frames),'decoded':len(decoded),'atlas_sizes':sorted({(int(f['width']),int(f['height'])) for f in frames}),'phase_coverage':coverage,'timing_note':'Phase markers were recorded after each Win32 action. A concurrent source update can precede that marker; signed differences are diagnostic, not action-to-output latency. Initial source/codec startup is included.','resize_recoveries':1,'periodic_refreshes':sum(int(r['periodic']) for r in sources),'unchanged_iterations_skipped':max(int(r['unchanged_skips']) for r in sources),'focus_unchanged_at_all_phase_samples':True,'qualified':True}
(b/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
