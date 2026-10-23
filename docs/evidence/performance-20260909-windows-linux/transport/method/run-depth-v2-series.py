from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,depth in [('depthv2-1-a1','1'),('depthv2-2-b1','2'),('depthv2-2-b2','2'),('depthv2-1-a2','1')]:
 print('BEGIN',label,depth,flush=True)
 subprocess.run(['python3',str(b/'nested-depth-v2.py'),label,'frame-rate','auto',depth],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('DEPTH_SERIES_PASSED',flush=True)
