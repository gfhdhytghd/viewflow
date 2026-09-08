from pathlib import Path
import sys,json
sys.path.insert(0,'tools');import profile_atlas_timeline as t
raw=Path('/tmp/viewflow-integrated-pair');label='4k-dual-observer-a'
w=(raw/f'window-{label}.log').read_text();d=(raw/f'desktop-{label}.log').read_text()
f=t.numbers(t.rows(w,'window-observer ')[0])['qpc_frequency']
wr=[t.numbers(x) for x in t.rows(w,'window-marker ')];dr=[t.numbers(x) for x in t.rows(d,'desktop-marker ')]
ws={x['frame']:x for x in wr};ds={x['frame']:x for x in dr}
assert len(ws)==len(wr) and len(ds)==len(dr)
pairs=[]
for marker in sorted(ws.keys() & ds.keys()):
 a=ws[marker];b=ds[marker]
 pairs.append(dict(marker=marker,window_render_qpc=a['render_qpc'],desktop_present_qpc=b['present_qpc'],window_acquired_qpc=a['acquired_qpc'],desktop_observed_qpc=b['observed_qpc'],window_render_minus_desktop_ms=(a['render_qpc']-b['present_qpc'])*1000/f))
result=dict(label=label,paired_markers=len(pairs),window_only=len(ws.keys()-ds.keys()),desktop_only=len(ds.keys()-ws.keys()),window_render_minus_desktop_ms=t.stats([p['window_render_minus_desktop_ms'] for p in pairs]),window_render_after_desktop=sum(p['window_render_minus_desktop_ms']>0 for p in pairs),pairs=pairs)
p=Path('/tmp/viewflow-dual-observer-comparison.json');old=json.loads(p.read_text()) if p.exists() else result;assert old==result,'reanalysis differs';p.write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k!='pairs'})
