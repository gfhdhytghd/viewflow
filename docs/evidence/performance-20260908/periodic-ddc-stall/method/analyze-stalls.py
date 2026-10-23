from pathlib import Path
import json
b=Path(__file__).resolve().parent.parent
w=json.loads((b/'method/abba-ddc-processes.json').read_text())
rows=json.loads((b/'comparison.json').read_text());output=[]
for r in rows:
    matches=[]
    for d in r['encoding_outliers_over_20ms']:
        if d['encode_us']<=150000:continue
        watched=w['start_ns']<=d['encode_start_ns']<=w['end_ns']
        processes=[p for p in w['processes'] if p['first_seen_ns']<=d['encoded_ns'] and p['last_seen_ns']>=d['encode_start_ns']]
        matches.append(dict(frame=d['frame'],encode_start_ns=d['encode_start_ns'],encoded_ns=d['encoded_ns'],encode_us=d['encode_us'],watched=watched,ddc_processes=processes))
        if watched:assert len(processes)==1
    output.append(dict(label=r['label'],periodic_long_stalls=matches))
transitions=json.loads((b/'nested/state.json').read_text())['status_transitions']
for start,end in zip(transitions,transitions[1:]):
    if start['mode']=='ondemand':
        # Allow only the pre-existing query to finish immediately after a switch.
        assert not any(start['monotonic_ns']+1_000_000_000<p['first_seen_ns']<end['monotonic_ns'] for p in w['processes'])
assert [len(r['periodic_long_stalls']) for r in output]==[5,0,0,6]
assert sum(d['watched'] for r in output for d in r['periodic_long_stalls'])==7
(b/'method/stall-correlation.json').write_text(json.dumps(output,indent=2)+'\n')
print('PASS all seven watched long stalls overlap one DDC query; both on-demand phases have no DDC query or long stall')
