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
 if 'readback_mode=async' in desktop:
  assert all(b['sequence']>a['sequence'] for a,b in zip(frames,frames[1:]))
  rb=t.numbers(t.rows(desktop,'readback-result ')[0]);assert rb['abandoned']==0 and rb['pending_peak']<=3
 else:rb=None
 row=dict(label=label,native_commit_hz=(len(commits)-1)*commits[0]['frequency']/(commits[-1]['qpc']-commits[0]['qpc']),desktop=obs,bounds=bounds,clock_and_stages=stages,readback=rb,observer_result=t.numbers(t.rows(desktop,'observer-result ')[0]),cpu_map_us=t.stats([x['cpu_map_us'] for x in frames if 'cpu_map_us' in x]),matched_unique_markers=len(pairs),missing_capture_marker=missing,ambiguous_capture_marker=ambiguous,identity_pairs=pairs,monitor_lines=[x for x in desktop.splitlines() if x.startswith(('monitor ','output ','adapter ','owned_proxy','desktop_image'))])
 timer=t.numbers(t.rows(desktop,'observer-timer ')[0]);waits=[t.numbers(x) for x in t.rows(desktop,'observer-timer-wait ')]
 assert len(waits)==8 and all(x['result']==258 for x in waits)
 assert timer['requested']==timer['active']==1
 row['timer']=timer;row['one_ms_wait_us']=t.stats([x['elapsed_us'] for x in waits])
 row['nvenc_control_lines']=[x for x in texts['source'].splitlines() if x.startswith('GPU nvenc-split ')]
 row['decoder_lines']=[x for x in texts['receiver'].splitlines() if x.startswith('atlas-color-decoder ')]
 enc=[t.numbers(x) for x in t.rows(texts['source'],'GPU encode timing ') if int(x['frame'])>=30]
 wire=[t.numbers(x) for x in t.rows(texts['source'],'atlas-wire-timing ') if int(x['frame'])>=30]
 encoder_keys=['fence','import','copy_prepare','nv12_alpha_readback','nvenc','total'];wire_keys=['encoded_bytes','wire_bytes','packets','feedback_us']
 row['malformed_encoder_rows']=[x for x in enc if not all(k in x for k in encoder_keys)]
 row['malformed_wire_rows']=[x for x in wire if not all(k in x for k in wire_keys)]
 enc=[x for x in enc if all(k in x for k in encoder_keys)];wire=[x for x in wire if all(k in x for k in wire_keys)]
 row['encoder_host_us']={key:t.stats([x[key] for x in enc]) for key in encoder_keys}
 row['wire_per_frame']={key:t.stats([x[key] for x in wire]) for key in ['encoded_bytes','wire_bytes','packets','feedback_us']}
 row['codec']='av1' if '-av1-' in label else 'h264'
 if row['codec']=='av1':
  mode='4' if '-four-' in label else 'auto'
  assert row['nvenc_control_lines'] and all(('requested='+mode+' set_status=0 read_status=0 observed='+('4' if mode=='4' else '0')) in x for x in row['nvenc_control_lines'])
  assert row['decoder_lines'] and all('codec=av1 backend=ffmpeg-d3d11va hardware_required=true' in x for x in row['decoder_lines'])
 else:assert not row['nvenc_control_lines'] and not row['decoder_lines']
 row['diagnostic_mode']='minimal' if '-minimal-' in label else 'noquery' if '-noquery-' in label else 'full'
 row['gpu_query_controls']=t.rows(texts['receiver'],'atlas-gpu-queries ')
 row['gpu_timestamp_count']=len(t.rows(texts['receiver'],'atlas-gpu-timestamp '));row['gpu_completion_count']=len(t.rows(texts['receiver'],'atlas-gpu-copy-completion '))
 row['socket_anchor_counts']={key:len(t.rows(texts[key],'atlas-socket-anchor ')) for key in ['source','receiver']}
 row['log_bytes']={key:len(texts[key].encode()) for key in texts}
 assert row['gpu_query_controls'] and all(x['enabled']==('1' if row['diagnostic_mode']=='full' else '0') for x in row['gpu_query_controls'])
 if row['diagnostic_mode']=='full':assert row['gpu_timestamp_count'] and row['gpu_completion_count']
 else:assert row['gpu_timestamp_count']==row['gpu_completion_count']==0
 if row['diagnostic_mode']=='minimal':assert not enc and all(n==0 for n in row['socket_anchor_counts'].values()) and 'alpha-copy-profile ' not in texts['source']
 else:assert enc and all(n>0 for n in row['socket_anchor_counts'].values())
 row['capture_events']=True
 row['capture_mode']='commit' if '-event-' in label else 'grid'
 row['capture_wait_control']=t.rows(texts['source'],'atlas-capture-wait ')
 row['capture_retire']=t.rows(texts['source'],'atlas-source-retiring ')
 assert row['capture_wait_control'] and all(x['events_enabled']==('true' if row['capture_events'] else 'false') for x in row['capture_wait_control'])
 assert row['capture_retire']
 for x in row['capture_retire']:
  assert int(x['waiting'])==int(x['capture_wakes'])+int(x['periodic_wakes'])
  assert int(x['capture_wakes'])>0 if row['capture_events'] else int(x['capture_wakes'])==0
 source_stages=[t.numbers(x) for x in t.rows(texts['source'],'atlas-source-timing ') if int(x['frame'])>=30]
 row['capture_delivery_ms']={key:t.stats([x[key]/1000 for x in source_stages if key in x]) for key in ['socket_age_max_us','collector_to_encode_us','previous_feedback_wait_us','captured_before_previous_return_us']}
 result.append(row)
 print(label,'native',row['native_commit_hz'],'observed',obs['observed_changes_per_second'],'copy_map',obs['copy_map_us'],'CPUmap',row['cpu_map_us'],'cap->desktop',bounds['unique_capture_stage_samples']['capture_to_desktop_upper_ms'],'readback',rb)
Path('/tmp/viewflow-commit-cadence-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
