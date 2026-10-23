$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$work="$r\vdd-restore-retry"
$xml='C:\VirtualDisplayDriver\vdd_settings.xml'
$helper="$r\build-16k\Release\viewflow_virtual_display.exe"
New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
$log="$work\session.log"
function Invoke-Display([string[]]$Arguments) {
 $output=@(& $helper @Arguments)
 $output | Add-Content -Encoding UTF8 $log
 if($LASTEXITCODE){throw "display helper failed: $Arguments ($LASTEXITCODE)"}
 return $output
}
function Read-Layout {
 $result=@()
 foreach($line in (Invoke-Display @())) {
  if($line -match '^(.+?) \| Virtual Display Driver \| flags=(\d+) \| (-?\d+),(-?\d+) (\d+)x(\d+) refresh_hz=(\d+)' -and ([int]$Matches[2] -band 1)) {
   $result+= [pscustomobject]@{name=$Matches[1];flags=[int]$Matches[2];x=[int]$Matches[3];y=[int]$Matches[4];width=[int]$Matches[5];height=[int]$Matches[6];hz=[int]$Matches[7]}
  }
 }
 return $result
}
function Restart-Vdd {
 & pnputil.exe /restart-device 'ROOT\DISPLAY\0000' | Add-Content -Encoding UTF8 $log
 if($LASTEXITCODE){throw "VDD restart failed: $LASTEXITCODE"}
 $deadline=(Get-Date).AddSeconds(15)
 do {Start-Sleep -Milliseconds 500;$layout=@(Read-Layout)} while($layout.Count -ne 2 -and (Get-Date) -lt $deadline)
 if($layout.Count -ne 2){throw 'virtual monitors did not return'}
}
function Resolve-Display($Original) {
 # GDI DISPLAY numbers change on PnP restart. Require a unique active virtual
 # display with the saved size and primary/non-primary role instead.
 $match=@(Read-Layout | Where-Object {$_.width -eq $Original.width -and $_.height -eq $Original.height -and ($_.flags -band 4) -eq ($Original.flags -band 4)})
 if($match.Count -ne 1){throw 'cannot uniquely resolve virtual display after restart'}
 return $match[0]
}

$expected=@(Get-Content "$r\refresh120-wgc4\before.json" -Raw | ConvertFrom-Json)
$running=@();$errors=@()
try {
 foreach($name in @('Viewflow-Windows-Linux-IVSHMEM','ViewflowWindowsMacReceiver','ViewflowWindowsMacSource')) {
  if((Get-ScheduledTask -TaskName $name).State -eq 'Running'){$running+=$name;Stop-ScheduledTask -TaskName $name}
 }
 Start-Sleep -Seconds 3
 Restart-Vdd
 foreach($original in $expected) {
  $actual=Resolve-Display $original
  if($actual.x -ne $original.x -or $actual.y -ne $original.y -or $actual.hz -ne $original.hz){Invoke-Display @('configure',$actual.name,"$($original.x)","$($original.y)","$($original.width)","$($original.height)") | Out-Null}
  Invoke-Display @('dpi',$actual.name,'200') | Out-Null
 }
} catch {$errors+=$_.Exception.Message}
finally {
 foreach($name in $running){try {Start-ScheduledTask -TaskName $name} catch {$errors+=$_.Exception.Message}}
 @(Read-Layout) | ConvertTo-Json | Set-Content "$work\after.json"
 ConvertTo-Json -InputObject @($errors) | Set-Content "$work\errors.json"
 'done' | Set-Content "$work\done"
}
if($errors.Count){throw ($errors -join '; ')}
