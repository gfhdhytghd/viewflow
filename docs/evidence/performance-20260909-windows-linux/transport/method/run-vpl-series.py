from pathlib import Path
import subprocess,json
b=Path(__file__).resolve().parent
for label,backend in [('vpl-mft-a1','mft'),('vpl-direct-b1','vpl'),('vpl-direct-b2','vpl'),('vpl-mft-a2','mft')]:
 print('BEGIN',label,backend,flush=True)
 subprocess.run(['python3',str(b/'nested-vpl.py'),label,'frame-rate',backend],check=True)
 subprocess.run(['python3',str(b/'analyze.py'),label],check=True,stdout=subprocess.DEVNULL)
 s=json.loads((b.parent/'runs'/label/'summary.json').read_text());print('RESULT',label,s['desktop_distinct_hz'],s['latency_high_ms'],flush=True)
print('VPL_SERIES_PASSED',flush=True)
