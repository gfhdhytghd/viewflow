import pathlib, subprocess, base64, time
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(script):
    r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,timeout=120)
    if r.returncode: print(r.stderr.decode(errors='replace'),flush=True)
    return r.returncode,r.stdout.decode(errors='replace')
code,out=ps(r"$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; $name='ViewflowPerf-HostBackdrop'; if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'isolated task already exists'}; $principal=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').Principal; $action=New-ScheduledTaskAction -Execute '"+root+r"\native-nowait-build\Release\viewflow_sparse_host_backdrop_test.exe' -WorkingDirectory '"+root+r"'; Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) | Out-Null; Start-ScheduledTask -TaskName $name; Write-Output 'started'")
print(code,out,flush=True)
if code: raise SystemExit(code)
for attempt in range(40):
    time.sleep(2)
    code,out=ps(r"$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; $name='ViewflowPerf-HostBackdrop'; $task=Get-ScheduledTask -TaskName $name; if($task.State -eq 'Running'){Write-Output 'RUNNING'; exit 0}; $info=Get-ScheduledTaskInfo -TaskName $name; Write-Output ('DONE result='+$info.LastTaskResult); Get-Content '"+root+r"\host-backdrop-result.log'; Unregister-ScheduledTask -TaskName $name -Confirm:$false; Write-Output 'REMOVED'; if($info.LastTaskResult -ne 0){exit 1}; exit 0")
    if 'RUNNING' not in out:
        print(code,out,flush=True);raise SystemExit(code)
print('task still running; retained for follow-up',flush=True)
