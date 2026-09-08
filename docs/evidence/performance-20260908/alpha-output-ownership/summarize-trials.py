from pathlib import Path
import sys,json,gzip,shutil,hashlib
sys.path.insert(0,'/home/wilf/data/viewflow/tools')
import profile_atlas_timeline as timeline
import summarize_alpha_profile as alpha
import summarize_desktop_markers as desktop
p=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260908/alpha-output-ownership');p.mkdir(exist_ok=True)
raw=Path('/tmp/viewflow-integrated-pair');out=[]
for label in sys.argv[1:]:
 mode='copy' if 'copy' in label else 'view';d=p/label;d.mkdir(exist_ok=True)
 texts={k:(raw/f'{k}-{label}.log').read_text() for k in ['source','receiver','desktop','runner','cleanup']}
 producer=(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_text()
 for k,t in [*texts.items(),('producer',producer)]:
  with gzip.open(d/(k+'.log.gz'),'wb') as z:z.write(t.encode())
 shutil.copy(raw/f'fixture-{label}.json',d/'fixture.json')
 stages=['pinned_to_vector','cache_compare']
 if mode=='copy':stages.insert(1,'cabi_to_rust')
 a=alpha.summarize(texts['source'],stages);t,c=timeline.export(texts['source'],texts['receiver'],texts['desktop'])
 ds=desktop.summarize(texts['desktop']);ds['render_to_desktop']=desktop.latency_bounds(texts['desktop'],texts['source'],producer,texts['receiver'])
 for name,value in [('alpha',a),('clock-and-stages',c),('desktop',ds)]:
  (d/(name+'.json')).write_text(json.dumps(value,indent=2)+'\n')
 row={'label':label,'mode':mode,'alpha_cpu_ms':a['same_frame_total_thread_cpu_ms'],'alpha_wall_ms':a['same_frame_total_wall_ms'],'encode_ms':c['wall_stage_ms']['encode (host incl waits)'],'captured_to_mutation_ms':ds['render_to_desktop']['unique_capture_stage_samples']['capture_to_mutation_upper_ms'],'capture_to_seen_desktop_ms':ds['render_to_desktop']['unique_capture_stage_samples']['capture_to_desktop_upper_ms'],'observed_marker_rate':ds['observed_changes_per_second'],'clock_uncertainty_ms':c['uncertainty_ms'],'rejections':a['rejected'],'source_mode':[l for l in texts['source'].splitlines() if l.startswith('alpha-output-storage ')]}
 out.append(row)
 print(label,'alphaCPU',round(row['alpha_cpu_ms']['median'],3),'encode',round(row['encode_ms']['median'],3),'cap->mutation',round(row['captured_to_mutation_ms']['median'],3),'cap->seen',round(row['capture_to_seen_desktop_ms']['median'],3),'markers',round(row['observed_marker_rate'],3))
(p/'comparison.json').write_text(json.dumps(out,indent=2)+'\n')
