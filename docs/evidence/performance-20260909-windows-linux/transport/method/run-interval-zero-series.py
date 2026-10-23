from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,interval in [('interval16-c1','16000'),('interval0-d1','0'),('interval0-d2','0'),('interval16-c2','16000')]:
 print('BEGIN',label,interval,flush=True)
 subprocess.run(['python3',str(b/'nested-interval.py'),label,'frame-rate','auto',interval],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('INTERVAL_SERIES_PASSED',flush=True)
