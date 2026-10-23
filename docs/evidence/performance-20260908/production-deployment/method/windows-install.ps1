param([ValidateSet('Check','Apply','Rollback')][string]$Mode='Check')
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$ErrorActionPreference='Stop'
$directory='C:\Users\wilf\Viewflow\desktop-test'
$manifest='C:\Users\wilf\Viewflow\performance-stage-20260909\windows-staged.json'
$backup='C:\Users\wilf\Viewflow\performance-backup-20260909'
$items=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
$active=@(Get-CimInstance Win32_Process|Where-Object {
  $_.ExecutablePath -eq (Join-Path $directory 'vf-media-peer.exe') -or
  $_.ExecutablePath -eq (Join-Path $directory 'viewflow_windows_composition_preview.exe')
})
if($active.Count){throw 'Main peer or presenter is running; recheck coordinated deployment state'}
$task=Get-ScheduledTask -TaskName 'ViewflowMain-Active'
if($task.State -ne 'Ready'){throw 'Main task state changed; inspect before installation'}
if($items.Count -ne 10){throw 'Expected two binaries, seven DLLs and the opted-in launcher'}

function Get-HashOrNull([string]$path) {
  if(Test-Path -LiteralPath $path){return (Get-FileHash -LiteralPath $path).Hash}
  return $null
}
function Restore-Files {
  foreach($item in $items) {
    $name=[IO.Path]::GetFileName($item.target)
    if($null -ne $item.before) {
      $saved=Join-Path $backup $name
      if((Get-HashOrNull $saved) -ne $item.before){throw "Backup mismatch: $name"}
      Copy-Item -LiteralPath $saved -Destination ($item.target+'.restore') -Force
      if(Test-Path -LiteralPath $item.target){
        [IO.File]::Replace(($item.target+'.restore'),$item.target,[NullString]::Value)
      }else{[IO.File]::Move(($item.target+'.restore'),$item.target)}
    }elseif(Test-Path -LiteralPath $item.target){
      Remove-Item -LiteralPath $item.target
    }
    if((Get-HashOrNull $item.target) -ne $item.before){throw "Restore readback mismatch: $name"}
  }
}
if($Mode -eq 'Rollback'){
  Restore-Files
  [pscustomobject]@{mode=$Mode;restored=$true}|ConvertTo-Json
  exit 0
}
foreach($item in $items){
  if((Split-Path -Parent $item.target) -ne $directory){throw 'Unexpected installation directory'}
  if((Get-HashOrNull $item.staged) -ne $item.sha256){throw 'Staged file changed'}
  if((Get-HashOrNull $item.target) -ne $item.before){throw 'Installed file changed since staging'}
}
$configHash=(Get-FileHash (Join-Path $directory 'receive.json')).Hash
$scriptHash=(Get-FileHash (Join-Path $directory 'main-session.ps1')).Hash
if($configHash -ne 'F822FAAA945015E120679BB4F46822B8A941CFCB842D22476E7D834AD9DC90C0' -or
   $scriptHash -ne 'A4F1AA147E1851F4029033DC09FCFE158C1A7298A961AB2FE36A6E2480B8EFBB'){
  throw 'Main configuration or script changed since qualification'
}
if($Mode -eq 'Check'){
  [pscustomobject]@{mode=$Mode;files=$items.Count;task=$task.State;processes=$active.Count;config_hash=$configHash;script_hash=$scriptHash}|ConvertTo-Json
  exit 0
}
if(!(Test-Path -LiteralPath $backup)){New-Item -ItemType Directory -Path $backup|Out-Null}
foreach($item in $items){
  if($null -ne $item.before){
    $saved=Join-Path $backup ([IO.Path]::GetFileName($item.target))
    if(!(Test-Path -LiteralPath $saved)){Copy-Item -LiteralPath $item.target -Destination $saved}
    if((Get-HashOrNull $saved) -ne $item.before){throw 'Backup verification failed'}
  }
}
try {
  foreach($item in $items){
    if($item.sha256 -eq $item.before){continue}
    Copy-Item -LiteralPath $item.staged -Destination ($item.target+'.performance-new') -Force
    if((Get-HashOrNull ($item.target+'.performance-new')) -ne $item.sha256){throw 'Temporary copy mismatch'}
    if(Test-Path -LiteralPath $item.target){
      [IO.File]::Replace(($item.target+'.performance-new'),$item.target,[NullString]::Value)
    }else{[IO.File]::Move(($item.target+'.performance-new'),$item.target)}
    if((Get-HashOrNull $item.target) -ne $item.sha256){throw 'Installed readback mismatch'}
  }
  & (Join-Path $directory 'vf-media-peer.exe') validate-receive --config (Join-Path $directory 'receive.json') 1>$null
  if($LASTEXITCODE -ne 0){throw 'Installed peer configuration validation failed'}
  if((Get-FileHash (Join-Path $directory 'receive.json')).Hash -ne $configHash -or
     (Get-FileHash (Join-Path $directory 'main-session.ps1')).Hash -ne (@($items|Where-Object { $_.target -eq (Join-Path $directory 'main-session.ps1') })[0].sha256)){throw 'Configuration changed during installation'}
}catch{
  $failure=$_
  Restore-Files
  throw $failure
}
[pscustomobject]@{mode=$Mode;installed=@($items|ForEach-Object {
  [pscustomobject]@{path=$_.target;hash=(Get-HashOrNull $_.target)}
});backup=$backup;task=(Get-ScheduledTask -TaskName 'ViewflowMain-Active').State;config_hash=$configHash;script_hash=(Get-FileHash (Join-Path $directory 'main-session.ps1')).Hash}|ConvertTo-Json -Depth 5
