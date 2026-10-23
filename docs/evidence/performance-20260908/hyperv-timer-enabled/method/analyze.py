from pathlib import Path
import json,math,re,statistics
b=Path(__file__).resolve().parent
lines=(b/'wait-resolution.log').read_text().splitlines()
def fields(line):return {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
meta=fields(next(x for x in lines if x.startswith('probe ')))
end=fields(next(x for x in lines if x.startswith('result ')))
assert meta['period_result']==0 and end['samples']==2048 and end['restored']==1 and end['exit']==0
policies=[fields(x) for x in lines if x.startswith('block=')]
assert [x['mode'] for x in policies]==[0,1,2,3,3,2,1,0]
samples=[fields(x) for x in lines if x.startswith('sample ')]
assert len(samples)==2048
results=[]
for policy in policies:
    block=policy['block'];mode=policy['mode'];ss=[x for x in samples if x['block']==block]
    assert len(ss)==256 and [x['index'] for x in ss]==list(range(256))
    assert all(x['mode']==mode and x['end']>=x['begin'] and x['result']==(0 if mode&2 else 258) for x in ss)
    if not mode&1:
        assert policy['policy_control']==meta['original_control'] and policy['policy_state']==meta['original_state']
    us=sorted((x['end']-x['begin'])*1000000/meta['qpc_frequency'] for x in ss)
    results.append(dict(policy,requested_us=1000,n=len(us),min_us=us[0],median_us=statistics.median(us),p95_us=us[math.ceil(.95*len(us))-1],max_us=us[-1]))
state=json.loads((b/'state.json').read_text(encoding='utf-8-sig'))
assert state['result']==state['remaining']==state['tasks']==0 and state['before_esrv']==state['after_esrv']
report=dict(meta=meta,result=end,blocks=results,scope='idle diagnostic process; no stream throughput or presentation result')
(b.parent/'wait-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
for r in results:print(r['block'],r['mode'],round(r['median_us'],2),round(r['p95_us'],2))
