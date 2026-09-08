from pathlib import Path
import json,sys
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
root=Path('/tmp/viewflow-composition-latency-probe');results=[]
for label in sys.argv[1:]:
 text=(root/(label+'-probe.log')).read_text();desktop=(root/(label+'-desktop.log')).read_text();state=json.loads((root/(label+'-state.json')).read_text(encoding='utf-8-sig'))
 assert state['probe_exit']==state['observer_exit']==state['owned_processes']==state['owned_tasks']==0
 raw_header=t.rows(text,'probe ')[0];header={**raw_header,**t.numbers(raw_header)};ready=t.numbers(t.rows(text,'probe-ready ')[0]);final=t.numbers(t.rows(text,'probe-result ')[0]);observed=d.summarize(desktop)
 frequency=header['qpc_frequency'];ddheader=t.numbers(t.rows(desktop,'observer ')[0]);assert frequency==ddheader['qpc_frequency'] and state['pid']==ready['pid']==ddheader['pid']
 assert header['width']==3848 and header['height']==2408 and final['foreground_unchanged']==1
 assert observed['nonincreasing_frame_ids']==observed['nonincreasing_present_timestamps']==0
 rows=[t.numbers(x) for x in t.rows(text,'probe-frame ')];frames={x['frame']:x for x in rows};assert len(frames)==len(rows)==final['frames']
 order=['render_qpc','drawn_qpc','begin_qpc','copied_qpc','ended_qpc','mutation_qpc','committed_qpc']
 for x in rows:assert all(x[b]>=x[a] for a,b in zip(order,order[1:]))
 assert all(b['frame']>a['frame'] and b['render_qpc']>a['render_qpc'] for a,b in zip(rows,rows[1:]))
 samples=[x for x in rows if x['frame']>=30];pairs=[];mouse_only=0;warmup=0
 for row in t.rows(desktop,'desktop-marker '):
  o=t.numbers(row)
  if not o['present_qpc']:mouse_only+=1;continue
  if o['frame']<30:warmup+=1;continue
  assert o['frame'] in frames and o['input']==0
  f=frames[o['frame']];assert o['present_qpc']>=f['render_qpc']
  pairs.append({'frame':f['frame'],'sequence':o['sequence'],'present_qpc':o['present_qpc'],**{k:f[k] for k in order}})
 assert pairs and all(b['sequence']>a['sequence'] for a,b in zip(pairs,pairs[1:]))
 latency={k.removesuffix('_qpc')+'_to_desktop_ms':t.stats([(p['present_qpc']-p[k])*1000/frequency for p in pairs]) for k in ['render_qpc','ended_qpc','mutation_qpc','committed_qpc']}
 rb=t.numbers(t.rows(desktop,'readback-result ')[0]);assert rb['abandoned']==0 and rb['pending_peak']<=3
 stage={name:t.stats([(p[b]-p[a])*1000/frequency for p in samples]) for name,a,b in [('source_render_host','render_qpc','drawn_qpc'),('begin_and_copy_host','begin_qpc','copied_qpc'),('end_and_flush_host','copied_qpc','ended_qpc'),('bind_and_commit_host','mutation_qpc','committed_qpc')]}
 row=dict(label=label,mode=header['mode'],probe_hash=state['probe_hash'],observer_hash=state['observer_hash'],qpc_frequency=frequency,header=header,scene=t.rows(text,'probe-scene '),ready=ready,final=final,observed=observed,readback=rb,paired=len(pairs),mouse_only_excluded=mouse_only,warmup_excluded=warmup,latency=latency,host_stage_ms=stage,submitted_hz=(len(samples)-1)*frequency/(samples[-1]['committed_qpc']-samples[0]['committed_qpc']),negative_mutation_to_desktop=sum(p['present_qpc']<p['mutation_qpc'] for p in pairs),negative_commit_to_desktop=sum(p['present_qpc']<p['committed_qpc'] for p in pairs),monitor_lines=[x for x in desktop.splitlines() if x.startswith(('monitor ','adapter ','output ','desktop_image_'))])
 (root/(label+'-pairs.json')).write_text(json.dumps(pairs,indent=2)+'\n');results.append(row)
 print(label,'submitHz',round(row['submitted_hz'],3),'observedHz',round(observed['observed_changes_per_second'],3),'latency',latency['mutation_to_desktop_ms'])
(root/'startup-comparison.json').write_text(json.dumps(results,indent=2)+'\n')
