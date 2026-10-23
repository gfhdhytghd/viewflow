$ErrorActionPreference='Stop'
$r='C:\Users\wilf\Viewflow\fusion-20261007'
$work="$r\refresh120-wgc4"
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
$before=@(Read-Layout)
if($before.Count -ne 2){throw 'expected two active virtual displays'}
$target=@($before | Where-Object {$_.width -eq 6144 -and $_.height -eq 3456 -and $_.x -eq 0 -and $_.y -eq 0})
if($target.Count -ne 1 -or $target[0].hz -ne 60){throw '6K baseline changed'}
$before | ConvertTo-Json | Set-Content -Encoding UTF8 "$work\before.json"
$dpi=@{}
foreach($display in $before) {
 $value=(Invoke-Display @('dpi',$display.name)) -join ' '
 if($value -notmatch 'dpi_before=(\d+)'){throw 'DPI snapshot unavailable'}
 $dpi[$display.name]=[int]$Matches[1]
}
$dpi | ConvertTo-Json | Set-Content -Encoding UTF8 "$work\dpi-before.json"
$hash=(Get-FileHash $xml).Hash
Copy-Item $xml "$work\original.xml"
$hash | Set-Content "$work\original.sha256"
$mac=@();$changed=$false;$errors=@()
try {
 foreach($name in @('ViewflowWindowsMacReceiver','ViewflowWindowsMacSource')) {
  if((Get-ScheduledTask -TaskName $name).State -eq 'Running'){$mac+=$name;Stop-ScheduledTask -TaskName $name}
 }
 [xml]$config=Get-Content $xml
 $existing=@($config.vdd_settings.resolutions.resolution | Where-Object {$_.width -eq '6144' -and $_.height -eq '3456' -and $_.refresh_rate -eq '60'})
 if($existing.Count -ne 1){throw 'unexpected 6K configuration'}
 $extra=$existing[0].CloneNode($true);$extra.refresh_rate='120'
 $config.vdd_settings.resolutions.AppendChild($extra) | Out-Null
 $changed=$true;$config.Save($xml)
 Restart-Vdd
 $currentTarget=Resolve-Display $target[0]
 Invoke-Display @('test-refresh',$currentTarget.name,'120') | Out-Null
 Invoke-Display @('refresh',$currentTarget.name,'120') | Out-Null
 $during=@(Read-Layout);$during | ConvertTo-Json | Set-Content -Encoding UTF8 "$work\during.json"
 $actual=@($during | Where-Object {$_.name -eq $currentTarget.name})
 if($actual.Count -ne 1 -or $actual[0].hz -ne 120 -or $actual[0].width -ne 6144 -or $actual[0].height -ne 3456){throw '120 Hz mode readback mismatch'}
 'ready' | Set-Content "$work\ready"
 $deadline=(Get-Date).AddSeconds(150)
 while(-not (Test-Path "$work\finish") -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 250}
} catch {$errors+=$_.Exception.Message} finally {
 if($changed) {
  try {$currentTarget=Resolve-Display $target[0];Invoke-Display @('refresh',$currentTarget.name,'60') | Out-Null} catch {$errors+=$_.Exception.Message}
  try {Copy-Item "$work\original.xml" $xml -Force;Restart-Vdd} catch {$errors+=$_.Exception.Message}
  try {
   $current=@(Read-Layout)
   foreach($original in $before) {
    $actual=@(Resolve-Display $original)
    if($actual[0].x -ne $original.x -or $actual[0].y -ne $original.y -or $actual[0].width -ne $original.width -or $actual[0].height -ne $original.height -or $actual[0].hz -ne $original.hz) {
     Invoke-Display @('configure',$actual[0].name,"$($original.x)","$($original.y)","$($original.width)","$($original.height)") | Out-Null
    }
    $value=(Invoke-Display @('dpi',$actual[0].name)) -join ' '
    if($value -notmatch 'dpi_before=(\d+)'){throw 'DPI restoration query failed'}
    if([int]$Matches[1] -ne $dpi[$original.name]){Invoke-Display @('dpi',$actual[0].name,"$($dpi[$original.name])") | Out-Null}
   }
  } catch {$errors+=$_.Exception.Message}
 }
 foreach($name in $mac){try {Start-ScheduledTask -TaskName $name} catch {$errors+=$_.Exception.Message}}
 try {
  $after=@(Read-Layout);$after | ConvertTo-Json | Set-Content -Encoding UTF8 "$work\after.json"
  if((Get-FileHash $xml).Hash -ne $hash){throw 'original XML hash was not restored'}
  $columns=@('flags','x','y','width','height','hz')
  if(($after | Sort-Object x,y | Select-Object $columns | ConvertTo-Json -Compress) -ne ($before | Sort-Object x,y | Select-Object $columns | ConvertTo-Json -Compress)){throw 'original layout was not restored'}
 } catch {$errors+=$_.Exception.Message}
 ConvertTo-Json -InputObject @($errors) | Set-Content -Encoding UTF8 "$work\errors.json"
 'done' | Set-Content "$work\done"
}
if($errors.Count){throw ($errors -join '; ')}
