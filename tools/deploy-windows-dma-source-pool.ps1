param(
 [Parameter(Mandatory=$true)][string]$BackupDirectory,
 [switch]$Apply
)
# Run only after the controlled benchmark has restored normal ownership.
# This is an administrative task stop, not a graceful GPU drain. No global
# process termination, input injection, shared-memory reset, or task rewrite.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$taskName='Viewflow-Windows-Linux-IVSHMEM'
$wrapper='C:\Users\wilf\Viewflow\ivshmem-20261007\windows-linux.ps1'
$native='C:\Users\wilf\Viewflow\fusion-20261007\build-16k\Release\viewflow_windows_reverse.dma-integrated-v3.exe'
$expectedHash='D946A703FABCA9C794F4758A9D49A5490E00C678BD01FD0E1A7842B1770D62DB'
$utf8=[Text.UTF8Encoding]::new($false)
$phase='preflight';$modified=$false;$stopped=$false;$backupReady=$false

function Owned-Processes {
 $all=@(Get-CimInstance Win32_Process)
 $roots=@($all | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($wrapper) -and ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'viewflow_fusion_launcher.exe')})
 $ids=[Collections.Generic.HashSet[uint32]]::new()
 foreach($root in $roots){[void]$ids.Add([uint32]$root.ProcessId)}
 do {$changed=$false;foreach($item in $all){if($ids.Contains([uint32]$item.ParentProcessId) -and $ids.Add([uint32]$item.ProcessId)){$changed=$true}}} while($changed)
 foreach($item in $all){
  if(-not $ids.Contains([uint32]$item.ProcessId)){continue}
  $process=Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue
  if(-not $process){continue}
  $null=$process.Handle # Retain the actual process object, never wait by PID alone.
  if($process.HasExited){$process.Dispose();continue}
  $ticks=$process.StartTime.ToUniversalTime().Ticks
  if([Math]::Abs($ticks-$item.CreationDate.ToUniversalTime().Ticks) -gt 10000){$process.Dispose();throw 'Process identity changed while capturing task tree'}
  [pscustomobject]@{Process=$process;Pid=$process.Id;StartTicks=[string]$ticks;Path=$process.Path}
 }
}
function Wait-Owned([object[]]$records) {
 $deadline=[DateTime]::UtcNow.AddSeconds(25)
 foreach($record in $records){
  $left=[Math]::Max(0,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds)
  if(-not $record.Process.WaitForExit($left)){throw 'Owned process exit not confirmed; no replacement writer may start'}
 }
}
function Assert-NoNative {
 # Read-only collision check. Never stop an unrelated instance by executable name.
 $remaining=@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -and ($_.ExecutablePath -ieq $oldNative -or $_.ExecutablePath -ieq $native)})
 if($remaining.Count){throw 'A matching native writer remains; no replacement writer may start'}
}
function Stop-OwnedTask([switch]$RequireRoots) {
 $records=@(Owned-Processes)
 if($RequireRoots -and -not $records.Count){throw 'Normal task process tree cannot be identified; no stop performed'}
 @($records | Select-Object Pid,StartTicks,Path) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $BackupDirectory ($phase+'-processes.json'))
 Stop-ScheduledTask -TaskName $taskName
 Wait-Owned $records
 foreach($record in $records){$record.Process.Dispose()}
 if((Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Task still running after stop'}
 Assert-NoNative
}
function Start-WithReconnectMarker([string]$Marker,[string]$FileName) {
 Start-ScheduledTask -TaskName $taskName
 @{state=[string](Get-ScheduledTask -TaskName $taskName).State;utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BackupDirectory $FileName)
 # Native startup depends on the Linux peer reconnecting; root owns that side.
 Write-Output $Marker
}
function Verify-Native([string]$ExpectedPath) {
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 while([DateTime]::UtcNow -lt $deadline){
  $records=@(Owned-Processes)
  $matches=@($records | Where-Object {$_.Path -ieq $ExpectedPath})
  if($matches.Count -eq 1 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){
   $record=$matches[0];Start-Sleep -Milliseconds 2000
   $alive=-not $record.Process.HasExited
   $result=@{pid=$record.Pid;start_utc_ticks=$record.StartTicks;native_path=$record.Path}
   foreach($entry in $records){$entry.Process.Dispose()}
   if($alive){return $result}
  }else{foreach($entry in $records){$entry.Process.Dispose()}}
  Start-Sleep -Milliseconds 250
 }
 throw 'Native startup unconfirmed after 30s; Linux peer reconnect may still be required'}
function Replace-Bytes([string]$Path,[byte[]]$Bytes) {
 $token=[Guid]::NewGuid().ToString('N')
 $temporary=$Path+'.viewflow-deploy-'+$token
 $replaceBackup=$Path+'.viewflow-replace-backup-'+$token
 # Windows PowerShell can coerce a null string argument to an empty path.
 # Supply a real unique backup path; the durable rollback copy is separate.
 try {[IO.File]::WriteAllBytes($temporary,$Bytes);[IO.File]::Replace($temporary,$Path,$replaceBackup)}
 finally {
  if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
  if(Test-Path -LiteralPath $replaceBackup){Remove-Item -LiteralPath $replaceBackup -Force}
 }
}

try {
 if(-not [IO.Path]::IsPathRooted($BackupDirectory)){throw 'BackupDirectory must be absolute'}
 if(Test-Path -LiteralPath $BackupDirectory){throw 'BackupDirectory must be new; refusing to overwrite rollback evidence'}
 if((Get-FileHash -LiteralPath $native -Algorithm SHA256).Hash -ne $expectedHash){throw 'Fixed candidate hash mismatch'}
 $originalWrapper=[IO.File]::ReadAllBytes($wrapper)
 $text=[IO.File]::ReadAllText($wrapper);$lines=$text -split '\r?\n'
 foreach($line in $lines){if($line.Trim() -and $line -notmatch '^\$env:([A-Za-z0-9_]+)=''([^'']*)''\s*$' -and $line -notmatch '^& '){throw 'Unsupported normal wrapper syntax'}}
 $invoke=@($lines | Where-Object {$_ -match '^& '})
 if($invoke.Count -ne 1 -or $invoke[0] -notmatch "^& '([^']+)' -Peer '([^']+)' -Config '([^']+)' -LogDirectory '([^']+)'\s*$"){throw 'Unsupported normal wrapper invocation'}
 $configPath=$matches[3]
 $originalConfig=[IO.File]::ReadAllBytes($configPath)
 $config=[IO.File]::ReadAllText($configPath) | ConvertFrom-Json
 $oldNative=[string]$config.backend.native
 if(-not $oldNative -or -not [IO.Path]::IsPathRooted($oldNative)){throw 'Existing native path unavailable'}
 $task=Get-ScheduledTask -TaskName $taskName
 if($task.State -ne 'Running'){throw 'Normal task is not running; finish benchmark/recovery before deployment'}
 $taskXml=Export-ScheduledTask -TaskName $taskName
 $config.backend.native=$native
 $candidateConfig=$utf8.GetBytes(($config | ConvertTo-Json -Depth 32)+"`r`n")
 $kept=@($lines | Where-Object {$_ -notmatch '^\$env:VIEWFLOW_SHM_D12_SOURCE_POOL=' -and $_.Trim()})
 $candidateWrapper=$utf8.GetBytes("`$env:VIEWFLOW_SHM_D12_SOURCE_POOL='1'`r`n"+($kept -join "`r`n")+"`r`n")
 if(-not $Apply){Write-Output 'Prepared plan only: fixed v3 native + source pool; rerun with -Apply after benchmark completion';return}
 New-Item -ItemType Directory -Path $BackupDirectory | Out-Null
 [IO.File]::WriteAllBytes((Join-Path $BackupDirectory 'windows-linux.ps1'),$originalWrapper)
 [IO.File]::WriteAllBytes((Join-Path $BackupDirectory 'windows-linux.json'),$originalConfig)
 [IO.File]::WriteAllText((Join-Path $BackupDirectory 'normal-task.xml'),$taskXml,$utf8)
 $backupReady=$true
 $phase='stop-original';Stop-OwnedTask -RequireRoots;$stopped=$true
 # Detect an external edit before any mutation. Never overwrite concurrent work.
 if([IO.File]::ReadAllText($wrapper) -cne $text){throw 'Wrapper changed during preflight'}
 $savedHash=(Get-FileHash -LiteralPath (Join-Path $BackupDirectory 'windows-linux.json')).Hash
 if((Get-FileHash -LiteralPath $configPath).Hash -ne $savedHash){throw 'Config changed during preflight'}
 $phase='replace';$modified=$true
 Replace-Bytes $configPath $candidateConfig
 Replace-Bytes $wrapper $candidateWrapper
 $phase='start-candidate';Start-WithReconnectMarker 'candidate-task-started' 'start-candidate.json'
 $verified=Verify-Native $native
 if((Get-FileHash -LiteralPath $native).Hash -ne $expectedHash){throw 'Candidate changed during deployment'}
 if((Export-ScheduledTask -TaskName $taskName) -cne $taskXml){throw 'Task definition changed during deployment'}
 @{status='deployed';native=$verified;sha256=$expectedHash;source_pool=$true;task_definition_unchanged=$true} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $BackupDirectory 'result.json')
 Write-Output 'Deployed fixed v3 native and source-pool wrapper; native process path verified'
} catch {
 $failureType=$_.Exception.GetType().FullName;$failureHresult=$_.Exception.HResult
 $rollbackType=$null;$rollbackHresult=$null
 $failedPhase=$phase;$rollback=if($failedPhase -eq 'stop-original'){'blocked-original-exit-unconfirmed'}else{'not-needed'}
 try {
  if($modified){
   $phase='stop-candidate';Stop-OwnedTask
   $phase='rollback-files'
   Replace-Bytes $configPath $originalConfig
   Replace-Bytes $wrapper $originalWrapper
   # Task XML was never modified; do not re-register credentials or task settings.
   if((Export-ScheduledTask -TaskName $taskName) -cne $taskXml){throw 'Task definition changed externally; restore requires review'}
   Start-WithReconnectMarker 'rollback-task-started' 'start-rollback.json'
   $null=Verify-Native $oldNative;$rollback='restored-and-verified'
  }elseif($stopped){Assert-NoNative;Start-WithReconnectMarker 'original-task-started' 'start-original.json';$null=Verify-Native $oldNative;$rollback='original-restarted'}
 } catch {$rollback='blocked-owned-exit-or-restore-unconfirmed';$rollbackType=$_.Exception.GetType().FullName;$rollbackHresult=$_.Exception.HResult}
 if($backupReady){@{status='failed';phase=$failedPhase;rollback=$rollback;error_type=$failureType;error_hresult=$failureHresult;rollback_error_type=$rollbackType;rollback_error_hresult=$rollbackHresult;configuration_contents_logged=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $BackupDirectory 'result.json')}
 # Deliberately avoid rendering exception records containing config/command text.
 throw "Viewflow deployment failed in $failedPhase; rollback=$rollback; consult local result.json"
}
