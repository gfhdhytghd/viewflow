[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('eyJzb3VyY2UiOiAiQzpcXFVzZXJzXFx3aWxmXFxWaWV3Zmxvd1xccGVyZi1pc29sYXRlZC04ZTk3YzFiNzUxZmNcXHJldmVyc2Utcm9vdC1wZXJmb3JtYW5jZS12Mi0yMDI2MDkwOVxcYnVpbGRcXFJlbGVhc2VcXHZpZXdmbG93X3dpbmRvd3NfcmV2ZXJzZS5leGUiLCAiaGFzaCI6ICJFMTU0M0YwNzU0QkFFMDc0MTk1NUVGNUZCRDE3ODI2MkVEMTBBRkUwNUUzODQ1MDYwRTI4QUFDNDEyMUI5M0QwIiwgInRhcmdldCI6ICJDOlxcVXNlcnNcXHdpbGZcXFZpZXdmbG93XFxkZXNrdG9wLXRlc3RcXHZpZXdmbG93X3dpbmRvd3NfcmV2ZXJzZS5leGUiLCAib2xkX2hhc2giOiAiNkVDNzlBNzM2MjVFNzFDRDcyM0I5OTVFNDU3RjE3QzQ0QThGNjkxMTg3MDQ3RjE5MkY4RDQzRDNEMUNGRTdDMyIsICJyZWNlaXZlX2hhc2giOiAiRjgyMkZBQUE5NDUwMTVFMTIwNjc5QkI0RjQ2ODIyQjhBOTQxQ0ZDQjg0MkQyMjQ3NkU3RDgzNEFEOURDOTBDMCIsICJzdGFtcCI6ICIyMDI2MDkwOVQxMzEzMDFaIn0='))|ConvertFrom-Json
if((Get-FileHash $p.source).Hash -ne $p.hash -or (Get-FileHash $p.target).Hash -ne $p.old_hash){throw 'native identity changed before install'}
if(@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $p.target}).Count){throw 'native source is running; install has not started'}
if((Get-ScheduledTask 'ViewflowMain-Active').State.ToString() -ne 'Ready'){throw 'main session changed; install has not started'}
$receive='C:\Users\wilf\Viewflow\desktop-test\receive.json'
if((Get-FileHash $receive).Hash -ne $p.receive_hash){throw 'receive configuration changed'}
$backup='C:\Users\wilf\Viewflow\performance-reverse-backup-'+$p.stamp
if(Test-Path $backup){throw 'backup exists'};New-Item -ItemType Directory $backup|Out-Null
Copy-Item $p.target (Join-Path $backup 'viewflow_windows_reverse.exe')
$modeFile=Join-Path (Split-Path -Parent $p.target) 'reverse-performance-mode';$hadMode=Test-Path $modeFile;$mode='frame-rate'
if($hadMode){Copy-Item $modeFile (Join-Path $backup 'reverse-performance-mode');$oldMode=(Get-Content $modeFile -Raw).Trim();if($oldMode -in @('frame-rate','latency')){$mode=$oldMode}}
$temp=$p.target+'.'+$p.stamp+'.tmp';$modeTemp=$modeFile+'.'+$p.stamp+'.tmp';$replaced=$false;$modeWritten=$false
try {
 Copy-Item $p.source $temp;if((Get-FileHash $temp).Hash -ne $p.hash){throw 'staged native mismatch'}
 [IO.File]::Replace($temp,$p.target,[NullString]::Value);$replaced=$true
 [IO.File]::WriteAllText($modeTemp,$mode+"`n",[Text.UTF8Encoding]::new($false))
 if($hadMode){[IO.File]::Replace($modeTemp,$modeFile,[NullString]::Value)}else{[IO.File]::Move($modeTemp,$modeFile)};$modeWritten=$true
 $status=& $p.target --performance-status|ConvertFrom-Json;if($LASTEXITCODE -ne 0 -or $status.schema -ne 1 -or $status.mode -ne $mode){throw 'installed settings check failed'}
 if((Get-FileHash $p.target).Hash -ne $p.hash -or (Get-FileHash $receive).Hash -ne $p.receive_hash){throw 'post-install identity mismatch'}
 [pscustomobject]@{target=$p.target;hash=(Get-FileHash $p.target).Hash;backup=$backup;status=$status;mode_file=$modeFile;had_mode_file=$hadMode;receive_hash=(Get-FileHash $receive).Hash;main=(Get-ScheduledTask 'ViewflowMain-Active').State.ToString();processes=@(Get-CimInstance Win32_Process|Where-Object{$_.ExecutablePath -eq $p.target -and $_.CommandLine -notmatch '--performance-status'}|Select-Object ProcessId,ExecutablePath)}|ConvertTo-Json -Depth 5
} catch {
 if($replaced){$restore=$p.target+'.restore';Copy-Item (Join-Path $backup 'viewflow_windows_reverse.exe') $restore;[IO.File]::Replace($restore,$p.target,[NullString]::Value)}
 if($modeWritten){if($hadMode){Copy-Item (Join-Path $backup 'reverse-performance-mode') $modeTemp;[IO.File]::Replace($modeTemp,$modeFile,[NullString]::Value)}else{Remove-Item $modeFile}}
 throw
} finally {if(Test-Path $temp){Remove-Item $temp};if(Test-Path $modeTemp){Remove-Item $modeTemp}}
