from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,interval in [('interval0-a1','0'),('interval32-b1','32000'),('interval32-b2','32000'),('interval0-a2','0')]:
 print('BEGIN',label,interval,flush=True)
 subprocess.run(['python3',str(b/'nested-interval.py'),label,'frame-rate','auto',interval],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('INTERVAL_SERIES_PASSED',flush=True)
