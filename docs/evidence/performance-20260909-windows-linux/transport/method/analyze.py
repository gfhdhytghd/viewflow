from pathlib import Path
import json,re,math,statistics,bisect,sys
b=Path(__file__).resolve().parent.parent;label=sys.argv[1] if len(sys.argv)>1 else 'baseline';p=b/'runs'/label
def rows(file,prefix):return [{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in file.read_text(errors='replace').splitlines() if line.startswith(prefix+' ')]
clocks=rows(p/'linux.log','reverse_clock');frames=rows(p/'fixture.log','fixture_frame');seen=rows(p/'desktop.log','desktop_marker');state=json.loads((p/'state.json').read_text());assert len(clocks)>=100 and frames and seen
for c in clocks:c.update(mid=(c['t1']+c['t4'])//2,low=c['t3']-c['t4'],high=c['t2']-c['t1'],rtt=c['t4']-c['t1']-c['t3']+c['t2']);assert c['rtt']>=0
assert all(x['valid']==1 for x in seen);first=[]
for x in seen:
 if not first or first[-1]['marker']!=x['marker']:first.append(x)
assert all(y['marker']>x['marker'] for x,y in zip(first,first[1:]));fixtures={x['id']:x for x in frames};assert all(x['marker'] in fixtures for x in first)
def stats(v):
 v=sorted(v);return dict(n=len(v),min=v[0],median=statistics.median(v),p95=v[math.ceil(len(v)*.95)-1],p99=v[math.ceil(len(v)*.99)-1],max=v[-1])
# At each observation, cover nearby clock intervals. This includes their
# entire observed spread instead of assuming a constant host/guest offset.
# End-to-end intervals are clock-sampling estimates, not a hardware clock proof.
matched=[]
for x in first:
 near=[c for c in clocks if abs(c['mid']-x['mono'])<=500_000_000];assert len(near)>=3
 low=min(c['low'] for c in near);high=max(c['high'] for c in near)
 t=fixtures[x['marker']]['begin']*100
 matched.append(dict(marker=x['marker'],mono=x['mono'],source_pre_draw_ns=t,latency_low_ms=(x['mono']-t+low)/1e6,latency_high_ms=(x['mono']-t+high)/1e6,clock_width_ms=(high-low)/1e6))
start=first[0]['mono']+3_000_000_000;steady=[x for x in matched if x['mono']>=start]
assert state['observer_exit']==0 and state['client_exit']==0 and state['task']['result']==0 and not state['after']['processes'] and not state['remaining_proxies']
r={'scope':'Windows fixture pre-draw -> WGC -> HEVC+exact alpha -> paired QUIC -> Linux NVDEC/CUDA/GLES/Wayland -> nested Hyprland desktop ROI observed; no physical scanout measurement','observer_captures':len(seen),'distinct_total':len(first),'warmup_observer_seconds':3,'steady_distinct':len(steady),'desktop_distinct_hz':(len(steady)-1)*1e9/(steady[-1]['mono']-steady[0]['mono']),'latency_low_ms':stats([x['latency_low_ms'] for x in steady]),'latency_high_ms':stats([x['latency_high_ms'] for x in steady]),'clock_envelope_width_ms':stats([x['clock_width_ms'] for x in steady]),'clock_rtt_ms':stats([x['rtt']/1e6 for x in clocks]),'clock_samples':len(clocks),'clock_estimation':'envelope of observed offset intervals within +/-0.5s; no assumed symmetric network delay; does not certify clock drift between samples','run_qualified':True,'target_6k30_60ms_met':False}
if (p/'source-desktop.log').exists():
 source=rows(p/'source-desktop.log','source_desktop');header=rows(p/'source-desktop.log','source_observer')[0];source_by_id={x['marker']:x for x in source};pairs=[]
 for x in matched:
  if x['mono']<start or x['marker'] not in source_by_id:continue
  row=source_by_id[x['marker']];source_ns=row['present_qpc']*1_000_000_000//header['frequency'];extra=(x['source_pre_draw_ns']-source_ns)/1e6
  pairs.append(dict(marker=x['marker'],desktop_low_ms=x['latency_low_ms']+extra,desktop_high_ms=x['latency_high_ms']+extra,draw_to_source_desktop_ms=-extra))
 r['source_desktop_pairs']=len(pairs);r['source_desktop_missing']=len(steady)-len(pairs);assert len(pairs)>len(steady)*.9
 r['source_desktop_to_linux_low_ms']=stats([x['desktop_low_ms'] for x in pairs]);r['source_desktop_to_linux_high_ms']=stats([x['desktop_high_ms'] for x in pairs]);r['fixture_draw_to_source_desktop_ms']=stats([x['draw_to_source_desktop_ms'] for x in pairs]);(p/'desktop-matched.json').write_text(json.dumps(pairs,indent=2)+'\n')
r['evaluation_criterion']={'desktop_distinct_hz_min':30,'latency_high_p95_ms_max':60,'note':'Operational analysis criterion; not a session timeout. Physical scanout remains unmeasured.'}
r['target_6k30_60ms_met']=r['desktop_distinct_hz']>=30 and r['latency_high_ms']['p95']<=60
r['largest_latency_observations']=sorted(steady,key=lambda x:x['latency_high_ms'],reverse=True)[:3]
r['distinct_observation_gap_ms']=stats([(y['mono']-x['mono'])/1e6 for x,y in zip(steady,steady[1:])])
(p/'summary.json').write_text(json.dumps(r,indent=2)+'\n');(p/'matched.json').write_text(json.dumps(matched,indent=2)+'\n');print(json.dumps(r,indent=2))
