from pathlib import Path
import json,sys,re,gzip,shutil,hashlib,collections
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
raw=Path('/tmp/viewflow-integrated-pair');dest=Path('docs/evidence/performance-20260908/source-alpha-snapshots');dest.mkdir(exist_ok=True)
comparison=[]
for label in ['4k-alpha-share-off-a1','4k-alpha-share-on-b1','4k-alpha-share-on-b2','4k-alpha-share-off-a2']:
 out=dest/label;out.mkdir(exist_ok=True);text={}
 for name in ['source','receiver','desktop','runner','cleanup']:
  text[name]=(raw/f'{name}-{label}.log').read_text()
  with gzip.open(out/(name+'.log.gz'),'wb') as z:z.write(text[name].encode())
 producer=(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_text()
 with gzip.open(out/'producer.log.gz','wb') as z:z.write(producer.encode())
 shutil.copy(raw/f'fixture-{label}.json',out/'fixture.json')
 _,c=t.export(text['source'],text['receiver'],text['desktop']);b=d.latency_bounds(text['desktop'],text['source'],producer,text['receiver'])
 commits=[t.numbers(x) for x in t.rows(text['receiver'],'atlas-native-timing ') if x['phase']=='committed' and int(x['frame'])>=30]
 reuse='-on-' in label;cache={};steps={};invalid=[]
 for x in t.rows(text['source'],'alpha-copy-profile '):steps.setdefault(int(x['frame']),[]).append(x)
 for x in t.rows(text['source'],'alpha-cache-profile '):cache.setdefault(int(x['frame']),[]).append(x)
 alpha=[];alpha_cache=[];full_stages=collections.defaultdict(list)
 for f,values in cache.items():
  if f<30:continue
  if len(values)!=1:invalid.append([f,'duplicate cache']);continue
  value=values[0];parts=steps.get(f,[]);kinds=[x['stage'] for x in parts]
  expected='native_alpha_compare' if reuse else 'pinned_to_vector'
  if kinds.count(expected)!=1 or len(kinds)!=len(set(kinds)) or any(k not in ['native_alpha_compare','pinned_to_vector'] for k in kinds):invalid.append([f,'profile identity/stage',kinds]);continue
  if value['cpu_valid']!='true' or any(x['clocks_valid']!='1' or x['bytes']!=value['bytes'] for x in parts):invalid.append([f,'clock/shape']);continue
  total=int(value['cpu_ns'])+sum(int(x['cpu_ns']) for x in parts)
  alpha.append(total/1e6);alpha_cache.append(int(value['cpu_ns'])/1e6)
  for x in parts:full_stages[x['stage']].append(int(x['cpu_ns'])/1e6)
 storage=t.rows(text['source'],'GPU alpha-storage ')
 assert all(x['mode']==('shared-snapshot' if reuse else 'per-frame-copy') for x in storage)
 assert not invalid,invalid
 row=dict(label=label,alpha_cpu_ms=t.stats(alpha),rust_cache_cpu_ms=t.stats(alpha_cache),alpha_stages_cpu_ms={k:t.stats(v) for k,v in full_stages.items()},invalid_alpha_profiles=invalid,alpha_snapshot_reused=sum(x['reused']=='1' for x in storage),alpha_prepare_records=len(storage),pinned_copy_records=sum(x['stage']=='pinned_to_vector' for xs in steps.values() for x in xs),native_commit_hz=(len(commits)-1)*commits[0]['frequency']/(commits[-1]['qpc']-commits[0]['qpc']),encode_ms=c['wall_stage_ms']['encode (host incl waits)'],capture_to_mutation_ms=b['unique_capture_stage_samples']['capture_to_mutation_upper_ms'],capture_to_seen_desktop_ms=b['unique_capture_stage_samples']['capture_to_desktop_upper_ms'])
 for name,value in [('summary',row),('clock-and-stages',c),('desktop',b)]: (out/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n')
 comparison.append(row)
 print(label,'alpha',row['alpha_cpu_ms']['median'],'enc',row['encode_ms']['median'],'mutation',row['capture_to_mutation_ms']['median'],'seen',row['capture_to_seen_desktop_ms']['median'],'commits',row['native_commit_hz'],'copies',row['pinned_copy_records'])
(dest/'comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
shutil.copy('/tmp/viewflow-native-alpha-share-trial-source-sha256.json',dest/'trial-source-sha256.json')
