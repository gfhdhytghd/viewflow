"""Change only fixture color cadence; reuse the combined transport experiment."""
import subprocess,base64,os
ssh=['ssh','-o','BatchMode=yes','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
def remote(script):
    script='$ErrorActionPreference="Stop";$ProgressPreference="SilentlyContinue";'+script
    subprocess.run(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],check=True)
remote(r'''
$p='C:\Users\wilf\Viewflow\fusion-20261007\motion-probe.ps1'
$s=[IO.File]::ReadAllText($p)
if(-not $s.Contains("-ArgumentList '30'")){throw 'fixture arguments changed'}
Copy-Item $p "$p.before-cycle8" -Force
[IO.File]::WriteAllText($p,$s.Replace("-ArgumentList '30'","-ArgumentList @('30','cycle8')"))
''')
try:
    subprocess.run(['python','docs/evidence/6k60-20261008/run-capture-event-paced.py'],env=os.environ|{'DEADLINE_RUN_SUFFIX':'cycle8'},check=True)
finally:
    remote(r'''
$p='C:\Users\wilf\Viewflow\fusion-20261007\motion-probe.ps1'
Copy-Item "$p.before-cycle8" $p -Force
''')
