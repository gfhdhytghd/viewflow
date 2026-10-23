from pathlib import Path
import sys,json
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
root=Path(__file__).resolve().parent/'runs';results=[]
for label in ['live-a1','cached30-b1','cached30-b2','live-a2']:
 p=root/(label+'-probe.log');dp=root/(label+'-desktop.log');sp=root/(label+'-state.json')
 if not all(x.exists() for x in [p,dp,sp]):continue
 text=p.read_text();desktop=dp.read_text();state=json.loads(sp.read_text(encoding='utf-8-sig'))
 assert state['probe_exit']==state['observer_exit']==state['owned_processes']==state['owned_tasks']==0
 raw=t.rows(text,'probe ')[0];header={**raw,**t.numbers(raw)};ready=t.numbers(t.rows(text,'probe-ready ')[0]);final=t.numbers(t.rows(text,'probe-result ')[0]);obs=d.summarize(desktop)
 f=header['qpc_frequency'];dd=t.numbers(t.rows(desktop,'observer ')[0]);assert f==dd['qpc_frequency'] and state['pid']==ready['pid']==dd['pid']
 assert header['width']==3848 and header['height']==2408 and final['foreground_unchanged']==1
 assert obs['nonincreasing_frame_ids']==obs['nonincreasing_present_timestamps']==0
 rows=[t.numbers(x) for x in t.rows(text,'probe-frame ')];frames={x['frame']:x for x in rows};assert len(frames)==len(rows)==final['frames']
 order=['render_qpc','drawn_qpc','begin_qpc','copied_qpc','ended_qpc','mutation_qpc','committed_qpc']
 for x in rows:
  assert all(x[b]>=x[a] for a,b in zip(order,order[1:]));assert x['backgrounds']==4 and x['host_flag']==1
 assert all(b['frame']>a['frame'] and b['render_qpc']>a['render_qpc'] for a,b in zip(rows,rows[1:]))
 pairs=[];mouse=0
 for raw in t.rows(desktop,'desktop-marker '):
  o=t.numbers(raw)
  if not o['present_qpc']:mouse+=1;continue
  assert o['frame'] in frames and o['input']==0
  source=frames[o['frame']];assert o['present_qpc']>=source['render_qpc']
  if source['frame']<120:continue
  pairs.append({**source,'sequence':o['sequence'],'present_qpc':o['present_qpc']})
 assert pairs and all(b['sequence']>a['sequence'] for a,b in zip(pairs,pairs[1:]))
 rb=t.numbers(t.rows(desktop,'readback-result ')[0]);assert rb['abandoned']==0 and rb['pending_peak']<=3
 def latency(a,b):return t.stats([(p[b]-p[a])*1000/f for p in pairs])
 bg=t.rows(text,'background-cache ');bg=t.numbers(bg[0]) if bg else None
 if bg:assert bg['error']==0 and bg['published']>0 and bg['taken']>0
 elapsed=final['elapsed_qpc']/f
 result=dict(label=label,header=header,state=state,ready=ready,final=final,observed=obs,readback=rb,mouse_only_excluded=mouse,n=len(pairs),
  native_submit_hz=final['frames']/elapsed,observed_change_hz=(len(pairs)-1)*f/(pairs[-1]['present_qpc']-pairs[0]['present_qpc']),
  render_to_dd_ms=latency('render_qpc','present_qpc'),mutation_to_dd_ms=latency('mutation_qpc','present_qpc'),render_to_mutation_ms=latency('render_qpc','mutation_qpc'),background=bg,background_taken_hz=bg['taken']/elapsed if bg else None)
 (root/(label+'-pairs.json')).write_text(json.dumps(pairs,indent=2)+'\n');results.append(result)
 print(json.dumps({k:result[k] for k in ['label','n','native_submit_hz','observed_change_hz','render_to_dd_ms','mutation_to_dd_ms','render_to_mutation_ms','background_taken_hz']}),flush=True)
if len(results)==4:
 assert len({r['state']['probe_hash'] for r in results})==len({r['state']['observer_hash'] for r in results})==1
(root.parent/'comparison.json').write_text(json.dumps(results,indent=2)+'\n')
