from pathlib import Path
import re,json,statistics,math
b=Path(__file__).resolve().parent.parent
rows=lambda p,k:[{a:int(v) for a,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in p.read_text().splitlines() if line.startswith(k+' ')]
alpha=rows(b/'runs/source.log','profile_alpha_ready');colors=rows(b/'runs/source.log','profile_color_ready');s=rows(b/'runs/source.log','profile_submit');o=rows(b/'runs/source.log','profile_output');f=rows(b/'runs/fixture.log','fixture_frame');c=rows(b/'runs/source.log','profile_capture');d=rows(b/'runs/decode.log','record_frame') if (b/'runs/decode.log').exists() else []
assert s and o and f and c
start=o[0]['write_end']+50000000;end=o[-1]['write_end'];out=[x for x in o if x['write_end']>=start];sub={x['pts']:x for x in s};fixtures={x['id']:x for x in f}
def stats(values):
 v=sorted(values);return dict(n=len(v),median=statistics.median(v),p95=v[math.ceil(len(v)*.95)-1],p99=v[math.ceil(len(v)*.99)-1],max=max(v),min=min(v))
r={'scope':'6K opaque fixture, Windows WGC->HEVC+alpha->local file only; excludes QUIC and Linux presentation','source_frames':len(o),'captures':len(c),'warmup_seconds':5,'steady_frames':len(out),'steady_output_hz':(len(out)-1)*1e7/(out[-1]['write_end']-out[0]['write_end']),'stages_ms':{}}
for name,key1,key2 in [('encoder_submit','submit_begin','submit_end'),('alpha_enqueue','alpha_begin','alpha_end'),('frame_work','begin','alpha_pack_end')]:r['stages_ms'][name]=stats([(sub[x['pts']][key2]-sub[x['pts']][key1])/1e4 for x in out])
am={x['pts']:x for x in alpha};cm={x['pts']:x for x in colors}
for name,k1,k2 in [('alpha_cpu_copy','begin','copied'),('alpha_compare_pack','copied','packed')]:r['stages_ms'][name]=stats([(am[x['pts']][k2]-am[x['pts']][k1])/1e4 for x in out])
r['stages_ms']['alpha_enqueue_to_collect']=stats([(am[x['pts']]['begin']-sub[x['pts']]['alpha_begin'])/1e4 for x in out])
r['stages_ms']['submit_to_color_poll']=stats([(cm[x['pts']]['at']-sub[x['pts']]['submit_begin'])/1e4 for x in out])
r['stages_ms']['submit_to_output']=stats([(x['pack_begin']-sub[x['pts']]['submit_begin'])/1e4 for x in out]);r['stages_ms']['pack_write']=stats([(x['write_end']-x['pack_begin'])/1e4 for x in out]);r['wgc_future_timestamp_count']=sum(x['capture']>x['copied'] for x in c)
if d:
 dm={x['pts']:x for x in d};assert len(dm)==len(o) and set(dm)=={x['pts'] for x in o}
 unique=[]
 for x in out:
  marker=dm[x['pts']]['marker'];assert marker in fixtures
  if not unique or unique[-1][1]!=marker:unique.append((x['write_end'],marker))
 r['marker_validation']={'decoded':len(d),'steady_distinct':len(unique),'steady_unique_hz':(len(unique)-1)*1e7/(unique[-1][0]-unique[0][0]),'regressions':sum(b[1]<a[1] for a,b in zip(unique,unique[1:]))}
 r['stages_ms']['fixture_pre_draw_to_output']=stats([(x['write_end']-fixtures[dm[x['pts']]['marker']]['begin'])/1e4 for x in out])
 r['offline_gpu_decode_ms']=stats([x['decode_ns']/1e6 for x in d]);r['offline_gpu_upload_ms']=stats([x['upload_ns']/1e6 for x in d])
state=json.loads((b/'method/run-state.json').read_text())
r['run_qualified']=state['task']['result']==0 and not state['after']['processes'] and bool(d)
r['qualification_note']='normal bounded exit and all emitted frames decoded' if r['run_qualified'] else 'diagnostic only: failed run or decode validation incomplete'
(b/'summary.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,indent=2))
