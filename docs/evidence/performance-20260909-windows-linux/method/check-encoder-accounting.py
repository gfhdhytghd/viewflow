"""Check accepted PTS order and the no-input drain barrier in diagnostic logs."""
from pathlib import Path
import json,re,sys
p=Path(sys.argv[1]);accepted=[];outputs=[];draining=False;begins=ends=0;flush=[]
for line in (p/'source.log').read_text(errors='replace').splitlines():
 d=dict(re.findall(r'(\w+)=(-?\d+)',line))
 if line.startswith('encoder_drain_begin '):
  assert not draining,line
  draining=True;begins+=1
 elif line.startswith('encoder_drain_end '):
  assert draining,line
  draining=False;ends+=1
 elif line.startswith('encoder_input '):
  assert not draining,line
  if int(d['mfx_status']) in (0,-10):accepted.append(int(d['pts']))
 elif line.startswith('encoder_output '):outputs.append(int(d['pts']))
 elif line.startswith('encoder_flush '):
  assert draining and int(d['pending'])==0,line
  flush.append(int(d['mfx_status']))
bounded='--bounded-stop' in sys.argv
assert accepted and accepted[:len(outputs)]==outputs and len(set(accepted))==len(accepted)
assert 0<=len(accepted)-len(outputs)<=2 if bounded else accepted==outputs
assert begins-ends==int(draining) if bounded else not draining and begins==ends
assert set(flush)<=set([0,-10]),set(flush)
r={'accepted':len(accepted),'output':len(outputs),'all_output_pts_match_accepted_prefix_once_in_order':True,'accepted_not_output_before_bounded_stop':len(accepted)-len(outputs),'draining_at_stop':draining,'bounded_stop':bounded,'drain_begins':begins,'drain_ends':ends,'no_input_during_drain':True,'all_null_inputs_after_existing_tasks_complete':True,'flush_status_counts':{str(k):flush.count(k) for k in set(flush)}}
(p/'encoder-accounting.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
