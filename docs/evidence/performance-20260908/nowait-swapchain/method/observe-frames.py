import pathlib,subprocess,base64,time,sys,os
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();label=sys.argv[1]
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; "+s).encode('utf-16le')).decode()],capture_output=True,timeout=30)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode(errors='replace'))
 return r.stdout.decode(errors='replace')
native_dir=os.environ.get('VIEWFLOW_OBSERVER_NATIVE_DIR','native-build')
assert native_dir in ('native-build','native-av1-build','native-nowait-build')
for _ in range(40):
 out=ps("$p=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -eq '"+root+"\\"+native_dir+"\\Release\\viewflow_windows_composition_preview.exe'}); if($p.Count -eq 1){Write-Output $p[0].ProcessId}").strip()
 if out.isdigit():break
 time.sleep(.25)
else:raise RuntimeError('owned native process not observed')
observer_exe=os.environ.get('VIEWFLOW_OBSERVER_EXE','viewflow_windows_frame_observer.exe')
assert observer_exe in ('viewflow_windows_frame_observer.exe','viewflow_windows_frame_observer_sync.exe','viewflow_windows_window_frame_observer.exe')
kind='window' if observer_exe=='viewflow_windows_window_frame_observer.exe' else 'desktop'
pid=int(out);name='ViewflowPerf-WindowFrameObserver' if kind=='window' else 'ViewflowPerf-FrameObserver';log=root+'\\'+kind+'-marker.log'
args=str(pid)+' 20000 "'+log+'"'+(' physical4k' if os.environ.get('VIEWFLOW_OBSERVE_PHYSICAL4K')=='1' else '')
timer=os.environ.get('VIEWFLOW_OBSERVER_TIMER')
if timer in ('0','1'):args+=' timer'+timer
print(ps("$name='"+name+"'; if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'observer task exists'}; $principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal; $action=New-ScheduledTaskAction -Execute '"+root+"\\native-build\\Release\\"+observer_exe+"' -Argument '"+args+"' -WorkingDirectory '"+root+"'; Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) | Out-Null; Start-ScheduledTask -TaskName $name"),flush=True)
for _ in range(40):
 time.sleep(1)
 if ps("Write-Output (Get-ScheduledTask -TaskName '"+name+"').State").strip()!='Running':break
else:raise RuntimeError('observer still running')
result=ps("Write-Output ('exit='+ (Get-ScheduledTaskInfo -TaskName '"+name+"').LastTaskResult); Get-Content '"+log+"' -Tail 3; Unregister-ScheduledTask -TaskName '"+name+"' -Confirm:$false")
subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+log.replace(chr(92),'/'),'/tmp/viewflow-integrated-pair/'+kind+'-'+label+'.log'],check=True)
print(result,flush=True)
