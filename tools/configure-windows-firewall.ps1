# Elevated application setup; does not start workers or change global firewall policy.
[CmdletBinding(SupportsShouldProcess = $true)]
param([string]$InstallRoot, [switch]$Remove, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'

function Get-ViewflowFirewallPrograms([string]$Root, [scriptblock]$Exists = { param($p) Test-Path -LiteralPath $p -PathType Leaf }) {
    # Exact installed executables, never a directory wildcard or a remote profile.
    $workers = @('viewflowd.exe', 'vf-handoff-peer.exe', 'vf-window-peer.exe', 'vf-media-peer.exe', 'vf-clipboard-peer.exe')
    $gui = [IO.Path]::GetFullPath((Join-Path $Root 'Viewflow.exe'))
    if (& $Exists $gui) { [pscustomobject]@{ Program = $gui; Protocols = @('TCP', 'UDP') } }
    foreach ($worker in $workers) {
        $path = [IO.Path]::GetFullPath((Join-Path (Join-Path $Root 'bin') $worker))
        if (& $Exists $path) { [pscustomobject]@{ Program = $path; Protocols = @('UDP') } }
    }
}
function Test-ViewflowProgramPath([string]$Candidate, [string[]]$Programs) {
    try { $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Candidate.Trim('"'))) }
    catch { return $false }
    foreach ($program in $Programs) {
        if ([string]::Equals($path, $program, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Get-ViewflowRuleName([string]$Program, [string]$Protocol) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Program.ToLowerInvariant() + '|' + $Protocol)) }
    finally { $hash.Dispose() }
    return 'Viewflow-In-' + ([BitConverter]::ToString($bytes).Replace('-', '').Substring(0, 24))
}
if ($SelfTest) {
    $root = Join-Path ([IO.Path]::GetTempPath()) 'Viewflow firewall fixture'
    $programs = @(Get-ViewflowFirewallPrograms $root { param($p) $true })
    if ($programs.Count -ne 6) { throw 'wrong worker allowlist' }
    $paths = @($programs | ForEach-Object { $_.Program })
    $handoff = Join-Path (Join-Path $root 'bin') 'vf-handoff-peer.exe'
    if (!(Test-ViewflowProgramPath ($handoff.ToUpperInvariant()) $paths)) { throw 'exact program match failed' }
    foreach ($other in @(($handoff + '.bak'), (Join-Path ([IO.Path]::GetTempPath()) 'vf-handoff-peer.exe'), '*')) {
        if (Test-ViewflowProgramPath $other $paths) { throw 'matched unrelated program' }
    }
    $rules = @($programs | ForEach-Object { $p = $_; foreach ($proto in $p.Protocols) { Get-ViewflowRuleName $p.Program $proto } })
    if ($rules.Count -ne 7 -or @($rules | Select-Object -Unique).Count -ne 7) { throw 'rule identities collide' }
    if ((Get-ViewflowRuleName $handoff 'UDP') -ne (Get-ViewflowRuleName ($handoff.ToUpperInvariant()) 'UDP')) { throw 'rule identity is not stable' }
    Write-Output 'PASS: exact installed paths, case-insensitive block matching, seven unique stable rules; no firewall changes'
    return
}
if (!$InstallRoot) { throw '-InstallRoot must identify the installed Viewflow directory' }
$InstallRoot = (Resolve-Path -LiteralPath $InstallRoot).Path
if (!(Test-Path -LiteralPath (Join-Path $InstallRoot 'bundle-manifest.json') -PathType Leaf) -or
    !(Test-Path -LiteralPath (Join-Path $InstallRoot 'Viewflow.exe') -PathType Leaf)) { throw 'expected an installed Viewflow bundle' }
if (!$WhatIfPreference) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this setup as Administrator (the app requests UAC)' }
}
Import-Module NetSecurity
$programs = @(Get-ViewflowFirewallPrograms $InstallRoot)
foreach ($entry in $programs) {
    foreach ($protocol in $entry.Protocols) {
        $name = Get-ViewflowRuleName $entry.Program $protocol
        $old = Get-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction SilentlyContinue
        if ($old -and $old.Group -ne 'Viewflow') { throw "Rule identity belongs to another application: $name" }
        if ($PSCmdlet.ShouldProcess($entry.Program, $(if ($Remove) { 'Remove Viewflow inbound rule' } else { "Allow inbound $protocol on Domain, Private and Public profiles" }))) {
            if ($old) { $old | Remove-NetFirewallRule }
            if (!$Remove) {
                New-NetFirewallRule -PolicyStore PersistentStore -Name $name -DisplayName "Viewflow $([IO.Path]::GetFileName($entry.Program)) $protocol" `
                    -Group 'Viewflow' -Program $entry.Program -Direction Inbound -Action Allow -Protocol $protocol `
                    -Profile Any -Enabled True -RemoteAddress Any -LocalAddress Any | Out-Null
            }
        }
    }
}
if (!$Remove) {
    # Windows prompt-generated Block rules override Allow rules. Remove only
    # local inbound blocks for these exact installed paths. GPO and unrelated
    # programs, other Viewflow installations, outbound rules and defaults stay intact.
    $paths = @($programs | ForEach-Object { $_.Program })
    $blocks = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Inbound -Action Block)
    foreach ($rule in $blocks) {
        foreach ($filter in @($rule | Get-NetFirewallApplicationFilter)) {
            if ((Test-ViewflowProgramPath $filter.Program $paths) -and
                $PSCmdlet.ShouldProcess($filter.Program, "Remove local inbound Block rule $($rule.Name)")) {
                $rule | Remove-NetFirewallRule
                break
            }
        }
    }
}
Write-Output 'Viewflow firewall setup complete. Other application and global firewall policies were not changed.'
