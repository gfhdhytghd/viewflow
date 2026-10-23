param([Parameter(Mandatory=$true)][string]$RunDirectory,[ValidateSet(1,2)][int]$InFlight=1,[string]$Native='', [switch]$GpuTiming,[switch]$HighPriority,[switch]$SourcePool,[ValidateRange(1,60)][int]$Seconds=20,[string]$FullscreenOutput='')
$ErrorActionPreference='Stop'
$normal='Viewflow-Windows-Linux-IVSHMEM'
$wrapper='C:\Users\wilf\Viewflow\ivshmem-20261007\windows-linux.ps1'
$fixturePath='C:\Users\wilf\Viewflow\fusion-20261007\build-16k\Release\viewflow_motion_fixture.exe'
$peer=$null; $fixture=$null; $restore=$false; $drained=$true; $nativeProcesses=@(); $oldExited=$true
try {
 # Parse, never execute or rewrite, the normal wrapper. Refuse unfamiliar syntax.
 $text=[IO.File]::ReadAllText($wrapper)
 $hash=(Get-FileHash $wrapper).Hash
 $lines=$text -split '\r?\n'
 foreach($line in $lines) {
  if($line -match '^\$env:([A-Za-z0-9_]+)=''([^'']*)''\s*$') { [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process') }
  elseif($line.Trim() -and $line -notmatch '^& ') {throw 'Unsupported normal wrapper syntax'}
 }
 $invoke=$lines | Where-Object {$_ -match '^& '}
 if($invoke.Count -ne 1 -or $invoke -notmatch "^& '([^']+)' -Peer '([^']+)' -Config '([^']+)' -LogDirectory '([^']+)'\s*$") {throw 'Unsupported normal invocation'}
 $session=$matches[1]; $peerPath=$matches[2]; $configPath=$matches[3]
 Copy-Item $wrapper (Join-Path $RunDirectory 'normal-wrapper.snapshot.ps1')
 Copy-Item $configPath (Join-Path $RunDirectory 'peer.json')
 if($Native){
  if(-not [IO.Path]::IsPathRooted($Native) -or -not (Test-Path -LiteralPath $Native -PathType Leaf)){throw 'Native override must name an existing absolute executable'}
  $config=Get-Content (Join-Path $RunDirectory 'peer.json') -Raw | ConvertFrom-Json
  $config.backend.native=$Native
  $config | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $RunDirectory 'peer.json')
 }
 Export-ScheduledTask -TaskName $normal | Set-Content (Join-Path $RunDirectory 'normal-task.xml')
 $restore=(Get-ScheduledTask -TaskName $normal).State -eq 'Running'
 @{normal_running=$restore;wrapper_hash=$hash;environment=@(Get-ChildItem Env:VIEWFLOW*)} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $RunDirectory 'before.json')
 # Match normal session defaults without invoking its endless restart loop.
 $env:VIEWFLOW_WINDOWS_INPUT_SERVICE='1'
 foreach($entry in @{VIEWFLOW_SHM_CAPTURE_STAGING='1';VIEWFLOW_SHM_COPY_THREADS='4';VIEWFLOW_SHM_COPY_AVX2='1';VIEWFLOW_WGC_INTERVAL_US='4000'}.GetEnumerator()) {
  if(-not [Environment]::GetEnvironmentVariable($entry.Key)){[Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process')}
 }
 Remove-Item Env:VIEWFLOW_FIXTURE_PIXEL_STAMP -ErrorAction SilentlyContinue
 # Clear any inherited fixture-only hook before deciding this invocation's route.
 foreach($name in @('VIEWFLOW_PROFILE_FULLSCREEN_OUTPUT','VIEWFLOW_PROFILE_FIXTURE_TOKEN','VIEWFLOW_PROFILE_FIXTURE_CREATED')){Remove-Item "Env:$name" -ErrorAction SilentlyContinue}
 if($FullscreenOutput){
  if($FullscreenOutput -notmatch '^\\\\\.\\DISPLAY[1-9][0-9]*$'){throw 'Invalid reserved output name'}
  if(-not $Native){throw 'DD fixture requires explicit candidate Native'}
  $env:VIEWFLOW_PROFILE_FULLSCREEN_OUTPUT=$FullscreenOutput
  $env:VIEWFLOW_PROFILE_FIXTURE_TOKEN=[Guid]::NewGuid().ToString('N')
  $env:VIEWFLOW_FULLSCREEN_DMA='1';$env:VIEWFLOW_FULLSCREEN_OUTPUT=$FullscreenOutput
  $env:VIEWFLOW_SHM_D12='1';$env:VIEWFLOW_SHM_D12_DD_SOURCE_POOL='1'
  $env:VIEWFLOW_SHM_CAPTURE_STAGING='0';$env:VIEWFLOW_SHM_CAPTURE_BANDS='0';$env:VIEWFLOW_SHM_PROGRESSIVE='0'
 }
 $env:VIEWFLOW_FIXTURE_START_GATE=Join-Path $RunDirectory 'start.gate'
 $env:VIEWFLOW_FIXTURE_HIGH_RES_TIMER='1'
 $env:VIEWFLOW_WGC_DELIVERY_TRACE='1'
 $env:VIEWFLOW_REVERSE_DIAGNOSTICS='1'
 $env:VIEWFLOW_SHM_D12_IN_FLIGHT=[string]$InFlight
 if($SourcePool){$env:VIEWFLOW_SHM_D12_SOURCE_POOL='1'}else{Remove-Item Env:VIEWFLOW_SHM_D12_SOURCE_POOL -ErrorAction SilentlyContinue}
 if($HighPriority){$env:VIEWFLOW_SHM_D12_HIGH_PRIORITY='1'}else{Remove-Item Env:VIEWFLOW_SHM_D12_HIGH_PRIORITY -ErrorAction SilentlyContinue}
 if($GpuTiming){$env:VIEWFLOW_SHM_D12_GPU_TIMING='1'}else{Remove-Item Env:VIEWFLOW_SHM_D12_GPU_TIMING -ErrorAction SilentlyContinue}
 @{in_flight=$InFlight;native_override=$Native;source_pool=[bool]$SourcePool;seconds=$Seconds;fullscreen_output=$FullscreenOutput;route_scope=$(if($FullscreenOutput){'owned producer DD; no Hyprland fullscreen manipulation'}else{'WGC fixture'});fixture_path=$fixturePath;fixture_sha256=(Get-FileHash $fixturePath).Hash} | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'parameters.json')
 if($restore){
  # Authorized administrative downtime; job teardown is forced, not GPU drain.
  $processes=@(Get-CimInstance Win32_Process)
  $roots=@($processes | Where-Object {$_.CommandLine -and $_.CommandLine.Contains($wrapper) -and ($_.Name -eq 'powershell.exe' -or $_.Name -eq 'viewflow_fusion_launcher.exe')})
  if(-not $roots.Count){throw 'Cannot identify normal task wrapper; no stop performed'}
  $ids=[Collections.Generic.HashSet[uint32]]::new()
  foreach($root in $roots){[void]$ids.Add([uint32]$root.ProcessId)}
  do {$changed=$false;foreach($item in $processes){if($ids.Contains([uint32]$item.ParentProcessId) -and $ids.Add([uint32]$item.ProcessId)){$changed=$true}}} while($changed)
  $oldHandles=@($processes | Where-Object {$ids.Contains([uint32]$_.ProcessId)} | ForEach-Object {$owned=Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue;if($owned){$null=$owned.Handle;$owned}})
  @{scope='administrative forced job stop; not graceful GPU drain';processes=@($oldHandles | Select-Object Id,StartTime,Path,@{Name='StartTimeUtcTicks';Expression={[string]$_.StartTime.ToUniversalTime().Ticks}})} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $RunDirectory 'normal-stop.json')
  $oldExited=$false
  Stop-ScheduledTask -TaskName $normal
  $deadline=[DateTime]::UtcNow.AddSeconds(20)
  $remainingProcesses=@()
  foreach($old in $oldHandles){$ms=[Math]::Max(0,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds);if(-not $old.WaitForExit($ms)){$remainingProcesses+=$old.Id}}
  $oldExited=$remainingProcesses.Count -eq 0
  if(-not $oldExited){@{blocked='old owned processes still alive; no test writer started; no SHM reset';pids=$remainingProcesses} | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'normal-stop-blocked.json');throw 'Old normal process exit not confirmed'}
 }
 $fixture=Start-Process -NoNewWindow -PassThru $fixturePath -ArgumentList "$Seconds waitable present-zero" -RedirectStandardError (Join-Path $RunDirectory 'fixture.log') -RedirectStandardOutput (Join-Path $RunDirectory 'fixture.stdout')
 $null=$fixture.Handle
 $env:VIEWFLOW_PROFILE_SOURCE_PID=[string]$fixture.Id
 if($FullscreenOutput){$env:VIEWFLOW_PROFILE_FIXTURE_CREATED=[string]$fixture.StartTime.ToFileTimeUtc()}
 $peer=Start-Process -NoNewWindow -PassThru $peerPath -ArgumentList @('--config',('"'+(Join-Path $RunDirectory 'peer.json')+'"')) -RedirectStandardError (Join-Path $RunDirectory 'source.log') -RedirectStandardOutput (Join-Path $RunDirectory 'source.stdout')
 $null=$peer.Handle
 @{peer_pid=$peer.Id;fixture_pid=$fixture.Id;fixture_created=$env:VIEWFLOW_PROFILE_FIXTURE_CREATED;fullscreen_output=$FullscreenOutput;gate=$env:VIEWFLOW_FIXTURE_START_GATE} | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'peer-ready.json')
 # Snapshot handles as well as PID, so PID reuse cannot target another process.
 Start-Sleep -Milliseconds 500
 $nativeProcesses=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($peer.Id)" | Where-Object {$_.ExecutablePath -eq ((Get-Content (Join-Path $RunDirectory 'peer.json') -Raw | ConvertFrom-Json).backend.native)} | ForEach-Object {$owned=Get-Process -Id $_.ProcessId -ErrorAction Stop;$null=$owned.Handle;$owned})
 @($nativeProcesses | Select-Object Id,StartTime,Path,@{Name='StartTimeUtcTicks';Expression={[string]$_.StartTime.ToUniversalTime().Ticks}}) | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'owned-native.json')
 $aborted=$false
 while(-not $fixture.WaitForExit(200)){
  if(Test-Path (Join-Path $RunDirectory 'stop.request')){
   $aborted=$true
   if(-not $fixture.HasExited){try {Stop-Process -InputObject $fixture -ErrorAction Stop} catch {if(-not $fixture.HasExited){throw}}}
   $fixture.WaitForExit()
   @{status='aborted';reason='host stop.request';fixture_pid=$fixture.Id} | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'aborted.json')
   break
  }
 }
 if($null -eq $fixture.ExitCode){throw 'Fixture exit status unavailable despite retained handle'}
 if(-not $aborted -and $fixture.ExitCode -ne 0){throw "Fixture exit $($fixture.ExitCode)"}
} catch {
 ($_ | Format-List * -Force | Out-String) | Set-Content (Join-Path $RunDirectory 'error.log')
 throw
} finally {
 $cleanupPhase='snapshot'
 try {
 # Only this invocation's process tree; never global process-name termination.
 if($peer -and -not $peer.HasExited){
  # Include children created after the first snapshot; never stop these children.
  $nativeProcesses+=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($peer.Id)" | Where-Object {$_.ExecutablePath -eq ((Get-Content (Join-Path $RunDirectory 'peer.json') -Raw | ConvertFrom-Json).backend.native)} | ForEach-Object {$owned=Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue;if($owned){$null=$owned.Handle;$owned}})
  @($nativeProcesses | Select-Object Id,StartTime,Path,@{Name='StartTimeUtcTicks';Expression={[string]$_.StartTime.ToUniversalTime().Ticks}}) | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'owned-native.json')
  $cleanupPhase='stop-peer'
  try {Stop-Process -InputObject $peer -ErrorAction Stop} catch {if(-not $peer.HasExited){throw}}
  $peer.WaitForExit()
 }
 $cleanupPhase='wait-native'
 $nativeProcesses=@($nativeProcesses | Group-Object Id | ForEach-Object {$_.Group[0]})
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 foreach($nativeProcess in $nativeProcesses){
  $remaining=[Math]::Max(0,[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds)
  if(-not $nativeProcess.WaitForExit($remaining)){$drained=$false}
 }
 if(-not $drained){@{blocked='owned native drain exceeded operation watchdog; GUI launcher job teardown will forcibly terminate remaining children after wrapper exits; no SHM reset; host must verify exit before normal restart';termination='pending launcher KILL_ON_JOB_CLOSE; not graceful';pids=@($nativeProcesses | Where-Object {-not $_.HasExited} | ForEach-Object {$_.Id})} | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'drain-blocked.json')}
 $cleanupPhase='stop-fixture'
 if($fixture -and -not $fixture.HasExited){try {Stop-Process -InputObject $fixture -ErrorAction Stop} catch {if(-not $fixture.HasExited){throw}};$fixture.WaitForExit()}
 $cleanupPhase='restore-normal'
 if($restore -and $drained -and $oldExited){Start-ScheduledTask -TaskName $normal;Start-Sleep -Milliseconds 500}
 @{wrapper_unchanged=((Get-FileHash $wrapper).Hash -eq $hash);native_drained=$drained;normal_state=[string](Get-ScheduledTask -TaskName $normal).State} | ConvertTo-Json | Set-Content (Join-Path $RunDirectory 'restore.json')
 if(-not $drained){throw 'Owned native did not drain; launcher job cleanup pending; verify process exit before restoring normal' }
 } catch {
  @{phase=$cleanupPhase;exception=($_ | Format-List * -Force | Out-String);job_cleanup='GUI launcher may forcibly terminate remaining children; host recovery must verify identities'} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $RunDirectory 'cleanup-error.json')
  throw
 }
}
