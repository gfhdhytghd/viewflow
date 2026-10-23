#!/usr/bin/env python3
"""Audit raw clock exchanges and export measured frame spans to Chrome Trace JSON.

Spans are wall time (including waits), not sampled CPU stacks or GPU execution.
Cross-host timestamps use the last preceding valid calibration; its uncertainty
is retained per frame. Native intervals stay on QPC, independent of calibration.
"""
import argparse
import bisect
import collections
import json
import re
import statistics
from pathlib import Path


def rows(text, prefix):
    return [dict(re.findall(r'(\w+)=([^\s]+)', line)) for line in text.splitlines() if line.startswith(prefix)]


def numbers(row):
    return {k: int(v) for k, v in row.items() if re.fullmatch(r'-?\d+', v)}


def stats(values):
    if not values:
        return {'n': 0}
    v = sorted(values)
    return {'n': len(v), 'min': v[0], 'median': statistics.median(v), 'p95': v[min(len(v)-1, int(len(v)*.95))], 'max': v[-1]}


def export(source, receiver, desktop):
    exchanges = [numbers(r) for r in rows(source, 'atlas-clock-exchange ')]
    invalid = []
    for i, r in enumerate(exchanges):
        rtt = r['t3']-r['t0']-(r['t2']-r['t1'])
        twice_offset = r['t1']-r['t0']+r['t2']-r['t3']
        offset = (1 if twice_offset >= 0 else -1)*(abs(twice_offset)//2)
        if rtt < 0 or r['t0'] > r['t3'] or r['t1'] > r['t2'] or offset != r['remote_offset_ns'] or (rtt+1)//2 != r['uncertainty_ns']:
            invalid.append(i)
    clocks = sorted([numbers(r) for r in rows(source, 'atlas-clock-mapping ')], key=lambda r:r['source_ns'])
    assert clocks and not invalid, 'missing or invalid clock evidence'
    anchors = [numbers(r) for r in rows(receiver, 'atlas-receiver-clock-anchor ')]
    assert len(anchors) == 1
    anchor = anchors[0]; freq = anchor['frequency']
    assert anchor['before_ns'] <= anchor['after_ns'] and freq > 0
    times = [r['source_ns'] for r in clocks]
    origin = clocks[0]['source_ns'] + clocks[0]['remote_offset_ns']
    events = []; durations = collections.defaultdict(list); skipped = collections.Counter(); encoded = {}
    captures = collections.defaultdict(list)
    for r in rows(source, 'GPU fixture-marker '):
        if r.get('valid') == '1':
            captures[int(r['atlas_frame'])].append(int(r['captured_ns']))
    exact_capture = {f:v[0] for f,v in captures.items() if len(v)==1}
    source_counts = collections.Counter(int(r['frame']) for r in rows(source, 'atlas-source-timing '))
    def qpc(q):
        return (q-anchor['qpc'])*1e9/freq + (anchor['before_ns']+anchor['after_ns'])/2
    def span(name, start, end, frame, pid, tid, error=0):
        if end < start:
            skipped['negative_'+name] += 1; return
        durations[name].append((end-start)/1e6)
        events.append(dict(name=name, cat='measured wall time', ph='X', pid=pid, tid=tid, ts=(start-origin)/1000, dur=(end-start)/1000, args=dict(frame=frame, clock_uncertainty_ns=error)))
    for row in rows(source, 'atlas-source-timing '):
        r=numbers(row); frame=r['frame']
        if source_counts[frame] != 1 or len(captures.get(frame, [])) > 1:
            skipped['duplicate_source_identity'] += 1; continue
        capture=exact_capture.get(frame, r['encode_start_ns']-r['capture_to_encode_start_us']*1000)
        i=bisect.bisect_right(times,capture)-1
        if i < 0: skipped['missing_clock']+=1; continue
        c=clocks[i]
        if r['batch_return_ns'] > c['source_ns']+c['valid_remaining_ns']:
            skipped['expired_clock']+=1; continue
        offset=c['remote_offset_ns']
        encoded[frame] = (r['encoded_ns']+offset, c['uncertainty_ns'])
        for name,a,b,tid in [('capture to encode',capture,r['encode_start_ns'],1),('encode (host incl waits)',r['encode_start_ns'],r['encoded_ns'],2),('release',r['encoded_ns'],r['released_ns'],2),('batch return / previous feedback',r['released_ns'],r['batch_return_ns'],3)]:
            span(name,a+offset,b+offset,frame,1,tid,c['uncertainty_ns'])
    native=collections.defaultdict(dict)
    native_counts=collections.Counter()
    for r in rows(receiver,'atlas-native-timing '):
        if 'qpc' in r:
            assert int(r['frequency']) == freq
            key=(int(r['frame']),r['phase']); native_counts[key]+=1
            native[key[0]][key[1]]=qpc(int(r['qpc']))
    for (frame,phase),count in native_counts.items():
        if count != 1:
            del native[frame][phase]; skipped['duplicate_native_phase']+=1
    phases=[('pipe-admission','decoded','pipe admission to decoded'),('decoded','proxy-ready','decoded to proxy ready'),('proxy-ready','copy-ready','surface copy host'),('copy-ready','committed','visual bind / commit host')]
    for frame,r in native.items():
        if frame in encoded and 'pipe-admission' in r:
            start,error=encoded[frame]
            span('encoded to pipe admission (transport + receiver + pipe parse)',start,r['pipe-admission'],frame,2,3,error)
        for a,b,name in phases:
            if a in r and b in r: span(name,r[a],r[b],frame,2,1)
    markers=collections.defaultdict(list)
    for r in rows(source,'GPU fixture-marker '):
        r=numbers(r)
        if r.get('valid'): markers[r['marker_frame']].append(r)
    for r in rows(desktop,'desktop-marker '):
        r=numbers(r); matches=markers[r['frame']]
        if len(matches)!=1: skipped['nonunique_marker']+=1; continue
        frame=matches[0]['atlas_frame']; n=native.get(frame,{})
        if 'committed' in n and r['present_qpc']>0:
            span('commit to desktop (queue + GPU + DWM; NOT DWM CPU)', n['committed'], qpc(r['present_qpc']), frame,2,2)
    offsets=[r['remote_offset_ns'] for r in clocks]
    # Linear fit is diagnostic only: network asymmetry can move offset estimates.
    x=[(r['source_ns']-times[0])/1e9 for r in clocks]; y=[v-offsets[0] for v in offsets]
    xm=statistics.mean(x); ym=statistics.mean(y); den=sum((v-xm)**2 for v in x)
    slope=sum((a-xm)*(b-ym) for a,b in zip(x,y))/den if den else 0
    report=dict(raw_exchange_count=len(exchanges), invalid_exchanges=invalid,
        mapping_count=len(clocks), uncertainty_ms=stats([r['uncertainty_ns']/1e6 for r in clocks]),
        network_rtt_ms=stats([r['network_round_trip_ns']/1e6 for r in exchanges]),
        offset_span_ms=(max(offsets)-min(offsets))/1e6, apparent_offset_slope_ppm=slope/1000,
        slope_is_not_independent_oscillator_drift=True, anchor_width_ns=anchor['after_ns']-anchor['before_ns'],
        skipped=dict(skipped), wall_stage_ms={k:stats(v) for k,v in durations.items()},
        caveat='Overlapping pipelines; do not sum independent medians. CPU flame graph and wall spans are distinct. Desktop timestamp is not photon time.')
    return dict(traceEvents=events,displayTimeUnit='ms'),report

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for n in ('source','receiver','desktop','output'):p.add_argument('--'+n,type=Path,required=True)
    a=p.parse_args(); trace,report=export(a.source.read_text(),a.receiver.read_text(),a.desktop.read_text())
    a.output.mkdir(parents=True,exist_ok=True)
    (a.output/'timeline.json').write_text(json.dumps(trace))
    (a.output/'clock-and-stages.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
