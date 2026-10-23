import subprocess,os
from pathlib import Path
r=Path(__file__).resolve().parent
helper=r.parents[2]/'build/ivshmem-backup/remote.py'
def remote(script):
 subprocess.run(['python3',str(helper)],input="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+script,text=True,check=True)
remote("logman create trace Viewflow6KProgressive10 -p Microsoft-Windows-Dwm-Core 0x80 5 -o C:\\Users\\wilf\\Viewflow\\progressive10.etl -ct perf -bs 64 -nb 16 64 -ets;if($LASTEXITCODE){throw 'trace start failed'}")
try:
 subprocess.run(['python3',str(r/'run-pixel-progressive10-control.py'),'enabled','5'],env=os.environ|{'DEADLINE_RUN_SUFFIX':'progressive10'},check=True)
finally:
 remote("logman stop Viewflow6KProgressive10 -ets;if($LASTEXITCODE){throw 'trace stop failed'};Get-Item C:\\Users\\wilf\\Viewflow\\progressive10.etl | Select Length | ConvertTo-Json -Compress")
