from pathlib import Path
p=Path('/tmp/viewflow-summarize-codec-split.py');s=p.read_text();s=s.replace(" result.append(row)",r''' attempts_raw=t.rows(texts['receiver'],'atlas-nowait-present ')
 attempts=[t.numbers(x) for x in attempts_raw]
 assert all(all(k in x for k in ['frame','bound','begin_qpc','copied_qpc','present_qpc','status']) for x in attempts)
 assert all(x['begin_qpc']<=x['copied_qpc']<=x['present_qpc'] for x in attempts)
 hz=anchor['frequency'];busy_status=-2005270518
 assert all(x['status'] in [0,busy_status] for x in attempts)
 success=[x for x in attempts if x['status']==0];busy=[x for x in attempts if x['status']==busy_status]
 row['swap_attempts']=dict(total=len(attempts),success=len(success),busy=len(busy),bound_success=sum(x['bound'] for x in success),unbound_success=sum(not x['bound'] for x in success),status_counts=dict(collections.Counter(x['status'] for x in attempts)),copy_host_ms=t.stats([(x['copied_qpc']-x['begin_qpc'])*1000/hz for x in attempts]),present_host_ms=t.stats([(x['present_qpc']-x['copied_qpc'])*1000/hz for x in attempts]),success_present_host_ms=t.stats([(x['present_qpc']-x['copied_qpc'])*1000/hz for x in success]),busy_present_host_ms=t.stats([(x['present_qpc']-x['copied_qpc'])*1000/hz for x in busy]))
 row['sampled_swap_surface']=t.rows(texts['receiver'],'atlas-nowait-surface ')
 row['nowait_enabled']='nowait1' in label
 if row['nowait_enabled']:assert len(success)>20 and row['swap_attempts']['bound_success']>0
 else:assert not attempts
 row['swap_attempt_rows']=attempts
 result.append(row)''')
s=s.replace('viewflow-codec-split-comparison.json','viewflow-nowait-swap-comparison.json')
Path('/tmp/viewflow-summarize-nowait-swap.py').write_text(s)
