$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new();$r='C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc';$name='ViewflowPerf-BinaryBackdrop';$exe=$r+'\native-binary-backdrop-build\Release\viewflow_sparse_binary_backdrop_test.exe';$work=$r+'\binary-backdrop-oracle-production';$result=-1;$registered=$false;
if(-not(Test-Path $exe)){throw 'oracle exe absent'};
if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){throw 'oracle task already exists'};
if(@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count){throw 'oracle already running'};
if(Test-Path $work){throw 'oracle work directory exists'};New-Item -ItemType Directory -Path $work|Out-Null;
try{
 $principal=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').Principal;
 Register-ScheduledTask -TaskName $name -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -WorkingDirectory $work) -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2))|Out-Null;$registered=$true;Start-ScheduledTask -TaskName $name;
 $start=Get-Date;Start-Sleep -Milliseconds 500;
 do{
  $t=Get-ScheduledTask -TaskName $name;$i=Get-ScheduledTaskInfo -TaskName $name;
  if($t.State -ne 'Running' -and $i.LastRunTime -ge $start.AddSeconds(-2)){break};
  if(((Get-Date)-$start).TotalSeconds -gt 90){throw 'oracle operation watchdog'};
  Start-Sleep -Milliseconds 500;
 }while($true);
 $result=$i.LastTaskResult;
}finally{
 if($registered){if((Get-ScheduledTask -TaskName $name).State -eq 'Running'){Stop-ScheduledTask -TaskName $name};Unregister-ScheduledTask -TaskName $name -Confirm:$false};
 @{exit=$result;owned_tasks=@(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue).Count;owned_processes=@(Get-CimInstance Win32_Process|Where-Object ExecutablePath -eq $exe).Count;exe_hash=(Get-FileHash $exe).Hash;time=(Get-Date).ToString('o')}|ConvertTo-Json|Set-Content -Encoding UTF8 ($work+'\state.json');
}
Get-Content ($work+'\binary-backdrop-result.log');Get-Content ($work+'\state.json');if($result -ne 0){exit 1}
