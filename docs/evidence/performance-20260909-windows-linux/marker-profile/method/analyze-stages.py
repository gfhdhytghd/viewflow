"""Join decoded fixture IDs to native PTS; never infer a PTS for duplicate IDs."""
from pathlib import Path
import json, re, math, statistics, collections, sys
b=Path(__file__).resolve().parents[2]
p=b/'transport/runs'/(sys.argv[1] if len(sys.argv)>1 else 'marker-profile-a1')
def rows(file,prefix):
    return [{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in (p/file).read_text(errors='replace').splitlines() if line.startswith(prefix+' ')]
def keyed(file,prefix,key='pts'):
    r=rows(file,prefix);d={x[key]:x for x in r};assert len(r)==len(d),(prefix,len(r),len(d));return d
def stats(v):
    v=sorted(v);assert v
    return dict(n=len(v),min=v[0],median=statistics.median(v),p95=v[math.ceil(len(v)*.95)-1],p99=v[math.ceil(len(v)*.99)-1],max=v[-1])
images=rows('native-profile.log','profile_image')
present=keyed('native-profile.log','profile_present')
assert [x['pts'] for x in images]==list(present), 'Input/output PTS alignment must hold for these per-accept stage logs'
received=keyed('native-profile.log','profile_received')
submits=keyed('source.log','profile_submit')
colors=keyed('source.log','profile_color_ready')
outputs=keyed('source.log','profile_output')
fixtures=keyed('fixture.log','fixture_frame','id')
captures=keyed('source.log','profile_capture','capture')
by_marker=collections.defaultdict(list)
for x in images:by_marker[x['marker']].append(x)
clocks=rows('linux.log','reverse_clock')
for c in clocks:c.update(mid=(c['t1']+c['t4'])//2,low=c['t3']-c['t4'],high=c['t2']-c['t1'])
matched=json.loads((p/'matched.json').read_text());start=matched[0]['mono']+3_000_000_000
out=[];exclusions=collections.Counter()
for observed in matched:
    if observed['mono']<start:continue
    candidates=by_marker[observed['marker']]
    if len(candidates)!=1:exclusions['ambiguous_marker' if candidates else 'marker_not_decoded']+=1;continue
    im=candidates[0];pts=im['pts']
    if any(pts not in d for d in [present,received,submits,colors,outputs]):exclusions['missing_stage']+=1;continue
    pr=present[pts];rx=received[pts]['at'];s=submits[pts];co=colors[pts];o=outputs[pts];f=fixtures[observed['marker']]
    near=[c for c in clocks if abs(c['mid']-rx)<=500_000_000];assert len(near)>=3
    low=min(c['low'] for c in near);high=max(c['high'] for c in near)
    cap=captures[s['capture']]
    stage=dict(
        fixture_pre_draw_to_wgc_copy_queued_ms=(cap['copied']-f['begin'])/10000,
        wgc_copy_queued_to_source_submit_ms=(s['submit_begin']-cap['copied'])/10000,
        fixture_pre_draw_to_source_submit_ms=(s['submit_begin']-f['begin'])/10000,
        source_submit_call_ms=(s['submit_end']-s['submit_begin'])/10000,
        source_submit_to_color_ready_ms=(co['at']-s['submit_begin'])/10000,
        source_color_ready_to_pipe_write_ms=(o['write_end']-co['at'])/10000,
        pipe_write_to_native_receive_low_ms=(rx-o['write_end']*100+low)/1e6,
        pipe_write_to_native_receive_high_ms=(rx-o['write_end']*100+high)/1e6,
        native_receive_to_accept_ms=(pr['begin']-rx)/1e6,
        native_accept_to_decode_submit_ms=(pr['submit']-pr['begin'])/1e6,
        native_decode_call_ms=(pr['decoded']-pr['submit'])/1e6,
        marker_read_ms=(im['end']-im['begin'])/1e6,
        native_gpu_upload_call_ms=(pr['uploaded']-pr['upload_begin'])/1e6,
        native_alpha_ms=(pr['alpha']-pr['uploaded'])/1e6,
        native_draw_and_swap_ms=(pr['swapped']-pr['alpha'])/1e6,
        native_swap_to_desktop_observed_ms=(observed['mono']-pr['swapped'])/1e6,
        full_route_upper_ms=observed['latency_high_ms'])
    out.append(dict(marker=observed['marker'],pts=pts,stage=stage))
assert len(out)>100
summary=dict(scope='Diagnostic stage pairing for unambiguous decoded markers; original full-route criterion unchanged',
    decoded_images=len(images),unique_decoded_markers=len(by_marker),duplicate_marker_ids=sum(len(v)>1 for v in by_marker.values()),
    observed_steady=len(out)+sum(exclusions.values()),paired=len(out),excluded=dict(exclusions),
    stages={k:stats([x['stage'][k] for x in out]) for k in out[0]['stage']},
    marker_read_all_ms=stats([(x['end']-x['begin'])/1e6 for x in images]),
    limitations=['Marker read adds two synchronous CUDA device-to-host row copies totaling 6 KiB per decoded image. Its CPU duration is reported separately; instrumentation can affect GPU scheduling.',
                'Stage quantiles are not additive. Decode/upload/draw timestamps measure CPU call boundaries, not isolated GPU execution.',
                'Cross-host stages use the observed clock interval envelope within +/-0.5 seconds. Desktop observation excludes physical scanout.',
                'Only markers decoded exactly once are paired to observed images; repeated marker IDs have no uniquely established PTS.'])
(p/'marker-stage-pairs.json').write_text(json.dumps(out,indent=2)+'\n')
(p/'marker-stage-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
