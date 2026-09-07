[CmdletBinding()]
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\capture-post-vfdqa-legacy-census.ps1')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$selfTokens = $null
$selfErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $MyInvocation.MyCommand.Path, [ref]$selfTokens, [ref]$selfErrors
)
if (@($selfErrors).Count -ne 0) {
    throw ('fixture PowerShell parse failed: ' + ($selfErrors | Out-String))
}

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $Source), [ref]$tokens, [ref]$errors
)
if (@($errors).Count -ne 0) {
    throw ('PowerShell parse failed: ' + ($errors | Out-String))
}
$commands = @($ast.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst]
}, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $null -ne $_ })
$forbidden = @(
    'Enable-ScheduledTask', 'Disable-ScheduledTask', 'Register-ScheduledTask',
    'Unregister-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask',
    'Remove-Item', 'Move-Item', 'Copy-Item', 'Set-Acl', 'Stop-Process',
    'Start-Process', 'Set-Content', 'Add-Content', 'Out-File'
)
foreach ($name in $forbidden) {
    if (@($commands | Where-Object { $_ -ieq $name }).Count -ne 0) {
        throw "read-only census contains mutation command: $name"
    }
}
foreach ($required in @(
    'Get-ScheduledTask', 'Export-ScheduledTask', 'Get-ChildItem', 'Get-Acl',
    'Get-CimInstance', 'Invoke-CimMethod', 'Get-FileHash'
)) {
    if (@($commands | Where-Object { $_ -ieq $required }).Count -eq 0) {
        throw "read-only census is missing required observation: $required"
    }
}

$sourceText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Source))
foreach ($requiredText in @(
    "state = 'viewflow-post-vfdqa-windows-legacy-census'",
    "policy = 'FREEZE_ONLY_NO_MUTATION'",
    "disposition = 'FROZEN_DISABLED_UNCHANGED'",
    "disposition = 'FROZEN_PRESENT_UNCHANGED'",
    "prohibited_actions = @('ENABLE', 'REPLACE', 'DELETE')",
    'Get-CimInstance Win32_Process -Filter "Name=''viewflowd.exe''"',
    '$taskBefore.task_xml_sha256 -cne $taskAfter.task_xml_sha256',
    '$rootBefore.census_sha256 -cne $rootAfter.census_sha256'
)) {
    if (-not $sourceText.Contains($requiredText)) {
        throw "source contract is missing: $requiredText"
    }
}

# Byte-level fixture: prove that CRLF and a non-text octet are preserved by the
# Base64/length/SHA triple used by the Linux raw envelope.
$raw = [byte[]](0x7b,0x7d,0x0d,0x0a,0x80)
$base64 = [Convert]::ToBase64String($raw)
$decoded = [Convert]::FromBase64String($base64)
if ($raw.Length -ne $decoded.Length) {
    throw 'raw Base64 fixture changed bytes'
}
for ($index = 0; $index -lt $raw.Length; $index++) {
    if ($raw[$index] -ne $decoded[$index]) {
        throw 'raw Base64 fixture changed bytes'
    }
}
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $first = [BitConverter]::ToString($sha.ComputeHash($raw))
    $second = [BitConverter]::ToString($sha.ComputeHash($decoded))
} finally {
    $sha.Dispose()
}
if ($first -cne $second) {
    throw 'raw SHA fixture changed bytes'
}

Write-Output 'post-VFDQA legacy census PowerShell read-only fixture passed'
