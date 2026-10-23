from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,mode in [('depthlimitv2-four-a1','frame-rate'),('depthlimitv2-two-b1','latency'),('depthlimitv2-two-b2','latency'),('depthlimitv2-four-a2','frame-rate')]:
 backend='auto'
 print('BEGIN',label,backend,flush=True)
 subprocess.run(['python3',str(b/'nested-depth-limit-v2.py'),label,mode,backend],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('DEPTH_LIMIT_V2_SERIES_PASSED',flush=True)
