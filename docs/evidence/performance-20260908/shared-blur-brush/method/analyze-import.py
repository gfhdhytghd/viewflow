from pathlib import Path
import json,re,sys,collections
sys.path.insert(0,str(Path(__file__).resolve().parent))
import profile_atlas_timeline as t
root=Path(sys.argv[1]);out=[]
for label in sys.argv[2:]:
 p=root/label;text=(p/'source.log').read_text();ids=[t.numbers(r) for r in t.rows(text,'GPU import-identity ')];assert ids and all(r['stat']==0 for r in ids)
 by_key=collections.Counter(tuple(r[k] for k in ['dev','ino','width','height','stride','offset','fourcc','modifier']) for r in ids)
 rows=[];malformed=0
 for line in text.splitlines():
  if not line.startswith('GPU encode-detail '):continue
  if ' marks=' not in line:malformed+=1;continue
  m=re.search(r'frame=(\d+)',line);assert m
  raw=line.split(' marks=',1)[1];pairs=re.findall(r'([a-z0-9_]+):(\d+)',raw);marks={k:int(v) for k,v in pairs}
  if not pairs or raw!=','.join(k+':'+v for k,v in pairs) or len(marks)!=len(pairs):malformed+=1;continue
  if int(m[1])<30:continue
  rows.append(marks)
 stages={}
 for start,end in [('fence','egl_image'),('egl_image','egl_bind'),('egl_bind','gl_finish'),('gl_finish','cuda_register'),('cuda_register','import'),('fence','import'),('import','copy_prepare'),('copy_prepare','nv12_alpha_readback'),('nv12_alpha_readback','nvenc'),('nvenc','return')]:
  values=[(r[end]-r[start])/1000 for r in rows if start in r and end in r];assert values and min(values)>=0
  stages[start+' to '+end]=t.stats(values)
 total=[r['return']/1000 for r in rows if 'return' in r]
 result=dict(label=label,identity_rows=len(ids),unique_storage_keys=len(by_key),storage_keys=[dict(zip(['dev','ino','width','height','stride','offset','fourcc','modifier'],key),observations=count) for key,count in by_key.items()],stage_ms=stages,total_encode_ms=t.stats(total),malformed_detail_lines=malformed,cache_rows=[t.numbers(r) for r in t.rows(text,'GPU import-cache ')])
 state=json.loads((p/'state.json').read_text())
 if 'import_cache_mode' in state:
  mode=int(state['import_cache_mode']);snapshots=result['cache_rows'];assert snapshots
  assert all(r['enabled']==mode and r['capacity']==4 and r['entries']<=4 for r in snapshots)
  assert all(b['imports']>a['imports'] for a,b in zip(snapshots,snapshots[1:]))
  if mode:
   assert all(r['hits']+r['misses']==r['imports'] and r['entries']<=r['misses']-r['evictions'] for r in snapshots)
   assert snapshots[-1]['hits']>0
  else:assert all(r['hits']==r['misses']==r['evictions']==r['entries']==0 for r in snapshots)
  result['last_cache_snapshot']=snapshots[-1]
 (p/'import-analysis.json').write_text(json.dumps(result,indent=2)+'\n');out.append(result)
 print(label,'identity rows',len(ids),'storage keys',len(by_key),'import ms',stages['fence to import'],'total',result['total_encode_ms'],'malformed',malformed,flush=True)
(root/'import-comparison.json').write_text(json.dumps(out,indent=2)+'\n')
