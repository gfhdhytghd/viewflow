#!/usr/bin/env python3
"""Analyze existing DMA evidence without contacting a VM or reading pixels."""
import argparse,pathlib,re,json,collections

def stat(v):
 v=sorted(v);return {'n':len(v),'p50':v[len(v)//2],'p95':v[int(len(v)*.95)],'max':v[-1]} if v else {'n':0}

def d11_groups(source):
 groups=collections.defaultdict(list)
 for line in source.splitlines():
  if not line.startswith('profile_d11_gpu_copy '):continue
  fields=dict(re.findall(r'(\w+)=([^ ]+)',line))
  if fields.get('valid')!='1' or 'gpu_ms' not in fields:continue
  groups[fields.get('scope','unknown-legacy-scope')].append(float(fields['gpu_ms']))
 return {scope:stat(values) for scope,values in sorted(groups.items())}

def presentation_intervals(host, begin_ns, end_ns):
 # Counters describe feedback arrivals, not presentation timestamps. Never clip
 # a partially overlapping interval or sum independent proxy frame rates.
 intervals=[]
 for line in host.splitlines():
  if 'ivshmem-presentation-counts ' not in line:continue
  fields=dict(re.findall(r'(\w+)=([^\s]+)',line))
  try:
   begin=int(fields['interval_begin_ns']);end=int(fields['interval_end_ns'])
   if fields.get('clock_id')!='1' or end<=begin:continue
   row={key:int(fields[key]) for key in ['requested','presented','discarded','invalid','untracked_commits','pending','unique_pts','duplicate_pts']}
  except (KeyError,ValueError):continue
  duration=(end-begin)/1e9
  row.update(proxy=fields.get('id'),output=fields.get('output'),begin_ns=begin,end_ns=end,seconds=duration,
             fully_inside_motion=begin>=begin_ns and end<=end_ns,
             feedback_arrival_fps=row['presented']/duration,
             unique_source_feedback_fps=row['unique_pts']/duration)
  intervals.append(row)
 return {'scope':'per-proxy feedback-arrival intervals; not photon timing, not exact motion-window FPS; no cross-proxy sum',
         'intervals':intervals,'complete_intervals_inside_motion':sum(x['fully_inside_motion'] for x in intervals)}

def analyze(p):
 # A completed fixture log can survive a later abort or cleanup failure. These
 # records take precedence over timestamps; never turn them into a baseline.
 for name in ['aborted.json','guest-aborted.json','cleanup-unconfirmed.json','drain-blocked.json','normal-stop-blocked.json']:
  if (p/name).exists():
   return {'run':str(p),'status':'aborted' if 'aborted' in name else 'unconfirmed','stable_baseline':False,'performance_valid':False,'window_precision':'not-evaluated','reason':name,'evidence':json.loads((p/name).read_text())}
 if (p/'task-result.json').exists():
  task=json.loads((p/'task-result.json').read_text())
  if task.get('status')=='aborted' or task.get('exit',0)!=0:
   return {'run':str(p),'status':'unsuccessful','stable_baseline':False,'performance_valid':False,'window_precision':'not-evaluated','reason':'task-result.json','evidence':task}
 s=(p/'source.log').read_text();h=(p/'host.log').read_text();f=(p/'fixture.log').read_text();boundaries=[re.search('motion-loop '+k+r' qpc=(\d+) frequency=(\d+)',f) for k in ['begin','end']];exact=all(boundaries);
 if not exact:raise ValueError('Exact motion-loop QPC/frequency absent; no exact analysis emitted (approximate analysis unavailable)')
 if boundaries[0][2]!=boundaries[1][2]:raise ValueError('Loop QPC frequency changed')
 frequency=int(boundaries[0][2]);lo,hi=[int(x[1])*10000000/frequency for x in boundaries];sec=(hi-lo)/1e7;cal=json.loads((p/'clock-start.json').read_text());end=json.loads((p/'clock-end.json').read_text());off=cal['offset_mid_ns']
 captures=[int(x) for x in re.findall(r'profile_capture id=\d+ capture=(\d+)',s)];mapping={int(x):int(y) for x,y in re.findall(r'profile_shared_capture pts=(\d+).*? capture=(\d+)',s)};pub=[int(x) for x in re.findall(r'profile_shared_ready pts=(\d+).*path=d12',s)]
 events=[(st,int(pts),int(ns)) for st,pts,ns in re.findall(r'ivshmem-host-frame stage=(\w+) pts=(\d+) monotonic_ns=(\d+)',h)];present=[(int(pts),int(ns)) for pts,ns,cid in re.findall(r'ivshmem-clock-sample .*?atlas_submit_qpc_100ns=(\d+) presented_monotonic_ns=(\d+) clock_id=(\d+)',h) if cid=='1'];gpu=[];pending=None
 for line in s.splitlines():
  if line.startswith('profile_d12_gpu_copy '):pending=dict(re.findall(r'(\w+)=([\d.]+)',line))
  if line.startswith('profile_d12_stages ') and pending:
   stage_sequence=re.search(r'sequence=(\d+)',line)
   pending['stage_verified']=bool(stage_sequence and stage_sequence[1]==pending.get('sequence'))
  if line.startswith('profile_shared_ready ') and pending:
   pts=int(re.search(r'pts=(\d+)',line)[1]);pending['pts']=pts;gpu.append(pending);pending=None
 def count(v):return {'count':len(v),'per_second':len(v)/sec}
 report={'run':str(p),'window_precision':'exact logged loop boundaries converted to QPC100ns','in_flight':json.loads((p/'parameters.json').read_text())['in_flight'],'loop':{'begin_qpc':lo,'end_qpc':hi,'seconds':sec,'generator_submit_fps':int(re.search(r'motion-fixture frames=(\d+)',f)[1])/sec,'original_qpc_frequency':frequency},'foreground_changes':int(re.search(r'foreground-summary changes=(\d+)',f)[1]),'wgc_raw_all_log_count':len(captures),'wgc_exact_loop_unique':count(set(c for c in captures if lo<=c<=hi)),'source_published_atlas_pts_in_loop':count([x for x in pub if lo<=x<=hi]),'host_accept_end_events_in_loop':count([ns for st,pts,ns in events if st=='accept_end' and lo*100+off<=ns<=hi*100+off]),'host_accept_scope':'accept_end CPU submission completion; not presentation','wayland_feedback_sample_count_in_loop':len([ns for pts,ns in present if lo*100+off<=ns<=hi*100+off]),'wayland_presented_fps':None,'wayland_scope':'feedback trace subsampled; full frame count unavailable','capture_to_wayland_ms_for_loop_captures':stat([(ns-off-mapping[pts]*100)/1e6 for pts,ns in present if pts in mapping and lo<=mapping[pts]<=hi]),'gpu_d12_ms_for_loop_atlas_pts':stat([float(x['gpu_ms']) for x in gpu if x.get('valid')=='1' and x.get('stage_verified') and lo<=x['pts']<=hi]),'gpu_d12_scope':'GPU copy timestamp duration excluding producer wait; linked to following completed PTS','gpu_d11_ms_all_log_including_gate':stat([float(x) for x in re.findall(r'profile_d11_gpu_copy .*?valid=1 .*?gpu_ms=([\d.]+)',s)]),'gpu_d11_scope':'ALL-ROLES aggregate, not bridge-only; all-session including gate; snapshot-local sequence lacks PTS join, not exact motion-window selection','gpu_d11_by_scope_ms_all_log_including_gate':d11_groups(s),'clock_uncertainty_ms':cal['uncertainty_ms'],'clock_offset_shift_ms':(end['offset_mid_ns']-off)/1e6,'cpu_fallback_counts':sorted(set(int(x) for x in re.findall(r'profile_d12 .*?fallbacks=(\d+)',s))),'cpu_frame_counts':sorted(set(int(x) for x in re.findall(r'profile_d12 .*?cpu_frames=(\d+)',s))),'atlas_extents':dict(collections.Counter(re.findall(r'reverse-atlas hardware=ivshmem-bgra width=(\d+) height=(\d+)',s)))}

 report['wayland_full_feedback_intervals']=presentation_intervals(h,lo*100+off,hi*100+off)

 # Fixed interior 20..40s interval for longer runs; full-loop metrics stay intact.
 report['interior_20s']={'status':'unavailable','reason':'actual loop shorter than 40 seconds'}
 if sec>=40:
  inner_lo=lo+20*10000000;inner_hi=lo+40*10000000
  report['interior_20s']={'status':'available','offset_seconds':[20,40],'duration_seconds':20,'scope':'predeclared interior interval, not startup or replacement for full-loop results','wgc_unique':len(set(c for c in captures if inner_lo<=c<inner_hi)),'source_published':sum(inner_lo<=x<inner_hi for x in pub),'host_accept_end':sum(st=='accept_end' and inner_lo*100+off<=ns<inner_hi*100+off for st,pts,ns in events),'presented_fps':None,'generator_fps':None,'generator_scope':'no per-frame generation timestamps; cannot infer interval generator count','capture_to_wayland_ms':stat([(ns-off-mapping[pts]*100)/1e6 for pts,ns in present if pts in mapping and inner_lo<=mapping[pts]<inner_hi])}
  for key in ['wgc_unique','source_published','host_accept_end']:report['interior_20s'][key+'_per_second']=report['interior_20s'][key]/20
 report['atlas_extents']={str(k):v for k,v in report['atlas_extents'].items()}
 inputs=[int(x) for x in re.findall(r'motion-input-clock .*?ok=1 .*?last_input_ms=(\d+)',f)]
 report['last_input']={'values_ms':inputs,'changed':len(set(inputs))>1 if inputs else None,'scope':'session last input, not evidence of injected input'}
 report['extent_changed']=len(report['atlas_extents'])>1
 report['stable_focus']=report['foreground_changes']==0
 report['stable_baseline']=report['stable_focus'] and not report['extent_changed'] and bool(inputs) and len(set(inputs))==1
 report['restore']={}
 for name in ['task-result.json','restore.json','host-recovery.json']:
  if (p/name).exists():report['restore'][name]=json.loads((p/name).read_text())
 drops=[line for line in s.splitlines() if re.search(r'profile_\w*drop\b',line)]
 report['droptrace']={'records':len(drops),'reasons':dict(collections.Counter(re.findall(r'reason=([^ ]+)','\n'.join(drops)))),'scope':'all-session logged drops only; absence does not establish no drops'}
 report['wgc_future_of_callback_ms']=stat([(int(c)-int(cb))/1e4 for c,cb in re.findall(r'profile_capture id=\d+ capture=(\d+).*?callback_qpc=(\d+)',s) if int(c)>int(cb)])
 report['timestamp_scope']='WGC system-relative timestamps are not generation timestamps; future-of-callback samples retained without reinterpretation'
 report['d12_association_warning']='Adjacent GPU query/stage/completed lines are diagnostic association, not explicit PTS carried by query; inspect interleaved/multilane logs'
 return report

def main():
 parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--run',type=pathlib.Path,required=True);args=parser.parse_args()
 try:result=analyze(args.run)
 except (ValueError,OSError) as error:result={'status':'unavailable','performance_valid':False,'stable_baseline':False,'window_precision':'not-exact','reason':str(error)}
 (args.run/'analysis-v2.json').write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({'output':str(args.run/'analysis-v2.json'),'window_precision':result.get('window_precision')}))

if __name__=='__main__':main()
