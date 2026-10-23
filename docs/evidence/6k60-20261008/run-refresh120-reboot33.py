"""Authorized reboot experiment; exact XML restoration and second boot in finally."""
import base64, subprocess, time, json
from pathlib import Path
r=Path(__file__).resolve().parent
ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','-o','HostKeyAlias=viewflow-windows','wilf@172.16.105.24']
base=r'C:\Users\wilf\Viewflow\fusion-20261007'
work=base+r'\refresh120-reboot33'
task='Viewflow-Refresh120-Reboot33'
def remote(s):
 p=subprocess.run(ssh+['powershell.exe','-NoProfile','-NonInteractive','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,text=True,timeout=30)
 if p.returncode: raise RuntimeError(p.stdout+p.stderr)
 return p.stdout.strip()
def put(path,text):
 data=base64.b64encode(text.encode('utf-8')).decode()
 remote(f"[IO.File]::WriteAllBytes('{path}',[Convert]::FromBase64String('{data}'))")
def launch(text):
 put(work+r'\session.ps1',text)
 remote(f"$a=New-ScheduledTaskAction -Execute '{base}\\build-16k\\Release\\viewflow_fusion_launcher.exe' -Argument '-File \"{work}\\session.ps1\"';$p=New-ScheduledTaskPrincipal -UserId wilf -LogonType Interactive -RunLevel Highest;Register-ScheduledTask -TaskName '{task}' -Action $a -Principal $p -Force | Out-Null;Start-ScheduledTask -TaskName '{task}'")
def wait_file(name,seconds=60):
 for _ in range(seconds//2):
  if remote(f"Test-Path '{work}\\{name}'")=='True':return
  time.sleep(2)
 raise RuntimeError('missing '+name)
def reboot():
 old=remote('(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc()')
 remote('shutdown.exe /r /t 5 /d p:0:0')
 for i in range(90):
  time.sleep(2)
  try:
   new=remote('(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToFileTimeUtc()')
   if new != old:
    print('New Windows boot observed',new,flush=True);time.sleep(15);return
  except (RuntimeError,subprocess.TimeoutExpired):pass
 raise RuntimeError('Windows reboot readiness timed out')
common=f"""$ErrorActionPreference='Stop'
$work='{work}'
$helper='{base}\\build-16k\\Release\\viewflow_virtual_display.exe'
function Run([string[]]$A) {{ $o=@(& $helper @A);if($LASTEXITCODE){{throw "helper failed $A"}};return $o }}
function Target {{
 $lines=@(Run @());$lines | Set-Content "$work\\layout-current.txt"
 $n=@();foreach($l in $lines){{if($l -match '^(.+?) \\| Virtual Display Driver \\| flags=(\\d+) \\| 0,0 6144x3456 refresh_hz=(\\d+)' -and ([int]$Matches[2] -band 4)){{$n+=$Matches[1]}}}}
 if($n.Count -ne 1){{throw 'primary 6K target ambiguous'}};return $n[0]
}}
"""
def inventory(tag):
 launch(common+f"""
try {{
 $d=Target
 Run @() | Set-Content "$work\\{tag}-layout.txt"
 Run @('modes',$d) | Set-Content "$work\\{tag}-modes.txt"
 Run @('dpi',$d) | Set-Content "$work\\{tag}-dpi.txt"
 'ok' | Set-Content "$work\\{tag}-done"
}} catch {{ $_ | Out-String | Set-Content "$work\\{tag}-error";throw }}
""")
 wait_file(tag+'-done')
 for kind in ['layout','modes','dpi']:
  value=remote(f"Get-Content '{work}\\{tag}-{kind}.txt' -Raw")
  (r/f'refresh120-reboot33-{tag}-{kind}.txt').write_text(value)
 print(tag,remote(f"Get-Content '{work}\\{tag}-layout.txt' -Raw"),flush=True)
remote(f"if(Test-Path '{work}'){{throw 'existing experiment'}};New-Item -ItemType Directory '{work}' | Out-Null;Copy-Item C:\\VirtualDisplayDriver\\vdd_settings.xml '{work}\\original.xml';if((Get-FileHash '{work}\\original.xml').Hash -ne 'A0F5A3FB82344F3D0F90DF92D213A46EB3BC0690F0FD3E9DB5AD5A9416B978EF'){{throw 'baseline changed'}}")
inventory('before')
changed=False
try:
 changed=True
 put(r'C:\VirtualDisplayDriver\vdd_settings.xml',(r/'refresh120-highres-fixture-proposed.xml').read_text())
 print('Installed only extra 6K120 capability; rebooting',flush=True)
 reboot()
 inventory('loaded')
 launch(common+r"""
$d=$null
try {
 $d=Target
 Run @('test-refresh',$d,'120') | Set-Content "$work\test120.txt"
 Run @('refresh',$d,'120') | Set-Content "$work\set120.txt"
 Run @() | Set-Content "$work\during-layout.txt"
 $actual=(Run @()) -join "`n"
 if($actual -notmatch '0,0 6144x3456 refresh_hz=120'){throw '120 readback failed'}
 'ready' | Set-Content "$work\ready"
 $end=(Get-Date).AddSeconds(240)
 while(-not(Test-Path "$work\finish") -and (Get-Date) -lt $end){Start-Sleep -Milliseconds 500}
} catch {$_ | Out-String | Set-Content "$work\guard-error.txt"} finally {
 if($d){Run @('refresh',$d,'60') | Set-Content "$work\restore60.txt"}
 'done' | Set-Content "$work\guard-done"
}
""".replace('"$work\\','"$work\\'))
 wait_file('ready',60)
 print('Verified 6K120; running 60 fps source trial',flush=True)
 import os
 subprocess.run(['python3',str(r/'run-pixel-progressive33-control.py'),'enabled','5'],env=os.environ|{'DEADLINE_RUN_SUFFIX':'progressive33'},check=True)
finally:
 if changed:
  remote(f"'finish' | Set-Content '{work}\\finish'")
  # Guard may not have started if capability validation failed.
  for _ in range(20):
   if remote(f"(Get-ScheduledTask -TaskName '{task}').State")!='Running':break
   time.sleep(2)
  remote(f"Copy-Item '{work}\\original.xml' C:\\VirtualDisplayDriver\\vdd_settings.xml -Force;if((Get-FileHash C:\\VirtualDisplayDriver\\vdd_settings.xml).Hash -ne (Get-FileHash '{work}\\original.xml').Hash){{throw 'XML restoration mismatch'}}")
  print('Restored original XML; second reboot removes added capability',flush=True)
  reboot()
  inventory('restored')
  remote(f"Unregister-ScheduledTask -TaskName '{task}' -Confirm:$false")
  subprocess.run(['systemctl','--user','restart','viewflow-ivshmem-windows.service'],check=True)
  print('Restoration completed',flush=True)
