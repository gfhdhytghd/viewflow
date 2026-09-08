import pathlib,subprocess,base64,time
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; "+s).encode('utf-16le')).decode()],capture_output=True,timeout=30)
 if r.returncode:raise RuntimeError(r.stdout.decode(errors='replace')+r.stderr.decode('gb18030',errors='replace'))
 return r.stdout.decode(errors='replace')
s="$name='ViewflowPerf-CoalescePixels'; if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'test task already exists'}; $principal=(Get-ScheduledTask -TaskName ViewflowMain-Active).Principal; $action=New-ScheduledTaskAction -Execute '"+root+"\\native-nowait-build\\Release\\viewflow_sparse_coalesce_capture_test.exe' -WorkingDirectory '"+root+"'; Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) | Out-Null; Start-ScheduledTask -TaskName $name"
ps(s)
for _ in range(40):
 time.sleep(1)
 state=ps("Write-Output (Get-ScheduledTask -TaskName ViewflowPerf-CoalescePixels).State").strip()
 if state!='Running':break
else:raise RuntimeError('test still running; inspect existing task')
out=ps("Get-Content '"+root+"\\coalesce-pixels-result.log'; Write-Output ('exit='+ (Get-ScheduledTaskInfo -TaskName ViewflowPerf-CoalescePixels).LastTaskResult); Unregister-ScheduledTask -TaskName ViewflowPerf-CoalescePixels -Confirm:$false")
pathlib.Path('/tmp/viewflow-nowait-pixels.log').write_text(out);print(out,flush=True)
