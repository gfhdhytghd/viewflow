#!/usr/bin/env python3
"""Correlate diagnostic timestamps; never substitute atlas PTS for WGC capture."""
import argparse,json,re,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('start',type=Path);p.add_argument('end',type=Path);p.add_argument('host',type=Path);p.add_argument('guest',type=Path);a=p.parse_args()
cals=[json.loads(x.read_text()) for x in (a.start,a.end)]
lo=min(x['best']['offset_low_ns'] for x in cals);hi=max(x['best']['offset_high_ns'] for x in cals);mid=(lo+hi)/2
begin=min(x['best']['host_start_ns'] for x in cals);end=max(x['best']['host_end_ns'] for x in cals)
captures={};callback_audit=[]
for line in a.guest.read_text(errors="replace").splitlines():
 if line.startswith("profile_capture "):
  d={k:int(v) for k,v in re.findall(r"(\w+)=(-?\d+)",line)}
  if "callback_qpc" in d:callback_audit.append(d)
callback_times={(d["id"],d["capture"]):d["callback_qpc"] for d in callback_audit}
future=sum(d["capture"]>d["callback_qpc"] for d in callback_audit)
for line in a.guest.read_text(errors='replace').splitlines():
 m=re.search(r'profile_shared_capture pts=(\d+) id=(\d+) capture=(\d+) version=(\d+) enqueued=(\d+) width=(\d+) height=(\d+)',line)
 if m: captures[(int(m[1]),int(m[2]))]=tuple(int(m[i]) for i in (3,4,6,7))
groups={};seen=set();callback_seen=set();outside=0
for line in a.host.read_text(errors='replace').splitlines():
 m=re.search(r'ivshmem-clock-sample output=(\S+) id=(\d+) atlas_submit_qpc_100ns=(\d+) presented_monotonic_ns=(\d+) clock_id=(\d+)',line)
 if not m or m[5]!='1':continue
 output,id,pts,when=m[1],int(m[2]),int(m[3]),int(m[4])
 if not begin<=when<=end:outside+=1;continue
 g=groups.setdefault(output,{'atlas_to_present_ms':[],'new_capture_to_present_first_observed_ms':[],'callback_to_present_first_observed_ms':[],'atlas_dimensions':set(),'unmatched':0})
 g['atlas_to_present_ms'].append((when-pts*100-mid)/1e6)
 capture=captures.get((pts,id))
 if not capture:g['unmatched']+=1;continue
 stamp,version,width,height=capture;g['atlas_dimensions'].add((width,height))
 key=(output,id,stamp)
 if key not in seen and stamp*100+mid>=begin:g['new_capture_to_present_first_observed_ms'].append((when-stamp*100-mid)/1e6);seen.add(key)
 if key in seen and key not in callback_seen and (id,stamp) in callback_times:
  callback=callback_times[(id,stamp)];callback_seen.add(key)
  if callback*100+mid>=begin:g['callback_to_present_first_observed_ms'].append((when-callback*100-mid)/1e6)
def stats(values):
 if not values:return {'n':0}
 values.sort();return {'n':len(values),'p50':statistics.median(values),'p95':values[min(len(values)-1,int(len(values)*.95))],'min':values[0],'max':values[-1]}
for g in groups.values():
 for key in ('atlas_to_present_ms','new_capture_to_present_first_observed_ms','callback_to_present_first_observed_ms'):g[key]=stats(g[key])
 g['atlas_dimensions']=sorted(g['atlas_dimensions'])
print(json.dumps({'wgc_timestamp_audit':{'callback_records':len(callback_audit),'timestamp_later_than_callback':future,'strict_capture_latency_validated':False,'status':'contradicted_by_future_timestamps' if future else 'requires_timestamp_and_pixel_identity_validation'},'scope':'sampled Wayland feedback, not photon; periodic cached frames are not motion FPS; captures predating calibration are excluded from new-capture latency','clock_endpoint_envelope_half_width_ms':(hi-lo)/2e6,'clock_endpoint_offset_change_us':(cals[1]['offset_mid_ns']-cals[0]['offset_mid_ns'])/1e3,'clock_caveat':'endpoint envelope is observed calibration uncertainty; unobserved clock drift is not bounded','outside_calibration_interval':outside,'outputs':groups},indent=2))
