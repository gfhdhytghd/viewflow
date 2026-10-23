from pathlib import Path
import subprocess
b=Path(__file__).resolve().parents[2]
for label,interval in [('markerinterval-default-a1','16000'),('markerinterval-zero-b1','0'),('markerinterval-zero-b2','0'),('markerinterval-default-a2','16000')]:
    print('RUN',label,flush=True)
    subprocess.run(['python3',str(b/'transport/method/nested-marker-interval.py'),label,'frame-rate','auto',interval],check=True)
    subprocess.run(['python3',str(b/'transport/method/analyze.py'),label],check=True)
    subprocess.run(['python3',str(b/'marker-profile/method/analyze-stages.py'),label],check=True)
