from pathlib import Path
import sys,json,collections,bisect,re
sys.path.insert(0,str(Path(__file__).resolve().parent))
import profile_atlas_timeline as t
import summarize_desktop_markers as d
root=Path(sys.argv[1]);out=[]
for label in sys.argv[2:]:
 p=root/label;source=(p/'source.log').read_text();receiver=(p/'isolated-receiver-stderr.log').read_text();desktop=(p/'desktop-marker.log').read_text();fixture=(p/'fixture.log').read_text()
 assert 'exit=0' in desktop
 dimensions={int(m[1]):m[2] for m in re.finditer(r'fixture-render frame=(\d+).* pixels=(\d+x\d+)',fixture)}
 assert all(dimensions[int(r['frame'])]=='3840x2400' for r in t.rows(desktop,'desktop-marker '))
 obs=d.summarize(desktop);bounds=d.latency_bounds(desktop,source,fixture,receiver);trace,stages=t.export(source,receiver,desktop)
 assert obs['nonincreasing_frame_ids']==obs['nonincreasing_present_timestamps']==0
 assert not bounds['negative_upper_bound'] and not bounds['expired_clock_mapping']
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
 rb=t.numbers(t.rows(desktop,'readback-result ')[0]);assert rb['abandoned']==0
 state=json.loads((p/'state.json').read_text());assert not state['cleanup_errors'] and not state['after']['processes'] and not state['after']['port']
 row=dict(label=label,native_commit_hz=(len(commits)-1)*commits[0]['frequency']/(commits[-1]['qpc']-commits[0]['qpc']),desktop=obs,bounds=bounds,stages=stages,readback=rb,identity_pairs=pairs,monitor_lines=[r for r in desktop.splitlines() if r.startswith(('monitor ','output ','adapter ','owned_proxy','desktop_image'))],source_exit=state['source_exit'],runner=(p/'isolated-runner-status.log').read_text())
 (p/'analysis.json').write_text(json.dumps(row,indent=2)+'\n');(p/'timeline.json').write_text(json.dumps(trace)+'\n')
 out.append(row)
 print(label,'native_hz',row['native_commit_hz'],'desktop_hz',obs['observed_changes_per_second'],'pre_draw_to_seen_upper_ms',bounds['latency_upper_ms'],'capture_to_seen_upper_ms',bounds['unique_capture_stage_samples']['capture_to_desktop_upper_ms'],flush=True)
(root/'phase-comparison.json').write_text(json.dumps(out,indent=2)+'\n')
