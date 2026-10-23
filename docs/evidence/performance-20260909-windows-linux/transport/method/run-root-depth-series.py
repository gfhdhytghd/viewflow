from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,mode in [('root-depth-frame-a1','frame-rate'),('root-depth-latency-b1','latency'),('root-depth-latency-b2','latency'),('root-depth-frame-a2','frame-rate')]:
 backend='auto'
 print('BEGIN',label,backend,flush=True)
 subprocess.run(['python3',str(b/'nested-root-depth.py'),label,mode,backend],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('ROOT_DEPTH_SERIES_PASSED',flush=True)
