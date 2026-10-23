from pathlib import Path
import subprocess
b=Path(__file__).resolve().parents[2]
for label,mode,interval in [('combinedzero-four-a1','frame-rate','0'),('combineddefault-two-b1','latency','16000'),('combineddefault-two-b2','latency','16000'),('combinedzero-four-a2','frame-rate','0'),('combinedzero-two-c1','latency','0'),('combinedzero-two-c2','latency','0')]:
    print('RUN',label,flush=True)
    subprocess.run(['python3',str(b/'transport/method/nested-depth-combined.py'),label,mode,'auto',interval],check=True)
    subprocess.run(['python3',str(b/'transport/method/analyze.py'),label],check=True)
