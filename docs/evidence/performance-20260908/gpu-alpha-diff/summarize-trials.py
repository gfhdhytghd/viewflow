from pathlib import Path
import json,sys,re,gzip,shutil,hashlib,collections
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
raw=Path('/tmp/viewflow-integrated-pair');dest=Path('docs/evidence/performance-20260908/gpu-alpha-diff');dest.mkdir(exist_ok=True)
comparison=[]
for label in ['4k-alpha-diff-off-a1','4k-alpha-diff-on-b1','4k-alpha-diff-on-b2','4k-alpha-diff-off-a2']:
 out=dest/label;out.mkdir(exist_ok=True);text={}
 for name in ['source','receiver','desktop','runner','cleanup']:
  text[name]=(raw/f'{name}-{label}.log').read_text()
  with gzip.open(out/(name+'.log.gz'),'wb') as z:z.write(text[name].encode())
 producer=(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_text()
 with gzip.open(out/'producer.log.gz','wb') as z:z.write(producer.encode())
 shutil.copy(raw/f'fixture-{label}.json',out/'fixture.json')
 _,c=t.export(text['source'],text['receiver'],text['desktop']);b=d.latency_bounds(text['desktop'],text['source'],producer,text['receiver'])
 commits=[t.numbers(x) for x in t.rows(text['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
 gpu='-on-' in label;cache={};steps={};invalid=[];transfers={}
 for x in t.rows(text['source'],'GPU alpha-transfer '):transfers.setdefault(int(x['frame']),[]).append(x)
 for x in t.rows(text['source'],'alpha-copy-profile '):steps.setdefault(int(x['frame']),[]).append(x)
 for x in t.rows(text['source'],'alpha-cache-profile '):cache.setdefault(int(x['frame']),[]).append(x)
 alpha=[];alpha_cache=[];full_stages=collections.defaultdict(list)
 for f,values in cache.items():
  if f<30:continue
  if len(values)!=1:invalid.append([f,'duplicate cache']);continue
  value=values[0];parts=steps.get(f,[]);kinds=[x['stage'] for x in parts]
  transfer=transfers.get(f,[])
  if len(transfer)!=1:invalid.append([f,'transfer identity']);continue
  transfer=transfer[0]
  compared=transfer['compared']=='1'
  if compared and not gpu:invalid.append([f,'unexpected GPU compare']);continue
  expected=[] if compared else ['native_alpha_compare']
  if transfer['download_bytes']=='0' and not compared:invalid.append([f,'missing GPU comparison for no readback']);continue
  if any(kinds.count(k)!=1 for k in expected) or len(kinds)!=len(set(kinds)) or any(k not in ['native_alpha_compare','pinned_to_vector'] for k in kinds):invalid.append([f,'profile identity/stage',kinds]);continue
  if value['cpu_valid']!='true' or any(x['clocks_valid']!='1' or x['bytes']!=value['bytes'] for x in parts):invalid.append([f,'clock/shape']);continue
  total=int(value['cpu_ns'])+sum(int(x['cpu_ns']) for x in parts)
  alpha.append(total/1e6);alpha_cache.append(int(value['cpu_ns'])/1e6)
  for x in parts:full_stages[x['stage']].append(int(x['cpu_ns'])/1e6)
 storage=t.rows(text['source'],'GPU alpha-storage ')
 assert all(x['mode']=='shared-snapshot' for x in storage)
 assert ('GPU alpha-diff enabled='+str(int(gpu))) in text['source']
 assert not invalid,invalid
 row=dict(label=label,gpu_compared_preparations=sum(x['compared']=='1' for values in transfers.values() for x in values),full_readback_preparations=sum(int(x['download_bytes'])>0 for values in transfers.values() for x in values),alpha_readback_bytes=sum(int(x['download_bytes']) for values in transfers.values() for x in values),alpha_cpu_ms=t.stats(alpha),rust_cache_cpu_ms=t.stats(alpha_cache),alpha_stages_cpu_ms={k:t.stats(v) for k,v in full_stages.items()},invalid_alpha_profiles=invalid,alpha_snapshot_reused=sum(x['reused']=='1' for x in storage),alpha_prepare_records=len(storage),pinned_copy_records=sum(x['stage']=='pinned_to_vector' for xs in steps.values() for x in xs),native_commit_hz=(len(commits)-1)*commits[0]['frequency']/(commits[-1]['qpc']-commits[0]['qpc']),encode_ms=c['wall_stage_ms']['encode (host incl waits)'],capture_to_mutation_ms=b['unique_capture_stage_samples']['capture_to_mutation_upper_ms'],capture_to_seen_desktop_ms=b['unique_capture_stage_samples']['capture_to_desktop_upper_ms'])
 for name,value in [('summary',row),('clock-and-stages',c),('desktop',b)]: (out/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n')
 # Nonoverlapping cumulative native checkpoints isolate the entire NV12,
 # alpha comparison/readback and host-snapshot segment, including waits.
 alpha_wall=[]
 for line in text['source'].splitlines():
  match=re.fullmatch(r'GPU encode-detail frame=(\d+) disposition=(\d+) truncated=0 marks=(.*)',line)
  if not match or int(match[1])<30:continue
  marks=dict((k,int(v)) for k,v in re.findall(r'(\w+):(\d+)',match[3]))
  if 'copy_prepare' in marks and 'nv12_alpha_readback' in marks:alpha_wall.append((marks['nv12_alpha_readback']-marks['copy_prepare'])/1000)
 row['nv12_alpha_host_ms']=t.stats(alpha_wall)
 (out/'summary.json').write_text(json.dumps(row,indent=2)+'\n')
 comparison.append(row)
 print(label,'alpha',row['alpha_cpu_ms']['median'],'enc',row['encode_ms']['median'],'mutation',row['capture_to_mutation_ms']['median'],'seen',row['capture_to_seen_desktop_ms']['median'],'commits',row['native_commit_hz'],'copies',row['pinned_copy_records'])
(dest/'comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
shutil.copy('/tmp/viewflow-gpu-alpha-diff-trial-source-sha256.json',dest/'trial-source-sha256.json')
