from pathlib import Path
import sys,json,collections,bisect
sys.path.insert(0,'tools')
import profile_atlas_timeline as t
import summarize_desktop_markers as d
raw=Path('/tmp/viewflow-integrated-pair');result=[]
for label in sys.argv[1:]:
 texts={n:(raw/f'{n}-{label}.log').read_text() for n in ['source','receiver','desktop']}
 desktop=texts['desktop'];assert 'exit=0' in desktop
 producer=(Path('/tmp/viewflow-frame-fixture-first')/(label+'-source.log')).read_text()
 obs=d.summarize(desktop);bounds=d.latency_bounds(desktop,texts['source'],producer,texts['receiver']);_,stages=t.export(texts['source'],texts['receiver'],desktop)
 frames=[t.numbers(r) for r in t.rows(desktop,'desktop-marker ')]
 commits=[t.numbers(r) for r in t.rows(texts['receiver'],'atlas-native-timing ') if r['phase']=='committed' and int(r['frame'])>=30]
 markers=collections.defaultdict(list)
 for r in t.rows(texts['source'],'GPU fixture-marker '):
  if r['valid']=='1':markers[int(r['marker_frame'])].append(t.numbers(r))
 native={int(r['frame']):t.numbers(r) for r in t.rows(texts['receiver'],'atlas-native-timing ') if r['phase']=='committed'}
 clocks=sorted([t.numbers(r) for r in t.rows(texts['source'],'atlas-clock-mapping ')],key=lambda r:r['source_ns']);clock_times=[x['source_ns'] for x in clocks]
 anchor=t.numbers(t.rows(texts['receiver'],'atlas-receiver-clock-anchor ')[0])
 pairs=[];missing=0;ambiguous=0
 for frame in frames:
  candidates=markers[frame['frame']]
  if len(candidates)!=1:
   missing+=not candidates;ambiguous+=len(candidates)>1;continue
  c=candidates[0];n=native.get(c['atlas_frame'])
  if n and frame['present_qpc']:
   ci=bisect.bisect_right(clock_times,c['captured_ns'])-1;assert ci>=0
   clock=clocks[ci];valid_until=clock['source_ns']+clock['valid_remaining_ns']
   present_source_upper=anchor['after_ns']+(frame['present_qpc']-anchor['qpc'])*1e9/anchor['frequency']-clock['remote_offset_ns']+clock['uncertainty_ns']
   assert present_source_upper<=valid_until,'calibration expired before desktop observation'
   pairs.append(dict(source_clock_mapping_valid_until_ns=valid_until,present_source_upper_ns=present_source_upper,marker=frame['frame'],atlas_frame=c['atlas_frame'],sequence=frame.get('sequence'),commit_qpc=n['qpc'],present_qpc=frame['present_qpc'],commit_to_seen_ms=(frame['present_qpc']-n['qpc'])*1000/n['frequency']))
 assert obs['nonincreasing_frame_ids']==0 and obs['nonincreasing_present_timestamps']==0
 assert all(x['commit_to_seen_ms']>=0 for x in pairs)
 assert bounds['negative_upper_bound']==0 and bounds['unique_capture_stage_samples']['negative_mutation_to_desktop']==0
 if '-async-' in label:
  assert all(b['sequence']>a['sequence'] for a,b in zip(frames,frames[1:]))
  rb=t.numbers(t.rows(desktop,'readback-result ')[0]);assert rb['abandoned']==0 and rb['pending_peak']<=3
 else:rb=None
 row=dict(label=label,native_commit_hz=(len(commits)-1)*commits[0]['frequency']/(commits[-1]['qpc']-commits[0]['qpc']),desktop=obs,bounds=bounds,clock_and_stages=stages,readback=rb,observer_result=t.numbers(t.rows(desktop,'observer-result ')[0]),cpu_map_us=t.stats([x['cpu_map_us'] for x in frames if 'cpu_map_us' in x]),matched_unique_markers=len(pairs),missing_capture_marker=missing,ambiguous_capture_marker=ambiguous,identity_pairs=pairs,monitor_lines=[x for x in desktop.splitlines() if x.startswith(('monitor ','output ','adapter ','owned_proxy','desktop_image'))])
 result.append(row)
 print(label,'native',row['native_commit_hz'],'observed',obs['observed_changes_per_second'],'copy_map',obs['copy_map_us'],'CPUmap',row['cpu_map_us'],'cap->desktop',bounds['unique_capture_stage_samples']['capture_to_desktop_upper_ms'],'readback',rb)
Path('/tmp/viewflow-observer-control-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
