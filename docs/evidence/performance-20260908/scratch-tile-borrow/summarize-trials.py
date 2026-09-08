from pathlib import Path
import json,sys,re,gzip,shutil,hashlib
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
p=Path('/tmp/viewflow-integrated-pair');dest=Path('docs/evidence/performance-20260908/scratch-tile-borrow');dest.mkdir(exist_ok=True);comparison=[]
for label in ['4k-scratch-copy-a1','4k-scratch-borrow-b1','4k-scratch-borrow-b2','4k-scratch-copy-a2']:
 out=dest/label;out.mkdir(exist_ok=True);text={}
 for name in ['source','receiver','desktop','runner','cleanup']:
  text[name]=(p/f'{name}-{label}.log').read_text()
  with gzip.open(out/(name+'.log.gz'),'wb') as z:z.write(text[name].encode())
 producer=(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_text()
 with gzip.open(out/'producer.log.gz','wb') as z:z.write(producer.encode())
 shutil.copy(p/f'fixture-{label}.json',out/'fixture.json')
 _,c=t.export(text['source'],text['receiver'],text['desktop']);b=d.latency_bounds(text['desktop'],text['source'],producer,text['receiver'])
 n=[t.numbers(x) for x in t.rows(text['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
 records=[];rejected=0
 for line in text['source'].splitlines():
  if not line.startswith('GPU encode-detail '):continue
  match=re.fullmatch(r'GPU encode-detail frame=(\d+) disposition=(\d+) truncated=0 marks=(.*)',line)
  if not match:rejected+=1;continue
  marks=[(k,int(v)) for k,v in re.findall(r'(\w+):(\d+)',match[3])]
  if not marks or marks[-1][0]!='return':rejected+=1;continue
  records.append(dict(frame=int(match[1]),disposition=int(match[2]),marks=marks))
 fields={name:[] for name in ['total','import','prepare_after_import','after_cleanup']}
 for x in records:
  m=dict(x['marks'])
  if x['frame']<30:continue
  if 'return' in m:fields['total'].append(m['return']/1000)
  if 'import' in m:fields['import'].append(m['import']/1000)
  if 'import'in m and 'copy_prepare'in m:fields['prepare_after_import'].append((m['copy_prepare']-m['import'])/1000)
  if 'cleanup'in m and 'return'in m:fields['after_cleanup'].append((m['return']-m['cleanup'])/1000)
 row=dict(label=label,native_commit_hz=(len(n)-1)*n[0]['frequency']/(n[-1]['qpc']-n[0]['qpc']),encode_ms=c['wall_stage_ms']['encode (host incl waits)'],capture_to_mutation_ms=b['unique_capture_stage_samples']['capture_to_mutation_upper_ms'],capture_to_seen_desktop_ms=b['unique_capture_stage_samples']['capture_to_desktop_upper_ms'],gpu_wall_ms={k:t.stats(v) for k,v in fields.items()},gpu_detail_rejected=rejected,borrow_count=sum(any(k=='tile_borrow' for k,_ in x['marks']) for x in records),free_count=sum(any(k=='tile_free' for k,_ in x['marks']) for x in records),mode=[x for x in text['source'].splitlines() if x.startswith('GPU prepared-tile storage=')],slow_gpu=sorted(records,key=lambda x:x['marks'][-1][1],reverse=True)[:6])
 for filename,value in [('summary',row),('clock-and-stages',c),('desktop',b)]:
  (out/(filename+'.json')).write_text(json.dumps(value,indent=2)+'\n')
 comparison.append(row)
 print(label,'prepare',round(row['gpu_wall_ms']['prepare_after_import']['median'],4),'cleanup',round(row['gpu_wall_ms']['after_cleanup']['median'],4),'enc',round(row['encode_ms']['median'],4),'commit',round(row['native_commit_hz'],3))
(dest/'comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
shutil.copy('/tmp/viewflow-scratch-swap-trial-source-sha256.json',dest/'trial-source-sha256.json')
