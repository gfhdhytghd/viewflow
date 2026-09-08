from pathlib import Path
import sys,json,collections,bisect
sys.path.insert(0,'tools');import profile_atlas_timeline as t
raw=Path('/tmp/viewflow-integrated-pair');out=[]
for label in sys.argv[1:]:
 s=(raw/f'source-{label}.log').read_text();r=(raw/f'receiver-{label}.log').read_text();w=(raw/f'window-{label}.log').read_text()
 assert 'exit=0' in w
 header=t.numbers(t.rows(w,'window-observer ')[0]);f=header['qpc_frequency'];rows=[t.numbers(x) for x in t.rows(w,'window-marker ')];summary=t.numbers(t.rows(w,'window-observer-result ')[0]);assert summary['abandoned']==0
 anchors=[t.numbers(x) for x in t.rows(r,'atlas-receiver-clock-anchor ')];assert len(anchors)==1 and anchors[0]['frequency']==f;anchor=anchors[0]
 _,stages=t.export(s,r,'')
 caps=collections.defaultdict(list)
 for x in t.rows(s,'GPU fixture-marker '):
  if x['valid']=='1':caps[int(x['marker_frame'])].append(t.numbers(x))
 commits={int(x['frame']):t.numbers(x) for x in t.rows(r,'atlas-native-timing ') if x['phase']=='committed'}
 clocks=sorted([t.numbers(x) for x in t.rows(s,'atlas-clock-mapping ')],key=lambda x:x['source_ns']);times=[x['source_ns'] for x in clocks]
 pairs=[];missing=0;ambiguous=0
 for x in rows:
  assert x['render_qpc']==x['render_100ns']*f//10000000
  cs=caps[x['frame']]
  if len(cs)!=1:missing+=not cs;ambiguous+=len(cs)>1;continue
  c=cs[0];n=commits.get(c['atlas_frame'])
  if n is None:missing+=1;continue
  i=bisect.bisect_right(times,c['captured_ns'])-1;assert i>=0;clock=clocks[i]
  render_receiver=anchor['before_ns']+(x['render_qpc']-anchor['qpc'])*1e9/f
  render_source_upper=render_receiver+(anchor['after_ns']-anchor['before_ns'])-clock['remote_offset_ns']+clock['uncertainty_ns'];assert render_source_upper<=clock['source_ns']+clock['valid_remaining_ns']
  capture_lower=(render_receiver-clock['remote_offset_ns']-clock['uncertainty_ns']-c['captured_ns'])/1e6
  capture_upper=(render_source_upper-c['captured_ns'])/1e6
  pairs.append(dict(marker=x['frame'],atlas_frame=c['atlas_frame'],render_qpc=x['render_qpc'],commit_qpc=n['qpc'],acquired_qpc=x['acquired_qpc'],sequence=x['sequence'],capture_to_render_lower_ms=capture_lower,capture_to_render_upper_ms=capture_upper,commit_to_render_ms=(x['render_qpc']-n['qpc'])*1000/f,render_to_acquire_ms=(x['acquired_qpc']-x['render_qpc'])*1000/f))
 native=[n for n in commits.values() if n['frame']>=30];native.sort(key=lambda x:x['qpc'])
 result=dict(label=label,endpoint='WGC SystemRelativeTime; separate from desktop LastPresentTime',native_commit_hz=(len(native)-1)*f/(native[-1]['qpc']-native[0]['qpc']),observed_window_changes_hz=(len(rows)-1)*f/(rows[-1]['render_qpc']-rows[0]['render_qpc']),summary=summary,missing=missing,ambiguous=ambiguous,nonincreasing_frame_ids=sum(b['frame']<=a['frame'] for a,b in zip(rows,rows[1:])),nonincreasing_render_timestamps=sum(b['render_qpc']<=a['render_qpc'] for a,b in zip(rows,rows[1:])),future_render_at_acquire=sum(x['render_qpc']>x['acquired_qpc'] for x in rows),negative_capture_to_render_upper=sum(x['capture_to_render_upper_ms']<0 for x in pairs),negative_commit_to_render=sum(x['commit_to_render_ms']<0 for x in pairs),capture_to_render_upper_ms=t.stats([x['capture_to_render_upper_ms'] for x in pairs]),commit_to_render_ms=t.stats([x['commit_to_render_ms'] for x in pairs]),render_to_acquire_ms=t.stats([(x['acquired_qpc']-x['render_qpc'])*1000/f for x in rows]),clock_and_stages=stages,pairs=pairs)
 result['timer_wait_us']=t.stats([t.numbers(x)['elapsed_us'] for x in t.rows(w,'observer-timer-wait ')])
 result['readback_us']=t.stats([x['readback_us'] for x in rows])
 result['timer']=[t.numbers(x) for x in t.rows(w,'observer-timer ')]
 out.append(result);print(json.dumps({k:v for k,v in result.items() if k not in ['pairs','clock_and_stages']},indent=2))
Path('/tmp/viewflow-window-observer-analysis.json').write_text(json.dumps(out,indent=2)+'\n')
