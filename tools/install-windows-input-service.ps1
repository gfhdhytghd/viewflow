#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string] $Binary,
    [string] $ReceiverAccount = "$env:USERDOMAIN\$env:USERNAME",
    [string] $InstallRoot = "$env:ProgramFiles\ViewflowInput"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sid = ([System.Security.Principal.NTAccount]::new($ReceiverAccount)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$source = (Resolve-Path -LiteralPath $Binary).Path
$root = [IO.Path]::GetFullPath($InstallRoot)
# Service code must not be replaceable by an unelevated account.
New-Item -ItemType Directory -Path $root -Force | Out-Null
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))) {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($entry[0]),$entry[1],'ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $root -AclObject $acl
$service = Get-Service -Name ViewflowInput -ErrorAction SilentlyContinue
if ($service) { Stop-Service -Name ViewflowInput; $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15)) }
$target = Join-Path $root 'vf-input-service.exe'
if (Test-Path -LiteralPath $target) { Copy-Item -LiteralPath $target -Destination ($target + '.previous') -Force }
Copy-Item -LiteralPath $source -Destination $target -Force
$command = '"' + $target + '" service ' + $sid
if ($service) {
    $change = Invoke-CimMethod -InputObject (Get-CimInstance Win32_Service -Filter "Name='ViewflowInput'") -MethodName Change -Arguments @{PathName=$command; StartMode='Automatic'; StartName='LocalSystem'}
    if ($change.ReturnValue -ne 0) { throw "Service configuration failed: $($change.ReturnValue)" }
} else {
    New-Service -Name ViewflowInput -DisplayName 'Viewflow Windows input' -BinaryPathName $command -StartupType Automatic -Description 'Input-only worker for the paired Viewflow receiver, including the Windows lock screen.' | Out-Null
}
& sc.exe failure ViewflowInput reset= 86400 actions= restart/2000/restart/5000/restart/10000 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Service recovery configuration failed' }
Start-Service -Name ViewflowInput
Get-Service -Name ViewflowInput
Write-Host 'Launch the receiver with VIEWFLOW_WINDOWS_INPUT_SERVICE=1, or desktop-drag-windows.ps1 -LockScreenInput.'
