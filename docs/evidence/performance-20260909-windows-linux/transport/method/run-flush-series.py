from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,delay in [('flush0-a1','0'),('flush5-b1','5'),('flush5-b2','5'),('flush0-a2','0')]:
 print('BEGIN',label,delay,flush=True)
 subprocess.run(['python3',str(b/'nested-flush.py'),label,'frame-rate','auto','2',delay],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('FLUSH_SERIES_PASSED',flush=True)
