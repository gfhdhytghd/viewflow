import subprocess,os
from pathlib import Path
r=Path(__file__).resolve().parent
helper=r.parents[2]/'build/ivshmem-backup/remote.py'
def remote(script):
 return subprocess.run(['python3',str(helper)],input="$ProgressPreference='SilentlyContinue';"+script,text=True,check=True)
remote("wpr -start GPU -start DesktopComposition -instancename Viewflow6KProgressive9;if($LASTEXITCODE){throw 'WPR start failed'}")
try:
 subprocess.run(['python3',str(r/'run-pixel-progressive9-control.py'),'enabled','5'],env=os.environ|{'DEADLINE_RUN_SUFFIX':'progressive9'},check=True)
finally:
 remote("wpr -stop C:\\Users\\wilf\\Viewflow\\progressive9.etl -instancename Viewflow6KProgressive9;if($LASTEXITCODE){throw 'WPR stop failed'};Get-Item C:\\Users\\wilf\\Viewflow\\progressive9.etl | Select Length | ConvertTo-Json -Compress")
