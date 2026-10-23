from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,enabled in [('copyflush-off-a1','0'),('copyflush-on-b1','1'),('copyflush-on-b2','1'),('copyflush-off-a2','0')]:
 print('BEGIN',label,enabled,flush=True)
 subprocess.run(['python3',str(b/'nested-copyflush.py'),label,'frame-rate','auto','2','0',enabled],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('COPYFLUSH_SERIES_PASSED',flush=True)
