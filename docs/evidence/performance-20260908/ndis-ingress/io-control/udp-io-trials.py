import subprocess,os,json,re,collections,statistics
from pathlib import Path
result={}
for label,mode in [('io-a1','blocking'),('io-b1','nonblocking'),('io-b2','nonblocking'),('io-a2','blocking')]:
 subprocess.run(['python3','/tmp/viewflow-run-udp-io.py',label],env=dict(os.environ,VIEWFLOW_PROBE_PORT='49101',VIEWFLOW_PROBE_PAIRS='24',VIEWFLOW_PROBE_PAUSE='.1',VIEWFLOW_PROBE_IO=mode),check=True)
 tx=json.loads(Path('/tmp/viewflow-udp-burst-'+label+'-source.json').read_text());rx=Path('/tmp/viewflow-udp-burst-'+label+'-receiver.log').read_text();groups=collections.defaultdict(list)
 for b,n,t in re.findall(r'probe-packet batch=(\d+) sequence=(\d+) qpc=(\d+)',rx):groups[int(b)].append((int(n),int(t)))
 assert len(groups)==len(tx)==52
 for r in tx:
  g=groups[r['batch']];assert len(g)==r['packets'] and len({n for n,q in g})==r['packets'];r['receive_span_ms']=(max(q for n,q in g)-min(q for n,q in g))/100000
 result[label]={'mode':mode,'batches':tx,'would_block':int(re.search(r'probe-would-block count=(\d+)',rx)[1])}
 print(label,mode,'RTTmedian/max',statistics.median(r['round_trip_us']/1000 for r in tx),max(r['round_trip_us']/1000 for r in tx),'RXspanmax',max(r['receive_span_ms'] for r in tx),flush=True)
Path('/tmp/viewflow-udp-io-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
