from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,wrapper in [('topology-inner-c1','nested-real-output.py'),('topology-direct-d1','root-real-output.py'),('topology-direct-d2','root-real-output.py'),('topology-inner-c2','nested-real-output.py')]:
 print('BEGIN',label,wrapper,flush=True)
 subprocess.run(['python3',str(b/wrapper),label,'frame-rate','auto'],check=True)
 subprocess.run(['python3',str(b/'analyze-real-output.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('REAL_OUTPUT_SERIES_PASSED',flush=True)
