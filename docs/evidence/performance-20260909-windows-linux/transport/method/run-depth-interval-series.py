from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,interval in [('depthinterval-default-a1','16000'),('depthinterval-zero-b1','0'),('depthinterval-zero-b2','0'),('depthinterval-default-a2','16000')]:
 print('BEGIN',label,interval,flush=True)
 subprocess.run(['python3',str(b/'nested-depth-interval.py'),label,'frame-rate','auto',interval],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('DEPTH_INTERVAL_SERIES_PASSED',flush=True)
