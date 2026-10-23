from pathlib import Path
import sys,json,collections,bisect,re
sys.path.insert(0,str(Path(__file__).resolve().parent))
import profile_atlas_timeline as t
import summarize_desktop_markers as d
root=Path(sys.argv[1]);out=[]
for label in sys.argv[2:]:
 p=root/label;source=(p/'source.log').read_text();receiver=(p/'isolated-receiver-stderr.log').read_text();desktop=(p/'desktop-marker.log').read_text();fixture=(p/'fixture.log').read_text()
 assert 'exit=0' in desktop
 output_rects={tuple(map(int,m.split(','))) for m in re.findall(r'^output rect=([^ ]+)',desktop,re.M)}
 assert len(output_rects)==1, 'display geometry changed during observation'
 assert all(r[2]-r[0]==3840 and r[3]-r[1]==2400 for r in output_rects), 'not an exact 4K output'
 assert 'monitor_selection exact4k=1 matches=1' in desktop
 if True:
  rect=next(iter(output_rects));
  for r in t.rows(receiver,'background-cache '):
   assert int(r['width'])<=rect[2]-rect[0] and int(r['height'])<=rect[3]-rect[1], 'cache exceeds observed display'
 dimensions={int(m[1]):m[2] for m in re.finditer(r'fixture-render frame=(\d+).* pixels=(\d+x\d+)',fixture)}
 assert all(dimensions[int(r['frame'])]=='3840x2400' for r in t.rows(desktop,'desktop-marker '))
 obs=d.summarize(desktop);requested_seconds=int(t.rows(desktop,'observer ')[0]['duration_ms'])/1000
 obs['requested_seconds']=requested_seconds
 obs['marker_span_fraction']=obs['elapsed_seconds']/requested_seconds
 obs['changes_per_requested_second']=obs['observed_changes']/requested_seconds
 obs['short_marker_span']=obs['marker_span_fraction']<0.9
 bounds=d.latency_bounds(desktop,source,fixture,receiver);trace,stages=t.export(source,receiver,desktop)
 assert not stages['invalid_exchanges'] and stages['mapping_count']>0
 assert obs['nonincreasing_frame_ids']==obs['nonincreasing_present_timestamps']==0
 assert not bounds['negative_upper_bound'] and not bounds['expired_clock_mapping']
 assert not bounds['missing_fixture_frame'] and not bounds['missing_preceding_clock']
 clocks=[t.numbers(r) for r in t.rows(source,'atlas-clock-mapping ')];clocks.sort(key=lambda r:r['source_ns']);times=[r['source_ns'] for r in clocks];anchor=t.numbers(t.rows(receiver,'atlas-receiver-clock-anchor ')[0])
 markers=collections.defaultdict(list)
 for r in t.rows(source,'GPU fixture-marker '):
  if r['valid']=='1':markers[int(r['marker_frame'])].append(t.numbers(r))
 native={int(r['frame']):t.numbers(r) for r in t.rows(receiver,'atlas-native-timing ') if r['phase']=='committed'}
 pairs=[]
 for r in t.rows(desktop,'desktop-marker '):
  f=t.numbers(r);c=markers[f['frame']]
  if len(c)!=1 or not f['present_qpc']:continue
  c=c[0];n=native.get(c['atlas_frame'])
  if n is None:continue
  i=bisect.bisect_right(times,c['captured_ns'])-1;assert i>=0;clock=clocks[i]
  end=anchor['after_ns']+(f['present_qpc']-anchor['qpc'])*1e9/anchor['frequency']-clock['remote_offset_ns']+clock['uncertainty_ns']
  assert end<=clock['source_ns']+clock['valid_remaining_ns']
  dt=(f['present_qpc']-n['qpc'])*1000/n['frequency'];assert dt>=0
  pairs.append(dict(marker_frame=f['frame'],atlas_frame=c['atlas_frame'],commit_qpc=n['qpc'],present_qpc=f['present_qpc'],commit_to_seen_ms=dt))
 commits=[n for f,n in native.items() if f>=30]
 rb=t.numbers(t.rows(desktop,'readback-result ')[0]);assert rb['abandoned']==0 and rb['pending_peak']<=3
 result=t.numbers(t.rows(desktop,'observer-result ')[0]);assert result['invalid']==0
 state=json.loads((p/'state.json').read_text());assert not state['cleanup_errors'] and not state['after']['processes'] and not state['after']['port']
 hosts=[t.numbers(r) for r in t.rows(receiver,'atlas-native-host-us ')]
 assert hosts, 'missing host/pool diagnostics'
 mode=int(state['async_dwm_flush'])
 assert mode in [0,1]
 assert 'atlas-backdrop sigma=12 mode=host-blur' in receiver
 assert 'atlas-diagnostic-window mouse_passthrough=1 no_activate=1' in receiver
 assert 'passive_proxy styles_verified=1 hit_queries=5 owned_hits=0 input_injected=0' in desktop
 assert 'fixture-input-policy passive=1' in fixture
 assert not t.rows(receiver,'native-background-cache ')
 summary=[t.numbers(r) for r in t.rows(receiver,'atlas-dwm-flush-summary ')]
 assert len(summary)<=1
 flushes=[t.numbers(r) for r in t.rows(receiver,'atlas-dwm-flush ')]
 count=summary[0] if summary else None
 if count:
  assert count['enabled']==mode and count['completed']==len(flushes)
  assert count['requested']==count['completed']+count['coalesced']+count['abandoned']
 if mode:assert len(flushes)>100
 else:assert not flushes and (count is None or not count['requested'])
 frequency=commits[0]['frequency']
 for f in flushes:
  assert f['hr']==0 and f['committed']<=f['begin']<=f['end']
  # Commit's receipt clock is sampled immediately before the trace clock.
  assert f['frame'] in native and f['committed']<=native[f['frame']]['qpc']<=f['begin']
 flush_stats={name:t.stats([(f[end]-f[begin])*1000/frequency for f in flushes]) for name,begin,end in [('commit_to_api_start_ms','committed','begin'),('api_wait_ms','begin','end'),('commit_to_api_return_ms','committed','end')]}
 flush_by_frame={f['frame']:f for f in flushes}
 flush_stats['api_return_to_seen_ms']=t.stats([(pair['present_qpc']-flush_by_frame[pair['atlas_frame']]['end'])*1000/frequency for pair in pairs if pair['atlas_frame'] in flush_by_frame])
 flush_stats['not_a_frame_present_receipt']=True

 valid=[h for h in hosts if h['frame']>=30 and h['completed']]
 host_stats={k:t.stats([h[k]/1000 for h in valid]) for k in ['resources','alpha','sample','input','output','shader','total']}
 runner=(p/'isolated-runner-status.log').read_text()
 if 'receiver_exit=' in runner:
  assert 'receiver_exit=1 watchdog=0' in runner
  termination='receiver exited after planned source timeout; runner watchdog unused'
 else:
  assert state['after_stream']['processes'], 'missing termination counter without recorded live receiver'
  termination='receiver still live after source timeout; private task/job stopped by controller cleanup; no exit counter'
 assert state['source_exit']==124
 row=dict(receiver_termination=termination,async_dwm_flush=mode,flush_summary=count,exit_counters_available=bool(summary),flush_stats=flush_stats,host_ms=host_stats,label=label,native_commit_hz=(len(commits)-1)*commits[0]['frequency']/(commits[-1]['qpc']-commits[0]['qpc']),desktop=obs,bounds=bounds,stages=stages,readback=rb,identity_pairs=pairs,monitor_lines=[r for r in desktop.splitlines() if r.startswith(('monitor ','output ','adapter ','owned_proxy','desktop_image','passive_proxy'))],source_exit=state['source_exit'],runner=(p/'isolated-runner-status.log').read_text())
 (p/'analysis.json').write_text(json.dumps(row,indent=2)+'\n');(p/'timeline.json').write_text(json.dumps(trace)+'\n')
 out.append(row)
 print(label,'native_hz',row['native_commit_hz'],'desktop_hz',obs['observed_changes_per_second'],'pre_draw_to_seen_upper_ms',bounds['latency_upper_ms'],'capture_to_seen_upper_ms',bounds['unique_capture_stage_samples']['capture_to_desktop_upper_ms'],flush=True)
(root/'passive-dwm-flush-comparison.json').write_text(json.dumps(out,indent=2)+'\n')
