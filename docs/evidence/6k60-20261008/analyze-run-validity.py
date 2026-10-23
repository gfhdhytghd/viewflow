"""Report observed benchmark disruptions; absence of logs is not validity proof."""
import json,re,sys
from pathlib import Path
r=Path(__file__).resolve().parent;t=sys.argv[1]
host=(r/f'{t}-host.log').read_text();fixture=(r/f'{t}-generator.log').read_text();events=[];extents=[]
for line in host.splitlines():
 if 'ivshmem-residency ' in line:
  prefix,rest=line.split(' client=',1);client,monitors=rest.split(' monitors=',1)
  c=json.loads(client);m=json.loads(monitors);match=re.search(r'id=(\d+) demand=(\d+),(\d+),(\d+),(\d+)',prefix)
  if not match:continue
  events.append({'log_time':prefix.split(' SuperPower ')[0],'id':int(match[1]),'demand':[int(match[i]) for i in range(2,6)],'window_workspace':c.get('workspace'),'window_visible':c.get('visible'),'outputs':[{'name':x['name'],'workspace':x.get('activeWorkspace'),'dpms':x.get('dpmsStatus')} for x in m]})
 if 'ivshmem-accept ' in line:
  d={k:float(v) for k,v in re.findall(r'(\w+)=(-?[\d.]+)',line)}
  extents.append({'width':int(d['width']),'height':int(d['height']),'frames':int(d['frames']),'interval_ms':d['interval_ms']})
zero=[e for e in events if not e['demand'][2] or not e['demand'][3]]
small=[e for e in extents if (e['width'],e['height'])!=(6144,3456)]
foreground=re.search(r'motion-foreground-summary changes=(\d+)',fixture)
changed=bool(re.search(r'motion-fixture frames=.*foreground_unchanged=0',fixture)) or bool(foreground and int(foreground[1]))
guest=(r/f'{t}-guest.log').read_text()
trace_status=[int(n) for n in re.findall(r'profile_trace_(?:status|summary) [^\n]*dropped=(\d+)',guest)]
host_trace_status=[int(n) for n in re.findall(r'profile_trace_(?:status|summary) [^\n]*dropped=(\d+)',host)]
reasons=[]
if any(host_trace_status):reasons.append('observed_dropped_host_trace_records')
if any(trace_status):reasons.append('observed_dropped_trace_records')
if zero:reasons.append('observed_zero_residency_demand')
if small:reasons.append('observed_non_6k_accept_interval')
if changed:reasons.append('observed_foreground_change')
print(json.dumps({'scope':'Observed discontinuities only; aggregate intervals and residency logging do not prove uninterrupted60fps or photon latency. Multiple-window attribution may require manual review.','sustained_6k_evidence':'invalid_or_confounded' if reasons else 'not_disproved_but_not_certified','reasons':reasons,'trace_drops_last_observed':trace_status[-1] if trace_status else None,'host_trace_drops_max_observed':max(host_trace_status) if host_trace_status else None,'residency_events':events,'accept_intervals':extents,'foreground_change_count':int(foreground[1]) if foreground else None},indent=2))
