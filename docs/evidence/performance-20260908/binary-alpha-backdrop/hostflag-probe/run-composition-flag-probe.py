from pathlib import Path
import subprocess,base64,json,os,hashlib,time
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
local=Path('/tmp/viewflow-composition-latency-probe');local.mkdir(exist_ok=True)
def ps(code,timeout=60):
 prefix="$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();"
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode((prefix+code).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode(errors='replace'))
 return r.stdout.decode(errors='replace')
label,mode=sysargs=__import__('sys').argv[1:]
assert mode in ['winrt','dcomp','hostflag','sparse','elided','toggle','toggle-reverse','flag-toggle','flag-toggle-reverse'] and all(c.isalnum() or c=='-' for c in label)
source=r'''$r='__ROOT__';$label='__LABEL__';$mode='__MODE__';$probe='ViewflowPerf-CompositionProbe';$observer='ViewflowPerf-CompositionProbeObserver';$exe=$r+'\viewflow_windows_composition_latency_probe.exe';$dd=$r+'\native-build\Release\viewflow_windows_frame_observer.exe';$pidSeen=0;$registeredProbe=$false;$registeredObserver=$false;$probeResult=-1;$observerResult=-1;
if(Get-ScheduledTask -TaskName $probe,$observer -ErrorAction SilentlyContinue){throw 'probe task already exists'};
if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq $exe -or $_.ExecutablePath -eq $dd}).Count){throw 'probe or observer already running'};
$principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal;
try {
 $args=$mode+' 33000 "'+$r+'\'+$label+'-probe.log"';
 Register-ScheduledTask -TaskName $probe -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registeredProbe=$true;Start-ScheduledTask -TaskName $probe;
 for($i=0;$i -lt 60;$i++){ $p=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe);if($p.Count -eq 1){$pidSeen=$p[0].ProcessId;break};Start-Sleep -Milliseconds 200 };
 if(-not $pidSeen){throw 'probe process did not start'};
 $args=$pidSeen.ToString()+' 30000 "'+$r+'\'+$label+'-desktop.log" physical4k timer1';
 Register-ScheduledTask -TaskName $observer -Principal $principal -Action (New-ScheduledTaskAction -Execute $dd -Argument $args -WorkingDirectory $r) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registeredObserver=$true;Start-ScheduledTask -TaskName $observer;
 Start-Sleep -Milliseconds 500;
 $started=Get-Date;
 do { $p=Get-Process -Id $pidSeen -ErrorAction SilentlyContinue;$o=Get-ScheduledTask -TaskName $observer; if(-not $p -and $o.State -ne 'Running'){break};if(((Get-Date)-$started).TotalSeconds -gt 70){throw 'probe operation did not finish'};Start-Sleep -Milliseconds 500 } while($true);
 $probeResult=(Get-ScheduledTaskInfo -TaskName $probe).LastTaskResult;$observerResult=(Get-ScheduledTaskInfo -TaskName $observer).LastTaskResult;
 if($probeResult -ne 0 -or $observerResult -ne 0){throw ('probe/observer failed '+$probeResult+'/'+$observerResult)};
} finally {
 if($registeredObserver){if((Get-ScheduledTask -TaskName $observer).State -eq 'Running'){Stop-ScheduledTask -TaskName $observer};Unregister-ScheduledTask -TaskName $observer -Confirm:$false};
 if($registeredProbe){if((Get-ScheduledTask -TaskName $probe).State -eq 'Running'){Stop-ScheduledTask -TaskName $probe};Unregister-ScheduledTask -TaskName $probe -Confirm:$false};
 $owned=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -eq $exe -or $_.ExecutablePath -eq $dd});
 @{label=$label;mode=$mode;pid=$pidSeen;probe_exit=$probeResult;observer_exit=$observerResult;owned_processes=$owned.Count;owned_tasks=@(Get-ScheduledTask -TaskName $probe,$observer -ErrorAction SilentlyContinue).Count;probe_hash=(Get-FileHash $exe).Hash;observer_hash=(Get-FileHash $dd).Hash;time=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -Encoding UTF8 ($r+'\'+$label+'-state.json');
}
Get-Content ($r+'\'+$label+'-state.json');
'''.replace('__ROOT__',root).replace('__LABEL__',label).replace('__MODE__',mode)
(local/(label+'-run.ps1')).write_text(source)
try:
 script=local/(label+'-run.ps1')
 script.write_text("$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();\n"+source)
 remote=root.replace(chr(92),'/')+'/'+label+'-run.ps1'
 subprocess.run(['scp','-q','-o','BatchMode=yes',str(script),'wilf@172.16.105.70:'+remote],check=True)
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-ExecutionPolicy','Bypass','-File',remote],capture_output=True,timeout=100)
 (local/(label+'-driver.log')).write_bytes(r.stdout+r.stderr)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode('gb18030',errors='replace'))
 print(r.stdout.decode(errors='replace'),flush=True)
finally:
 for suffix in ['probe.log','desktop.log','state.json']:
  r=subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+label+'-'+suffix,str(local/(label+'-'+suffix))])
  if r.returncode:print('fetch_failed',label,suffix,flush=True)
s=json.loads((local/(label+'-state.json')).read_text(encoding='utf-8-sig'));assert s['probe_exit']==s['observer_exit']==s['owned_processes']==s['owned_tasks']==0
p=(local/(label+'-probe.log')).read_text();assert 'exit=0' in p and 'foreground_unchanged=1' in p
print('COMPLETE',label,mode,flush=True)
