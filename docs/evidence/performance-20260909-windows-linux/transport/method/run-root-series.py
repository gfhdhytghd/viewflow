from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,mode in [('root-frame-a1','frame-rate'),('root-latency-b1','latency'),('root-latency-b2','latency'),('root-frame-a2','frame-rate')]:
 print('BEGIN',label,mode,flush=True)
 subprocess.run(['python3',str(b/'nested-root.py'),label,mode],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('ROOT_SERIES_PASSED',flush=True)
