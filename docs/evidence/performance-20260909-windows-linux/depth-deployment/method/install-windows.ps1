[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('eyJzb3VyY2UiOiAiQzpcXFVzZXJzXFx3aWxmXFxWaWV3Zmxvd1xccGVyZi1pc29sYXRlZC04ZTk3YzFiNzUxZmNcXHJldmVyc2Utcm9vdC1kZXB0aC0yMDI2MDkwOVxcYnVpbGRcXFJlbGVhc2VcXHZpZXdmbG93X3dpbmRvd3NfcmV2ZXJzZS5leGUiLCAiaGFzaCI6ICJDOTE0Q0M0N0E1NTQ5NEVERDk2QjdDOEJCMzVCRDk5RUU3Njk3NDBEMTI3MTU2MjQxQjQ1MjQ2RDk4RjI5M0RCIiwgIm9sZCI6ICI4NzVFNTZGOUU3NDZCNURBRUEzNzgxNERDNjdDNTQ0OTVBOUIzMTNDRDZGMEVCNkIyNjUyQTU5RjA1N0Y0MkZFIiwgInN0YW1wIjogIjIwMjYwOTA5VDE1NDYzN1oifQ=='))|ConvertFrom-Json
$target='C:\Users\wilf\Viewflow\desktop-test\viewflow_windows_reverse.exe';$receive='C:\Users\wilf\Viewflow\desktop-test\receive.json';$mode=Join-Path (Split-Path $target) 'reverse-performance-mode'
if((Get-FileHash $p.source).Hash -ne $p.hash -or (Get-FileHash $target).Hash -ne $p.old){throw 'native identity changed'}
if((Get-ScheduledTask 'ViewflowMain-Active').State.ToString() -ne 'Ready'){throw 'main session is running'}
if(@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $target -or $_.ExecutablePath -like '*reverse-root-depth-20260909*' -or $_.ExecutablePath -like '*reverse-lifecycle-root-depth-20260909*' -or $_.ExecutablePath -like '*reverse-transport-20260909*'}).Count){throw 'native or benchmark is still running'}
$before=@{receive=(Get-FileHash $receive).Hash;mode=(Get-FileHash $mode).Hash;runtime=(Get-FileHash 'C:\Windows\System32\libvpl.dll').Hash;depth_user=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_VPL_DEPTH','User');depth_machine=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_VPL_DEPTH','Machine');encoder_user=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_ENCODER','User');encoder_machine=[Environment]::GetEnvironmentVariable('VIEWFLOW_REVERSE_ENCODER','Machine')}
if($before.encoder_user -notin @($null,'','auto') -or $before.encoder_machine -notin @($null,'','auto')){throw 'existing explicit encoder override needs inspection'}
if($before.depth_user -notin @($null,'','2') -or $before.depth_machine -notin @($null,'','2')){throw 'existing depth override needs inspection'}
$backup='C:\Users\wilf\Viewflow\performance-depth-backup-'+$p.stamp;if(Test-Path $backup){throw 'backup already exists'};New-Item -ItemType Directory $backup|Out-Null
Copy-Item $target (Join-Path $backup 'viewflow_windows_reverse.exe');$temp=$target+'.'+$p.stamp+'.tmp';$replaced=$false
try{
 Copy-Item $p.source $temp;if((Get-FileHash $temp).Hash -ne $p.hash){throw 'staged binary hash mismatch'}
 [IO.File]::Replace($temp,$target,[NullString]::Value);$replaced=$true
 $status=& $target --performance-status|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or $status.schema -ne 1){throw 'installed native status failed'}
 if((Get-FileHash $target).Hash -ne $p.hash -or (Get-FileHash $receive).Hash -ne $before.receive -or (Get-FileHash $mode).Hash -ne $before.mode){throw 'post-install files mismatch'}
 [pscustomobject]@{target=$target;hash=(Get-FileHash $target).Hash;backup=$backup;backup_hash=(Get-FileHash (Join-Path $backup 'viewflow_windows_reverse.exe')).Hash;status=$status;before=$before;receive_hash=(Get-FileHash $receive).Hash;mode_hash=(Get-FileHash $mode).Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();streams=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $target}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 6
}catch{
 if($replaced){$rollback=$target+'.rollback.tmp';Copy-Item (Join-Path $backup 'viewflow_windows_reverse.exe') $rollback;[IO.File]::Replace($rollback,$target,[NullString]::Value)}
 throw
}finally{if(Test-Path $temp){Remove-Item $temp}}
