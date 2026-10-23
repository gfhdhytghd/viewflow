from pathlib import Path
import sys,json
sys.path.insert(0,str(Path(__file__).resolve().parent))
import profile_atlas_timeline as t
import summarize_desktop_markers as d
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path('/tmp/viewflow-commit-request-probe');results=[]
for label in (sys.argv[2:] if len(sys.argv)>2 else ['probe-request-ab','probe-request-ba']):
 text=(root/(label+'-probe.log')).read_text();desktop=(root/(label+'-desktop.log')).read_text();state=json.loads((root/(label+'-state.json')).read_text(encoding='utf-8-sig'))
 assert state['probe_exit']==state['observer_exit']==state['owned_processes']==state['owned_tasks']==0
 raw=t.rows(text,'probe ')[0];header={**raw,**t.numbers(raw)};ready=t.numbers(t.rows(text,'probe-ready ')[0]);final=t.numbers(t.rows(text,'probe-result ')[0]);obs=d.summarize(desktop)
 f=header['qpc_frequency'];dd=t.numbers(t.rows(desktop,'observer ')[0]);assert f==dd['qpc_frequency'] and state['pid']==ready['pid']==dd['pid']
 assert header['width']==3848 and header['height']==2408 and final['foreground_unchanged']==1
 assert obs['nonincreasing_frame_ids']==obs['nonincreasing_present_timestamps']==0
 rows=[t.numbers(x) for x in t.rows(text,'probe-frame ')];frames={x['frame']:x for x in rows};assert len(frames)==len(rows)==final['frames']
 order=['render_qpc','drawn_qpc','begin_qpc','copied_qpc','ended_qpc','mutation_qpc','committed_qpc']
 for x in rows:
  assert all(x[b]>=x[a] for a,b in zip(order,order[1:]))
  assert x['phase']==(x['frame']-1)//240 and x['phase_frame']==(x['frame']-1)%240
  assert x['backgrounds']==4 and x['host_flag']==1
  assert x['request_enabled']==int((x['phase']%2!=0)!=(header['mode']=='request-toggle-reverse'))
 request=t.numbers(t.rows(text,'request-result ')[0]);assert request['failed']==request['wait_used']==0
 assert request['started']==sum(x['requested'] for x in rows)==request['completed']+request['pending']
 assert request['peak']<=32
 for x in rows:
  assert x['requested']==x['request_enabled'] and x['request_skipped']==x['request_hr']==0
  if x['requested']:assert x['mutation_qpc']<=x['request_begin_qpc']<=x['request_end_qpc']<=x['committed_qpc']
 assert all(b['frame']>a['frame'] and b['render_qpc']>a['render_qpc'] for a,b in zip(rows,rows[1:]))
 pairs=[];mouse=0;warmup=0
 for raw in t.rows(desktop,'desktop-marker '):
  o=t.numbers(raw)
  if not o['present_qpc']:mouse+=1;continue
  assert o['frame'] in frames and o['input']==0
  source=frames[o['frame']];assert o['present_qpc']>=source['render_qpc']
  p={**source,'sequence':o['sequence'],'present_qpc':o['present_qpc'],'warmup':source['phase_frame']<30}
  pairs.append(p);warmup+=p['warmup']
 assert pairs and all(b['sequence']>a['sequence'] for a,b in zip(pairs,pairs[1:]))
 rb=t.numbers(t.rows(desktop,'readback-result ')[0]);assert rb['abandoned']==0 and rb['pending_peak']<=3
 def stat(a):
  return {'n':len(a),'mutation_to_dd_ms':t.stats([(p['present_qpc']-p['mutation_qpc'])*1000/f for p in a]),'render_to_dd_ms':t.stats([(p['present_qpc']-p['render_qpc'])*1000/f for p in a]),'negative_mutation':sum(p['present_qpc']<p['mutation_qpc'] for p in a),'observed_change_hz':(len(a)-1)*f/(a[-1]['present_qpc']-a[0]['present_qpc']) if len(a)>1 else None}
 phases=[]
 for phase in sorted({p['phase'] for p in pairs}):
  selected=[p for p in pairs if p['phase']==phase and not p['warmup']]
  if not selected:continue
  phases.append({'phase':phase,'request_enabled':selected[0]['request_enabled'],'first_frame':selected[0]['frame'],'last_frame':selected[-1]['frame'],**stat(selected)})
 # Aggregated latency is valid; do not aggregate change rate across noncontiguous phases.
 grouped={}
 for bg in [0,1]:
  grouped[str(bg)]=stat([p for p in pairs if p['request_enabled']==bg and not p['warmup']]);del grouped[str(bg)]['observed_change_hz']
 result=dict(request_result=request,request_call_ms=t.stats([(x['request_end_qpc']-x['request_begin_qpc'])*1000/f for x in rows if x['requested']]),label=label,header=header,state=state,ready=ready,final=final,observed=obs,readback=rb,mouse_only_excluded=mouse,warmup_excluded=warmup,phases=phases,grouped=grouped)
 (root/(label+'-pairs.json')).write_text(json.dumps(pairs,indent=2)+'\n');results.append(result)
 print(label, json.dumps({'request_result':request,'request_call_ms':result['request_call_ms'],'grouped':grouped}),flush=True)
(root/'request-comparison.json').write_text(json.dumps(results,indent=2)+'\n')
