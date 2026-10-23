from pathlib import Path
import json,re,math,hashlib,shutil
b=Path(__file__).resolve().parents[2];p=b/'source-wait-profile';d=b/'transport/runs/source-wait-long-latency-a1'
read=lambda p:json.loads(p.read_text());sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
m=read(p/'method/source-sha256.json');assert len(m)==69 and m==read(p/'method/remote-source-sha256.json') and all(sha(p/'source'/k)==v for k,v in m.items())
assert '100% tests passed, 0 tests failed out of 6' in (p/'method/build.log').read_text()
t=(d/'source.log').read_text();rows=lambda prefix:[dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)',s)) for s in t.splitlines() if s.startswith(prefix+' ')]
summaries=rows('profile_wait_summary');bins=rows('profile_wait_bin');assert len(summaries)==8;names=read(p/'method/reasons.json');out=[]
for s in summaries:
 v=sorted((x for x in bins if x['reason']==s['reason']),key=lambda x:x['lower_ms']);assert sum(x['count'] for x in v)==s['count']
 lower=None;acc=0
 for x in v:
  acc+=x['count']
  if acc>=math.ceil(s['count']*.95):lower=x['lower_ms'];break
 out.append(dict(reason=names[str(s['reason'])],count=s['count'],mean_ms=s['sum_100ns']/10000/s['count'] if s['count'] else None,max_ms=s['max_100ns']/10000,p95_bin_lower_ms=lower,p95_bin_upper_ms=min(lower+1,s['max_100ns']/10000) if lower is not None and lower<63 else s['max_100ns']/10000 if lower is not None else None,histogram=v))
state=read(d/'state.json');assert state['native_hash_before']==state['native_hash_after'] and state['before']['installed']==state['after']['installed']=='C914CC47A55494EDD96B7C8BB35BD99EE769740D127156241B45246D98F293DB';assert not state['after']['processes'] and not state['after']['port'] and not state['remaining_proxies'];assert state['mode_before']['mode']==state['mode_restored']['mode']
a=read(d/'marker-stage-summary.json');r=read(d/'summary.json');assert r['run_qualified'] and a['paired']==r['steady_distinct'] and not a['excluded']
source=Path(state['nested_state']['root']);n=read(source/'state.json');assert n['nested_stopped'] and not n['remaining_clients'];target=b/'transport/nested/source-wait-long-latency-a1';target.mkdir(parents=True,exist_ok=True)
for name in ['state.json','hyprland.lua','compositor.log','inner.py','launch.py']:shutil.copy2(source/name,target/name)
result=dict(native_sha256=state['native_hash_before'],waits=out,full_route=r,paired_markers=a['paired'],limitations=['Histograms have 1 ms bins, with an overflow bin at 63 ms. Means and maxima use actual 100 ns samples.','Timing instrumentation adds overhead; slow operations are diagnostics, not proof of their contribution to a particular full-route outlier.'])
(p/'method/results.json').write_text(json.dumps(result,indent=2)+'\n')
for x in out:print(x['reason'],x['count'],x['mean_ms'],x['max_ms'])
