"""Offline reproduction: python3 docs/evidence/6k60-20261008/analyze-motion89.py."""
import json,pathlib,re
base=pathlib.Path(__file__).resolve().parent

def stats(values):
 values=sorted(values)
 return {'count':len(values),'p50':values[len(values)//2],'p95':values[int(len(values)*.95)],'max':values[-1]} if values else {'count':0}

results={}
for number in (8,9):
 p=base/f'dma-production-motion{number}';analysis=json.loads((p/'analysis-v2.json').read_text());source=(p/'source.log').read_text();lo=analysis['loop']['begin_qpc'];hi=analysis['loop']['end_qpc'];rows=[];pending={}
 for line in source.splitlines():
  if line.startswith(('profile_d12_gpu_copy ','profile_d12_clock ','profile_d12_stages ')):pending.update(dict(re.findall(r'(\w+)=([^ ]+)',line)))
  if line.startswith('profile_shared_ready '):
   pts=int(re.search(r'pts=(\d+)',line)[1])
   if lo<=pts<=hi and 'estimated_end_qpc' in pending:rows.append(pending)
   pending={}
 metrics={key:stats([float(x[key]) for x in rows]) for key in ['host_wait_ms','import_ms','submit_cpu_ms','producer_observed_ms','consumer_observed_ms','max_poll_gap_ms','gpu_ms','submit_end_to_gpu_start_ms']}
 metrics['calibration_call_ms']=stats([(int(x['calibration_end_qpc'])-int(x['calibration_begin_qpc']))/1e4 for x in rows])
 metrics['estimated_gpu_end_to_cpu_observed_ms']=stats([float(x['consumer_observed_ms'])-(float(x['estimated_end_qpc'])-float(x['submit_end_qpc']))/1e4 for x in rows])
 metrics['submit_interval_ms']=stats([(float(y['submit_end_qpc'])-float(x['submit_end_qpc']))/1e4 for x,y in zip(rows,rows[1:])])
 metrics['previous_gpu_end_to_next_submit_ms']=stats([(float(y['submit_begin_qpc'])-float(x['estimated_end_qpc']))/1e4 for x,y in zip(rows,rows[1:])])
 results[str(number)]={'analysis':analysis,'queue_metrics':metrics,'adopt_records_all_session':len(re.findall(r'^profile_d12_adopt ',source,re.M)),'bridge_records_all_session':len(re.findall(r'^profile_d12_bridge ',source,re.M)),'restore':json.loads((p/'restore.json').read_text())}
(base/'dma-motion89-comparison.json').write_text(json.dumps({'scope':'Exact motion-loop PTS window; adjacent clock/stage/publication diagnostic association. Producer wait vs queue scheduling not separately resolved. End-to-observed is estimated, not pure polling sleep.','runs':results},indent=2)+'\n')
for n,r in results.items():
 print(n,{k:[round(v.get('p50',0),3),round(v.get('p95',0),3)] for k,v in r['queue_metrics'].items()},'adopt',r['adopt_records_all_session'],'bridge',r['bridge_records_all_session'])
