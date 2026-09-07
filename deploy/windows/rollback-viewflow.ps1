[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$TokenPath,

    [Parameter(Mandatory = $true)]
    [string]$RecoveryBundlePath,

    [string]$LinuxDeactivationProofPath,

    [string]$LinuxDeactivationTranscriptPath,

    [string]$RuntimeReceiptPath,

    [string]$DaemonExitEvidencePath,

    [string]$DaemonExitObservationPath,

    [Parameter(Mandatory = $true)]
    [string]$RecoveryForceReleaseReceiptPath,

    [switch]$ValidateOnly,

    [string]$ReceiptPath
)

$ErrorActionPreference = 'Stop'

$taskPath = '\'
$taskName = 'Viewflow Peer'
$expectedTaskName = "${taskPath}${taskName}"
$installRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA 'Programs\Viewflow')
)
$installedBinary = [System.IO.Path]::GetFullPath(
    (Join-Path $installRoot 'viewflowd.exe')
)
$installedWrapper = [System.IO.Path]::GetFullPath(
    (Join-Path $installRoot 'viewflow-client.ps1')
)
$expectedPowerShell = [System.IO.Path]::GetFullPath(
    (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentUserSid = $currentIdentity.User.Value
$stableObservationMs = 6000
$forceReleaseStableMs = 500
$forceReleaseTaskTimeoutSeconds = 30
$forceReleaseCleanupStableMs = 500
$forceReleaseTaskDescription = 'Viewflow rollback force-release one-shot'
$expectedPeer = '172.16.105.62:44119'
$expectedServerName = 'viewflow-linux'
$expectedLocalDeviceId = '00000000000000000000000000000001'
$expectedDeviceId = '00000000000000000000000000000002'
$expectedSourceDisplayId = '00000000000000000000000000000101'
$maximumJsonInteger = 9007199254740991L
$expectedCert = [System.IO.Path]::GetFullPath(
    (Join-Path $installRoot 'identity\peer.pem')
)
$expectedKey = [System.IO.Path]::GetFullPath(
    (Join-Path $installRoot 'identity\peer.key')
)
$expectedCa = [System.IO.Path]::GetFullPath(
    (Join-Path $installRoot 'identity\ca.pem')
)
$expectedOperationId = $null
$expectedReadinessReceiptPath = $null
$expectedReadinessLockPath = $null
$expectedRunningBinarySha256 = $null

function Test-JsonInteger {
    param($Value)
    $Value -is [int] -or $Value -is [long]
}

function Assert-Uint53 {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Positive
    )

    if (-not (Test-JsonInteger $Value) -or [long]$Value -lt 0 -or
        [long]$Value -gt $maximumJsonInteger -or
        ($Positive -and [long]$Value -eq 0)) {
        throw "$Name must be an unsigned JSON-safe integer"
    }
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($Value -isnot [pscustomobject]) {
        throw "$Context must be a JSON object"
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count -or
        (Compare-Object -ReferenceObject $expected -DifferenceObject $actual)) {
        throw "$Context has an unexpected property set"
    }
}

function Assert-JsonDeepEqual {
    param(
        $Left,
        $Right,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ($null -eq $Left -or $null -eq $Right) {
        if ($null -ne $Left -or $null -ne $Right) {
            throw "$Context differs"
        }
        return
    }
    if ($Left -is [pscustomobject] -or $Right -is [pscustomobject]) {
        if ($Left -isnot [pscustomobject] -or $Right -isnot [pscustomobject]) {
            throw "$Context differs in type"
        }
        $leftNames = @($Left.PSObject.Properties | ForEach-Object Name)
        Assert-ExactPropertySet -Value $Right -Names $leftNames -Context $Context
        foreach ($name in $leftNames) {
            $leftProperty = @($Left.PSObject.Properties | Where-Object {
                $_.Name -ceq $name
            })
            $rightProperty = @($Right.PSObject.Properties | Where-Object {
                $_.Name -ceq $name
            })
            Assert-JsonDeepEqual -Left $leftProperty[0].Value `
                -Right $rightProperty[0].Value -Context "$Context.$name"
        }
        return
    }
    $leftIsArray = $Left -is [Array]
    $rightIsArray = $Right -is [Array]
    if ($leftIsArray -or $rightIsArray) {
        if (-not $leftIsArray -or -not $rightIsArray -or
            $Left.Count -ne $Right.Count) {
            throw "$Context differs in array shape"
        }
        for ($index = 0; $index -lt $Left.Count; $index++) {
            Assert-JsonDeepEqual -Left $Left[$index] -Right $Right[$index] `
                -Context "$Context[$index]"
        }
        return
    }
    if (Test-JsonInteger $Left) {
        if (-not (Test-JsonInteger $Right) -or
            [long]$Left -ne [long]$Right) {
            throw "$Context differs"
        }
        return
    }
    if ($Left.GetType() -ne $Right.GetType()) {
        throw "$Context differs in type"
    }
    if ($Left -is [string]) {
        if ($Left -cne $Right) {
            throw "$Context differs"
        }
    } elseif (-not [object]::Equals($Left, $Right)) {
        throw "$Context differs"
    }
}

function Assert-LowerSha256 {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256 string"
    }
}

function Assert-ExactUtcTimestamp {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string]) {
        throw "$Name must be a string"
    }
    try {
        $timestamp = [DateTimeOffset]::ParseExact(
            [string]$Value,
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
    } catch {
        throw "$Name must use exact UTC millisecond format"
    }
    if (($timestamp - [DateTimeOffset]::UtcNow).TotalSeconds -gt 30) {
        throw "$Name is from the future"
    }
    $timestamp
}

function Get-CanonicalAbsolutePath {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$Value) -or
        -not [System.IO.Path]::IsPathRooted([string]$Value)) {
        throw "$Name must be an absolute path"
    }
    try {
        $fullPath = [System.IO.Path]::GetFullPath([string]$Value)
    } catch {
        throw "$Name is invalid"
    }
    if (-not $fullPath.Equals(
        [string]$Value,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Name must already be canonical"
    }
    $fullPath
}

function Assert-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Actual.Equals($Expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name does not match the fixed Viewflow path"
    }
}

function Assert-RegularNonReparseFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name does not exist: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must not be a reparse point: $Path"
    }
}

function Get-FileSha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Lower {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $digest = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($digest.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $digest.Dispose()
    }
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-LowerSha256 -Value $Expected -Name "$Name expected hash"
    $actual = Get-FileSha256Lower -Path $Path
    if ($actual -cne $Expected) {
        throw "$Name SHA-256 mismatch: $Path"
    }
    $actual
}

function Assert-FileHashOneOf {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($hash in $Expected) {
        Assert-LowerSha256 -Value $hash -Name "$Name allowed hash"
    }
    $actual = Get-FileSha256Lower -Path $Path
    if ($Expected -cnotcontains $actual) {
        throw "$Name SHA-256 is not an allowed transaction state: $Path"
    }
    $actual
}

function Read-FileBytesExclusive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-RegularNonReparseFile -Path $Path -Name $Name
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::None
    )
    try {
        $memory = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($memory)
            return ,$memory.ToArray()
        } finally {
            $memory.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Read-StrictUtf8JsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-RegularNonReparseFile -Path $Path -Name $Name
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $bytes = Read-FileBytesExclusive -Path $Path -Name $Name
    if ($bytes.Length -eq 0) {
        throw "$Name is empty: $Path"
    }
    try {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $encoding.GetString($bytes)
        $value = $text | ConvertFrom-Json
    } catch {
        throw "$Name is not strict UTF-8 JSON: $Path"
    }
    if ($null -eq $value) {
        throw "$Name is empty: $Path"
    }
    [pscustomobject]@{
        Value = $value
        Sha256 = Get-BytesSha256Lower -Bytes $bytes
    }
}

function Assert-PairwiseDistinctPaths {
    param(
        [Parameter(Mandatory = $true)][hashtable[]]$Bindings
    )

    for ($left = 0; $left -lt $Bindings.Count; $left++) {
        for ($right = $left + 1; $right -lt $Bindings.Count; $right++) {
            if ($Bindings[$left].Path.Equals(
                $Bindings[$right].Path,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw ('Rollback paths must be pairwise distinct: {0} and {1}' -f @(
                    $Bindings[$left].Name,
                    $Bindings[$right].Name
                ))
            }
        }
    }
}

function Get-FileLinkIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq ('ViewflowRollback.NativeFile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ViewflowRollback {
    [StructLayout(LayoutKind.Sequential)]
    public struct FileTime { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)]
    public struct ByHandleFileInformation {
        public uint FileAttributes;
        public FileTime CreationTime;
        public FileTime LastAccessTime;
        public FileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }
    public static class NativeFile {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out ByHandleFileInformation information);
    }
}
'@
    }
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $information = New-Object ViewflowRollback.ByHandleFileInformation
        if (-not [ViewflowRollback.NativeFile]::GetFileInformationByHandle(
            $stream.SafeFileHandle,
            [ref]$information
        )) {
            throw "$Name file identity could not be read"
        }
        if ([uint32]$information.NumberOfLinks -ne 1) {
            throw "$Name must have exactly one hard link"
        }
        '{0:x8}:{1:x8}{2:x8}' -f @(
            [uint32]$information.VolumeSerialNumber,
            [uint32]$information.FileIndexHigh,
            [uint32]$information.FileIndexLow
        )
    } finally {
        $stream.Dispose()
    }
}

function Assert-DistinctFileIdentities {
    param([Parameter(Mandatory = $true)][hashtable[]]$Bindings)

    $identities = @{}
    foreach ($binding in $Bindings) {
        Assert-RegularNonReparseFile -Path $binding.Path -Name $binding.Name
        Assert-OwnerOnlyFileSecurity -Path $binding.Path -Name $binding.Name
        $identity = Get-FileLinkIdentity -Path $binding.Path -Name $binding.Name
        if ($identities.ContainsKey($identity)) {
            throw ('Rollback files must not alias: {0} and {1}' -f @(
                $identities[$identity],
                $binding.Name
            ))
        }
        $identities[$identity] = $binding.Name
    }
}

function Read-PrivateFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-RegularNonReparseFile -Path $Path -Name $Name
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $bytes = Read-FileBytesExclusive -Path $Path -Name $Name
    [pscustomobject]@{
        Bytes = $bytes
        Sha256 = Get-BytesSha256Lower -Bytes $bytes
    }
}

function Open-PrivateFileClaim {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    Assert-RegularNonReparseFile -Path $Path -Name $Name
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $memory = New-Object IO.MemoryStream
        try {
            $stream.CopyTo($memory)
            $actualSha256 = Get-BytesSha256Lower -Bytes $memory.ToArray()
        } finally {
            $memory.Dispose()
        }
        if ($actualSha256 -cne $ExpectedSha256) {
            throw "$Name changed before the exclusive recovery claim"
        }
        $stream.Position = 0
        [pscustomobject]@{
            Path = $Path
            Name = $Name
            Sha256 = $actualSha256
            Stream = $stream
        }
        $stream = $null
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Assert-BaseNameBinding {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -isnot [string] -or
        [string]$Value -cne [System.IO.Path]::GetFileName($Path)) {
        throw "$Name does not match the exact file name"
    }
}

function Read-VerifiedUtf16TaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $bytes = Read-FileBytesExclusive -Path $Path -Name 'Rollback backup task XML'
    $actualSha256 = Get-BytesSha256Lower -Bytes $bytes
    if ($actualSha256 -cne $ExpectedSha256) {
        throw 'Rollback backup task XML changed after validation'
    }
    if ($bytes.Length -lt 4 -or $bytes[0] -ne 0xff -or $bytes[1] -ne 0xfe) {
        throw 'Rollback backup task XML must be UTF-16LE with a BOM'
    }
    try {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
        $encoding.GetString($bytes, 2, $bytes.Length - 2)
    } catch {
        throw 'Rollback backup task XML is not strict UTF-16LE'
    }
}

function Resolve-AccountSid {
    param(
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Account)) {
        throw "$Context account is empty"
    }
    try {
        if ($Account -match '^S-1-') {
            return ([System.Security.Principal.SecurityIdentifier]$Account).Value
        }
        $ntAccount = New-Object -TypeName System.Security.Principal.NTAccount `
            -ArgumentList $Account
        return $ntAccount.Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        throw "$Context account cannot be resolved: $Account"
    }
}

function Assert-OwnerOnlyFileSecurity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $security = Get-Acl -LiteralPath $Path
    $ownerSid = Resolve-AccountSid -Account ([string]$security.Owner) `
        -Context "$Name owner"
    if ($ownerSid -cne $currentUserSid) {
        throw "$Name owner does not match the current user SID"
    }
    if (-not $security.AreAccessRulesProtected) {
        throw "$Name ACL must have inheritance disabled"
    }
    $rules = @($security.GetAccessRules(
        $true,
        $false,
        [System.Security.Principal.SecurityIdentifier]
    ))
    if ($rules.Count -ne 1) {
        throw "$Name ACL must contain exactly one explicit access rule"
    }
    $rule = $rules[0]
    if ($rule.IdentityReference.Value -cne $currentUserSid -or
        $rule.AccessControlType -ne
            [System.Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne
            [System.Security.AccessControl.FileSystemRights]::FullControl) {
        throw "$Name ACL is not current-SID-only FullControl"
    }
}

function Split-WindowsCommandLine {
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    $arguments = New-Object System.Collections.Generic.List[string]
    $index = 0
    while ($index -lt $CommandLine.Length) {
        while ($index -lt $CommandLine.Length -and
            [char]::IsWhiteSpace($CommandLine[$index])) {
            $index++
        }
        if ($index -ge $CommandLine.Length) { break }
        $builder = New-Object System.Text.StringBuilder
        $quoted = $false
        while ($index -lt $CommandLine.Length) {
            $slashes = 0
            while ($index -lt $CommandLine.Length -and
                $CommandLine[$index] -eq '\') {
                $slashes++
                $index++
            }
            if ($index -lt $CommandLine.Length -and
                $CommandLine[$index] -eq '"') {
                $null = $builder.Append('\' * [Math]::Floor($slashes / 2))
                if (($slashes % 2) -eq 0) {
                    $quoted = -not $quoted
                } else {
                    $null = $builder.Append('"')
                }
                $index++
                continue
            }
            $null = $builder.Append('\' * $slashes)
            if ($index -ge $CommandLine.Length -or
                (-not $quoted -and [char]::IsWhiteSpace($CommandLine[$index]))) {
                break
            }
            $null = $builder.Append($CommandLine[$index])
            $index++
        }
        if ($quoted) {
            throw 'Command line contains an unterminated quote'
        }
        $arguments.Add($builder.ToString())
    }
    $arguments.ToArray()
}

function Assert-ExactArguments {
    param(
        [Parameter(Mandatory = $true)][string[]]$Actual,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Context,
        [string[]]$PathIndexes = @()
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Context has an unexpected argument count"
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        $comparison = if ($PathIndexes -contains [string]$index) {
            [StringComparison]::OrdinalIgnoreCase
        } else {
            [StringComparison]::Ordinal
        }
        if (-not ([string]$Actual[$index]).Equals(
            [string]$Expected[$index],
            $comparison
        )) {
            throw "$Context has an unexpected token at index $index"
        }
    }
}

function Assert-ActionArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actual = @(Split-WindowsCommandLine -CommandLine $Arguments)
    $expected = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden', '-File', $installedWrapper
    )
    if ($actual.Count -eq ($expected.Count + 6)) {
        if ([string]::IsNullOrWhiteSpace($expectedOperationId)) {
            throw "$Context readiness arguments lack an operation binding"
        }
        $script:expectedReadinessReceiptPath = Get-CanonicalAbsolutePath `
            -Value ([string]$actual[9]) -Name "$Context readiness receipt path"
        $script:expectedReadinessLockPath = Get-CanonicalAbsolutePath `
            -Value ([string]$actual[11]) -Name "$Context readiness lock path"
        if ($script:expectedReadinessReceiptPath.Equals(
            $script:expectedReadinessLockPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "$Context readiness paths must be distinct"
        }
        $expected += @(
            '-ReadinessReceiptPath', $script:expectedReadinessReceiptPath,
            '-ReadinessLockPath', $script:expectedReadinessLockPath,
            '-OperationId', $expectedOperationId
        )
    }
    Assert-ExactArguments -Actual $actual -Expected $expected -Context $Context `
        -PathIndexes @('7', '9', '11')
}

function Assert-TaskSettingsContract {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ([string]$Settings.MultipleInstances -cne 'IgnoreNew' -or
        $null -eq $Settings.Enabled -or
        -not [Convert]::ToBoolean($Settings.Enabled) -or
        $null -eq $Settings.DisallowStartIfOnBatteries -or
        [Convert]::ToBoolean($Settings.DisallowStartIfOnBatteries) -or
        $null -eq $Settings.StopIfGoingOnBatteries -or
        [Convert]::ToBoolean($Settings.StopIfGoingOnBatteries) -or
        $null -eq $Settings.AllowHardTerminate -or
        -not [Convert]::ToBoolean($Settings.AllowHardTerminate) -or
        $null -eq $Settings.RestartCount -or
        [int]$Settings.RestartCount -ne 0) {
        throw "$Context settings do not match the fixed task contract"
    }
    $executionTimeLimit = [string]$Settings.ExecutionTimeLimit
    if ($executionTimeLimit -cne 'PT0S' -and
        $executionTimeLimit -cne [TimeSpan]::Zero.ToString()) {
        throw "$Context execution time must be unlimited"
    }
}

function Assert-NoTaskTriggers {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Context
    )

    # PowerShell 5.1 can report an inline filtered expression incorrectly when
    # ScheduledTasks exposes Triggers as $null. Materialize it before counting.
    $taskTriggers = @($Task.Triggers | Where-Object { $null -ne $_ })
    if ($taskTriggers.Count -ne 0) {
        throw "$Context must not have automatic triggers"
    }
}

function Assert-LegacyOrNoTaskTriggers {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $taskTriggers = @($Task.Triggers | Where-Object { $null -ne $_ })
    if ($taskTriggers.Count -eq 0) {
        return
    }
    if ($taskTriggers.Count -ne 1) {
        throw "$Context has an invalid automatic-trigger count"
    }
    $trigger = $taskTriggers[0]
    $triggerClass = if ($null -eq $trigger.CimClass) {
        $null
    } else {
        [string]$trigger.CimClass.CimClassName
    }
    if ($triggerClass -cne 'MSFT_TaskLogonTrigger') {
        throw "$Context legacy trigger is not a LogonTrigger"
    }
    $enabledProperty = $trigger.PSObject.Properties['Enabled']
    if ($null -ne $enabledProperty -and $null -ne $enabledProperty.Value -and
        ($enabledProperty.Value -isnot [bool] -or
            -not [bool]$enabledProperty.Value)) {
        throw "$Context legacy LogonTrigger is disabled or malformed"
    }
    $userProperty = $trigger.PSObject.Properties['UserId']
    if ($null -eq $userProperty -or $userProperty.Value -isnot [string] -or
        (Resolve-AccountSid -Account ([string]$userProperty.Value) `
            -Context "$Context legacy LogonTrigger") -cne $currentUserSid) {
        throw "$Context legacy LogonTrigger user does not match the current user"
    }
}

function Assert-ScheduledTaskContract {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [ValidateSet('Running', 'Ready')][string]$RequiredState
    )

    if ([string]$Task.State -cne $RequiredState) {
        throw "$expectedTaskName must be $RequiredState"
    }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) {
        throw "$expectedTaskName must have exactly one action"
    }
    $actionExecutable = Get-CanonicalAbsolutePath -Value (
        [Environment]::ExpandEnvironmentVariables(
            ([string]$actions[0].Execute).Trim('"')
        )
    ) -Name 'Scheduled-task action executable'
    Assert-SamePath -Actual $actionExecutable -Expected $expectedPowerShell `
        -Name 'Scheduled-task action executable'
    Assert-ActionArguments -Arguments ([string]$actions[0].Arguments) `
        -Context 'Scheduled-task action'
    $workingDirectory = Get-CanonicalAbsolutePath `
        -Value ([string]$actions[0].WorkingDirectory) `
        -Name 'Scheduled-task working directory'
    Assert-SamePath -Actual $workingDirectory -Expected $installRoot `
        -Name 'Scheduled-task working directory'

    $taskSid = Resolve-AccountSid -Account ([string]$Task.Principal.UserId) `
        -Context 'Scheduled-task principal'
    if ($taskSid -cne $currentUserSid -or
        [string]$Task.Principal.LogonType -cne 'Interactive' -or
        [string]$Task.Principal.RunLevel -cne 'Limited') {
        throw "$expectedTaskName principal is not the current interactive limited user"
    }

    Assert-NoTaskTriggers -Task $Task -Context $expectedTaskName
    Assert-TaskSettingsContract -Settings $Task.Settings `
        -Context $expectedTaskName
}

function Assert-RestoredScheduledTaskContract {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [ValidateSet('Running', 'Ready')][string]$RequiredState = 'Ready',
        [switch]$AllowLegacyLogonTrigger
    )

    if ([string]$Task.State -cne $RequiredState) {
        throw "$expectedTaskName must be $RequiredState"
    }
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) {
        throw "$expectedTaskName must have exactly one restored action"
    }
    $actionExecutable = Get-CanonicalAbsolutePath -Value (
        [Environment]::ExpandEnvironmentVariables(
            ([string]$actions[0].Execute).Trim('"')
        )
    ) -Name 'Restored scheduled-task action executable'
    Assert-SamePath -Actual $actionExecutable -Expected $expectedPowerShell `
        -Name 'Restored scheduled-task action executable'
    Assert-ActionArguments -Arguments ([string]$actions[0].Arguments) `
        -Context 'Restored scheduled-task action'

    $workingDirectory = Get-CanonicalAbsolutePath `
        -Value ([string]$actions[0].WorkingDirectory) `
        -Name 'Restored scheduled-task working directory'
    Assert-SamePath -Actual $workingDirectory -Expected $installRoot `
        -Name 'Restored scheduled-task working directory'

    $taskSid = Resolve-AccountSid -Account ([string]$Task.Principal.UserId) `
        -Context 'Restored scheduled-task principal'
    if ($taskSid -cne $currentUserSid -or
        [string]$Task.Principal.LogonType -cne 'Interactive' -or
        [string]$Task.Principal.RunLevel -cne 'Limited') {
        throw 'Restored task principal is not the current interactive limited user'
    }
    if ($AllowLegacyLogonTrigger) {
        Assert-LegacyOrNoTaskTriggers -Task $Task `
            -Context 'Restored scheduled task'
    } else {
        Assert-NoTaskTriggers -Task $Task -Context 'Restored scheduled task'
    }
    Assert-TaskSettingsContract -Settings $Task.Settings `
        -Context 'Restored scheduled task'
}

function Assert-TaskXmlContract {
    param(
        [Parameter(Mandatory = $true)][string]$Xml,
        [switch]$AllowLegacyLogonTrigger
    )

    $settings = [System.Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = $null
    $stringReader = $null
    try {
        $stringReader = New-Object System.IO.StringReader($Xml)
        $reader = [System.Xml.XmlReader]::Create($stringReader, $settings)
        $document = [System.Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $stringReader) {
            $stringReader.Dispose()
        }
    }

    if ($document.DocumentElement.LocalName -cne 'Task' -or
        $document.DocumentElement.NamespaceURI -cne
            'http://schemas.microsoft.com/windows/2004/02/mit/task') {
        throw 'Backup task XML has an invalid root element'
    }
    $namespace = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespace.AddNamespace(
        't',
        'http://schemas.microsoft.com/windows/2004/02/mit/task'
    )
    $uriNodes = @($document.SelectNodes(
        '/t:Task/t:RegistrationInfo/t:URI',
        $namespace
    ))
    if ($uriNodes.Count -ne 1 -or
        [string]$uriNodes[0].InnerText -cne $expectedTaskName) {
        throw 'Backup task XML URI does not match the fixed task name'
    }
    $triggerContainers = @($document.SelectNodes(
        '/t:Task/t:Triggers', $namespace
    ))
    if ($triggerContainers.Count -ne 1) {
        throw 'Backup task XML must contain exactly one Triggers container'
    }
    $triggers = @($triggerContainers[0].SelectNodes('*'))
    if ($triggers.Count -ne 0) {
        if (-not $AllowLegacyLogonTrigger -or $triggers.Count -ne 1) {
            throw 'Backup task XML has an invalid automatic-trigger count'
        }
        $trigger = $triggers[0]
        if ($trigger.LocalName -cne 'LogonTrigger' -or
            $trigger.NamespaceURI -cne
                'http://schemas.microsoft.com/windows/2004/02/mit/task' -or
            $trigger.Attributes.Count -ne 0) {
            throw 'Backup task XML legacy trigger is not an exact LogonTrigger'
        }
        $children = @($trigger.SelectNodes('*'))
        $triggerUsers = @($trigger.SelectNodes('t:UserId', $namespace))
        $triggerEnabled = @($trigger.SelectNodes('t:Enabled', $namespace))
        if ($triggerUsers.Count -ne 1 -or $triggerEnabled.Count -gt 1 -or
            $children.Count -ne (1 + $triggerEnabled.Count)) {
            throw 'Backup task XML legacy LogonTrigger has an unexpected child set'
        }
        foreach ($child in $children) {
            if ($child.Attributes.Count -ne 0 -or
                @($child.SelectNodes('*')).Count -ne 0) {
                throw 'Backup task XML legacy LogonTrigger child is malformed'
            }
        }
        if ($triggerEnabled.Count -eq 1 -and
            [string]$triggerEnabled[0].InnerText -cne 'true') {
            throw 'Backup task XML legacy LogonTrigger must be enabled'
        }
        if ((Resolve-AccountSid `
            -Account ([string]$triggerUsers[0].InnerText) `
            -Context 'Backup task XML legacy LogonTrigger') -cne
                $currentUserSid) {
            throw 'Backup task XML legacy LogonTrigger user does not match the current user'
        }
    }
    $actionsNodes = @($document.SelectNodes('/t:Task/t:Actions', $namespace))
    if ($actionsNodes.Count -ne 1) {
        throw 'Backup task XML must contain exactly one Actions container'
    }
    $actionNodes = @($actionsNodes[0].SelectNodes('*'))
    if ($actionNodes.Count -ne 1 -or $actionNodes[0].LocalName -cne 'Exec') {
        throw 'Backup task XML must contain exactly one action and it must be Exec'
    }
    $execNode = $actionNodes[0]
    $command = $execNode.SelectSingleNode('t:Command', $namespace)
    $arguments = $execNode.SelectSingleNode('t:Arguments', $namespace)
    $workingDirectory = $execNode.SelectSingleNode(
        't:WorkingDirectory',
        $namespace
    )
    if ($null -eq $command -or $null -eq $arguments) {
        throw 'Backup task XML action is incomplete'
    }
    $commandPath = Get-CanonicalAbsolutePath -Value (
        [Environment]::ExpandEnvironmentVariables(
            ([string]$command.InnerText).Trim('"')
        )
    ) -Name 'Backup task XML command'
    Assert-SamePath -Actual $commandPath -Expected $expectedPowerShell `
        -Name 'Backup task XML command'
    Assert-ActionArguments -Arguments ([string]$arguments.InnerText) `
        -Context 'Backup task XML action'
    if ($null -eq $workingDirectory) {
        throw 'Backup task XML working directory is missing'
    }
    $workingPath = Get-CanonicalAbsolutePath `
        -Value ([string]$workingDirectory.InnerText) `
        -Name 'Backup task XML working directory'
    Assert-SamePath -Actual $workingPath -Expected $installRoot `
        -Name 'Backup task XML working directory'

    $principalNodes = @($document.SelectNodes(
        '/t:Task/t:Principals/t:Principal',
        $namespace
    ))
    if ($principalNodes.Count -ne 1) {
        throw 'Backup task XML must contain exactly one principal'
    }
    $principalId = [string]$principalNodes[0].GetAttribute('id')
    $actionsContext = [string]$actionsNodes[0].GetAttribute('Context')
    if ([string]::IsNullOrWhiteSpace($principalId) -or
        $actionsContext -cne $principalId) {
        throw 'Backup task XML action context does not match the principal ID'
    }
    $userId = $principalNodes[0].SelectSingleNode('t:UserId', $namespace)
    $logonType = $principalNodes[0].SelectSingleNode('t:LogonType', $namespace)
    $runLevel = @($principalNodes[0].SelectNodes('t:RunLevel', $namespace))
    if ($null -eq $userId -or $null -eq $logonType -or
        $runLevel.Count -gt 1 -or
        (Resolve-AccountSid -Account ([string]$userId.InnerText) `
            -Context 'Backup task XML principal') -cne $currentUserSid -or
        [string]$logonType.InnerText -cne 'InteractiveToken' -or
        ($runLevel.Count -eq 1 -and
            [string]$runLevel[0].InnerText -cne 'LeastPrivilege')) {
        throw 'Backup task XML principal is not the current interactive limited user'
    }

    $settingsNode = $document.SelectSingleNode('/t:Task/t:Settings', $namespace)
    if ($null -eq $settingsNode) {
        throw 'Backup task XML settings are missing'
    }
    $requiredSettings = @{
        MultipleInstancesPolicy = 'IgnoreNew'
        DisallowStartIfOnBatteries = 'false'
        StopIfGoingOnBatteries = 'false'
        ExecutionTimeLimit = 'PT0S'
    }
    foreach ($settingName in $requiredSettings.Keys) {
        $settingNodes = @($settingsNode.SelectNodes("t:$settingName", $namespace))
        if ($settingNodes.Count -ne 1 -or
            [string]$settingNodes[0].InnerText -cne $requiredSettings[$settingName]) {
            throw "Backup task XML setting is invalid: $settingName"
        }
    }
    foreach ($optionalTrueSetting in @('AllowHardTerminate', 'Enabled')) {
        $optionalNodes = @($settingsNode.SelectNodes(
            "t:$optionalTrueSetting", $namespace
        ))
        if ($optionalNodes.Count -gt 1 -or
            ($optionalNodes.Count -eq 1 -and
                [string]$optionalNodes[0].InnerText -cne 'true')) {
            throw "Backup task XML setting is invalid: $optionalTrueSetting"
        }
    }
    if ($null -ne $settingsNode.SelectSingleNode('t:RestartOnFailure', $namespace)) {
        throw 'Backup task XML must not contain a restart-on-failure policy'
    }
}

function Get-ExactInstalledViewflowProcesses {
    @(
        Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'" |
            Where-Object {
                $_.ExecutablePath -and
                [System.IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals(
                    $installedBinary,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
}

function Get-ProcessOwnerSid {
    param([Parameter(Mandatory = $true)]$Process)

    $owner = Invoke-CimMethod -InputObject $Process -MethodName GetOwnerSid
    if ([long]$owner.ReturnValue -ne 0 -or
        [string]::IsNullOrWhiteSpace([string]$owner.Sid)) {
        throw "Cannot resolve owner SID for process $($Process.ProcessId)"
    }
    [string]$owner.Sid
}

function Assert-ExpectedViewflowProcess {
    param([Parameter(Mandatory = $true)]$Process)

    if ($null -eq $Process.SessionId -or [long]$Process.SessionId -ne 1) {
        throw 'The exact installed Viewflow process must run in Session 1'
    }
    if ((Get-ProcessOwnerSid -Process $Process) -cne $currentUserSid) {
        throw 'The exact installed Viewflow process must run as the current user'
    }
    $actual = @(Split-WindowsCommandLine -CommandLine ([string]$Process.CommandLine))
    $expected = @(
        $installedBinary, 'connect',
        '--peer', $expectedPeer,
        '--server-name', $expectedServerName,
        '--cert', $expectedCert,
        '--key', $expectedKey,
        '--ca', $expectedCa,
        '--input-backend', 'native',
        '--device-id', $expectedDeviceId,
        '--probe-interval-ms', '1000',
        '--probe-timeout-ms', '3000'
    )
    if ($actual.Count -eq ($expected.Count + 6)) {
        if ([string]::IsNullOrWhiteSpace($expectedOperationId)) {
            throw 'Viewflow readiness arguments are not bound to a rollback operation'
        }
        foreach ($pathIndex in @(21, 23)) {
            $path = Get-CanonicalAbsolutePath -Value ([string]$actual[$pathIndex]) `
                -Name 'Viewflow readiness path'
            if (-not $path.Equals(
                [string]$actual[$pathIndex],
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'Viewflow readiness path is not canonical'
            }
        }
        $expected += @(
            '--readiness-receipt', $expectedReadinessReceiptPath,
            '--readiness-lock', $expectedReadinessLockPath,
            '--operation-id', $expectedOperationId
        )
    }
    Assert-ExactArguments -Actual $actual -Expected $expected `
        -Context 'Viewflow process command line' `
        -PathIndexes @('0', '7', '9', '11', '21', '23')
}

function Assert-CurrentRollbackBoundary {
    param([switch]$AllowLegacyLogonTrigger)

    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    $taskState = [string]$task.State
    if ($taskState -cne 'Running' -and $taskState -cne 'Ready') {
        throw "$expectedTaskName must be Ready or Running before rollback"
    }
    Assert-RestoredScheduledTaskContract -Task $task `
        -RequiredState $taskState `
        -AllowLegacyLogonTrigger:$AllowLegacyLogonTrigger
    $processes = @(Get-ExactInstalledViewflowProcesses)
    if ($taskState -ceq 'Ready') {
        if ($processes.Count -ne 0) {
            throw 'A Ready Viewflow task must have zero exact installed processes'
        }
        return [pscustomobject]@{
            TaskState = 'Ready'
            Process = $null
        }
    }
    if ($processes.Count -ne 1) {
        throw 'A Running Viewflow task must have exactly one installed process'
    }
    if ([string]::IsNullOrWhiteSpace($expectedRunningBinarySha256) -or
        (Get-FileSha256Lower -Path $installedBinary) -cne
            $expectedRunningBinarySha256) {
        throw 'The Running Viewflow task does not use the manifest candidate binary'
    }
    Assert-ExpectedViewflowProcess -Process $processes[0]
    [pscustomobject]@{
        TaskState = 'Running'
        Process = $processes[0]
    }
}

function Wait-ReadyInactiveBoundary {
    param([Parameter(Mandatory = $true)][string]$Context)

    $wait = [Diagnostics.Stopwatch]::StartNew()
    $stableSinceMs = $null
    do {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        $processes = @(Get-ExactInstalledViewflowProcesses)
        if ([string]$task.State -ceq 'Ready' -and $processes.Count -eq 0) {
            if ($null -eq $stableSinceMs) {
                $stableSinceMs = $wait.ElapsedMilliseconds
            }
            if (($wait.ElapsedMilliseconds - $stableSinceMs) -ge
                $stableObservationMs) {
                return $task
            }
        } else {
            $stableSinceMs = $null
        }
        Start-Sleep -Milliseconds 100
    } while ($wait.ElapsedMilliseconds -lt 20000)
    throw "$Context did not remain Ready with zero exact processes for $stableObservationMs ms"
}

function Restore-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $parent = [System.IO.Path]::GetDirectoryName($Destination)
    $temporary = Join-Path $parent (
        '.{0}.{1}.rollback.tmp' -f @(
            [System.IO.Path]::GetFileName($Destination),
            [Guid]::NewGuid().ToString('N')
        )
    )
    $replacementBackup = Join-Path $parent (
        '.{0}.{1}.rollback.replace-backup' -f @(
            [System.IO.Path]::GetFileName($Destination),
            [Guid]::NewGuid().ToString('N')
        )
    )
    $failedReplacement = Join-Path $parent (
        '.{0}.{1}.rollback.failed-replacement' -f @(
            [System.IO.Path]::GetFileName($Destination),
            [Guid]::NewGuid().ToString('N')
        )
    )
    Assert-RegularNonReparseFile -Path $Source -Name 'Rollback source artifact'
    Assert-RegularNonReparseFile -Path $Destination `
        -Name 'Rollback destination artifact'
    $originalDestinationSha256 = Get-FileSha256Lower -Path $Destination
    $replacementCommitted = $false
    $failedReplacementCreated = $false
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary
        $null = Assert-FileHash -Path $temporary -Expected $ExpectedSha256 `
            -Name 'Prepared rollback artifact'
        foreach ($reservedPath in @($replacementBackup, $failedReplacement)) {
            if (Test-Path -LiteralPath $reservedPath) {
                throw "Rollback replacement backup path already exists: $reservedPath"
            }
        }
        # Windows PowerShell 5.1/.NET Framework rejects a null File.Replace
        # backup path on supported production hosts. The same-directory unique
        # path also retains the pre-replacement destination until the new file
        # and the durable manifest backup have both been revalidated.
        [System.IO.File]::Replace(
            $temporary,
            $Destination,
            $replacementBackup,
            $true
        )
        $replacementCommitted = $true
        $null = Assert-FileHash -Path $Destination -Expected $ExpectedSha256 `
            -Name 'Restored artifact'
        $null = Assert-FileHash -Path $Source -Expected $ExpectedSha256 `
            -Name 'Durable rollback source artifact'
        Remove-Item -LiteralPath $replacementBackup -Force
        $replacementCommitted = $false
    } catch {
        $replacementFailure = $_
        if ($replacementCommitted -and
            (Test-Path -LiteralPath $replacementBackup -PathType Leaf)) {
            try {
                if (Test-Path -LiteralPath $failedReplacement) {
                    throw 'Rollback recovery backup path was unexpectedly occupied'
                }
                [System.IO.File]::Replace(
                    $replacementBackup,
                    $Destination,
                    $failedReplacement,
                    $true
                )
                $failedReplacementCreated = $true
                $replacementCommitted = $false
                $null = Assert-FileHash -Path $Destination `
                    -Expected $originalDestinationSha256 `
                    -Name 'Recovered pre-rollback destination'
                $null = Assert-FileHash -Path $Source -Expected $ExpectedSha256 `
                    -Name 'Durable rollback source artifact after recovery'
                Remove-Item -LiteralPath $failedReplacement -Force
                $failedReplacementCreated = $false
            } catch {
                throw (
                    'Rollback artifact replacement failed: {0}; restoring the ' +
                    'pre-rollback destination also failed: {1}'
                ) -f @(
                    $replacementFailure.Exception.Message,
                    $_.Exception.Message
                )
            }
        }
        throw $replacementFailure
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        if ($failedReplacementCreated -and
            (Test-Path -LiteralPath $failedReplacement)) {
            Remove-Item -LiteralPath $failedReplacement -Force
        }
    }
}

function New-OwnerOnlyFileSecurity {
    $sid = [System.Security.Principal.SecurityIdentifier]::new($currentUserSid)
    $security = [System.Security.AccessControl.FileSecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $security.AddAccessRule($rule)
    $security
}

function Assert-NewOutputPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $canonical = Get-CanonicalAbsolutePath -Value $Path -Name 'Receipt path'
    if (Test-Path -LiteralPath $canonical) {
        throw "Receipt path already exists: $canonical"
    }
    $parent = [System.IO.Path]::GetDirectoryName($canonical)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Receipt parent does not exist: $parent"
    }
    if (((Get-Item -LiteralPath $parent -Force).Attributes -band
        [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Receipt parent must not be a reparse point'
    }
    $canonical
}

function Write-OwnerOnlyCreateOnceJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = ($Value | ConvertTo-Json -Depth 8) + "`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $parent = [System.IO.Path]::GetDirectoryName($Path)
    $leaf = [System.IO.Path]::GetFileName($Path)
    $temporary = Join-Path $parent ('.{0}.{1}.tmp' -f $leaf, [Guid]::NewGuid())
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $temporary,
            [System.IO.FileMode]::CreateNew,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough,
            (New-OwnerOnlyFileSecurity)
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [System.IO.File]::Move($temporary, $Path)
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    Assert-OwnerOnlyFileSecurity -Path $Path -Name 'Rollback receipt'
}

function Assert-RecoveryBundleContract {
    param(
        [Parameter(Mandatory = $true)]$Bundle,
        [Parameter(Mandatory = $true)][string]$RollbackMode,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$ManifestSha256,
        [Parameter(Mandatory = $true)][string]$TokenSha256,
        [string]$ProofSha256,
        [string]$TranscriptSha256,
        [string]$RuntimeReceiptSha256,
        [string]$DaemonExitEvidenceSha256,
        [string]$ObservationSha256
    )

    $bundleKeys = @(
        'schema_version', 'state', 'rollback_mode', 'operation_id',
        'rollback_manifest_sha256',
        'rollback_token_sha256', 'created_at_utc'
    )
    if ($RollbackMode -ceq 'bootstrap-v1.3') {
        $bundleKeys += @(
            'linux_deactivation_proof_file_name',
            'linux_deactivation_proof_sha256',
            'linux_deactivation_transcript_file_name',
            'linux_deactivation_transcript_sha256'
        )
    } else {
        $bundleKeys += @(
            'runtime_receipt_file_name', 'runtime_receipt_sha256',
            'daemon_exit_evidence_file_name',
            'daemon_exit_evidence_sha256',
            'daemon_exit_observation_file_name',
            'daemon_exit_observation_sha256'
        )
    }
    Assert-ExactPropertySet -Value $Bundle -Context 'Recovery bundle' `
        -Names $bundleKeys
    if ($Bundle.schema_version -isnot [int] -or
        $Bundle.schema_version -ne 1 -or
        $Bundle.state -isnot [string] -or
        $Bundle.state -cne 'viewflow-cross-host-recovery-authorized' -or
        $Bundle.rollback_mode -isnot [string] -or
        $Bundle.rollback_mode -cne $RollbackMode -or
        $Bundle.operation_id -isnot [string] -or
        $Bundle.operation_id -cne $OperationId) {
        throw 'Recovery bundle schema, state, or operation binding is invalid'
    }
    $hashBindings = @(
        @{ Value = $Bundle.rollback_manifest_sha256; Expected = $ManifestSha256; Name = 'rollback_manifest_sha256' },
        @{ Value = $Bundle.rollback_token_sha256; Expected = $TokenSha256; Name = 'rollback_token_sha256' }
    )
    if ($RollbackMode -ceq 'bootstrap-v1.3') {
        $hashBindings += @(
            @{ Value = $Bundle.linux_deactivation_proof_sha256; Expected = $ProofSha256; Name = 'linux_deactivation_proof_sha256' },
            @{ Value = $Bundle.linux_deactivation_transcript_sha256; Expected = $TranscriptSha256; Name = 'linux_deactivation_transcript_sha256' }
        )
    } else {
        $hashBindings += @(
            @{ Value = $Bundle.runtime_receipt_sha256; Expected = $RuntimeReceiptSha256; Name = 'runtime_receipt_sha256' },
            @{ Value = $Bundle.daemon_exit_evidence_sha256; Expected = $DaemonExitEvidenceSha256; Name = 'daemon_exit_evidence_sha256' },
            @{ Value = $Bundle.daemon_exit_observation_sha256; Expected = $ObservationSha256; Name = 'daemon_exit_observation_sha256' }
        )
    }
    foreach ($hashBinding in $hashBindings) {
        Assert-LowerSha256 -Value $hashBinding.Value `
            -Name "Recovery bundle $($hashBinding.Name)"
        if ([string]$hashBinding.Value -cne [string]$hashBinding.Expected) {
            throw "Recovery bundle $($hashBinding.Name) does not match the claimed raw bytes"
        }
    }
    if ($RollbackMode -ceq 'bootstrap-v1.3') {
        Assert-BaseNameBinding -Value $Bundle.linux_deactivation_proof_file_name `
            -Path $LinuxDeactivationProofPath -Name 'Recovery proof file name'
        Assert-BaseNameBinding -Value $Bundle.linux_deactivation_transcript_file_name `
            -Path $LinuxDeactivationTranscriptPath -Name 'Recovery transcript file name'
    } else {
        Assert-BaseNameBinding -Value $Bundle.runtime_receipt_file_name `
            -Path $RuntimeReceiptPath -Name 'Runtime receipt file name'
        Assert-BaseNameBinding -Value $Bundle.daemon_exit_evidence_file_name `
            -Path $DaemonExitEvidencePath -Name 'Daemon-exit evidence file name'
        Assert-BaseNameBinding `
            -Value $Bundle.daemon_exit_observation_file_name `
            -Path $DaemonExitObservationPath `
            -Name 'Daemon-exit observation file name'
    }
    $null = Assert-ExactUtcTimestamp -Value $Bundle.created_at_utc `
        -Name 'Recovery bundle created_at_utc'
}

function Assert-LinuxDeactivationProofContract {
    param(
        [Parameter(Mandatory = $true)]$Proof,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$TranscriptSha256
    )

    Assert-ExactPropertySet -Value $Proof -Context 'Linux deactivation proof' -Names @(
        'schema_version', 'state', 'operation_id', 'identity',
        'installed_artifacts', 'loaded_configuration', 'stopped_runtime',
        'observation'
    )
    if ($Proof.schema_version -isnot [int] -or $Proof.schema_version -ne 3 -or
        $Proof.state -isnot [string] -or
        $Proof.state -cne 'viewflow-linux-deactivated' -or
        $Proof.operation_id -isnot [string] -or
        $Proof.operation_id -cne $OperationId) {
        throw 'Linux deactivation proof schema, state, or operation binding is invalid'
    }
    Assert-ExactPropertySet -Value $Proof.identity `
        -Context 'Linux identity' -Names @('uid', 'home', 'boot_id')
    if (-not (Test-JsonInteger $Proof.identity.uid) -or
        [long]$Proof.identity.uid -ne 1000 -or
        $Proof.identity.home -isnot [string] -or
        $Proof.identity.home -cne '/home/wilf' -or
        $Proof.identity.boot_id -isnot [string] -or
        $Proof.identity.boot_id -cnotmatch '^[0-9a-f]{8}-[0-9a-f-]{27,}$') {
        throw 'Linux deactivation proof identity is invalid'
    }

    $artifactPaths = [ordered]@{
        viewflowd = '/home/wilf/.local/lib/viewflow/viewflowd'
        deployment_marker_tool =
            '/home/wilf/.local/lib/viewflow/viewflow-deployment-marker'
        deskflow = '/home/wilf/.local/lib/deskflow-scale-fix/deskflow'
        deskflow_core = '/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core'
        viewflow_unit = '/home/wilf/.config/systemd/user/viewflow-peer.service'
        deskflow_dropin = '/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf'
    }
    Assert-ExactPropertySet -Value $Proof.installed_artifacts `
        -Context 'Linux installed_artifacts' -Names @($artifactPaths.Keys)
    foreach ($artifactName in $artifactPaths.Keys) {
        $artifact = $Proof.installed_artifacts.$artifactName
        Assert-ExactPropertySet -Value $artifact `
            -Context "Linux installed_artifacts.$artifactName" `
            -Names @('path', 'sha256')
        if ($artifact.path -isnot [string] -or
            $artifact.path -cne $artifactPaths[$artifactName]) {
            throw "Linux installed_artifacts.$artifactName path is invalid"
        }
        Assert-LowerSha256 -Value $artifact.sha256 `
            -Name "Linux installed_artifacts.$artifactName sha256"
    }

    Assert-ExactPropertySet -Value $Proof.stopped_runtime `
        -Context 'Linux stopped_runtime' -Names @(
            'deployment_marker_tool', 'deskflow', 'viewflow'
        )
    Assert-ExactPropertySet -Value $Proof.stopped_runtime.deployment_marker_tool `
        -Context 'Linux stopped deployment marker tool' `
        -Names @('exact_process_count')
    Assert-ExactPropertySet -Value $Proof.stopped_runtime.deskflow `
        -Context 'Linux stopped Deskflow' -Names @(
            'unit_active_state', 'main_pid', 'exact_process_count',
            'core_exact_process_count', 'tcp_24800_listener_count'
        )
    Assert-ExactPropertySet -Value $Proof.stopped_runtime.viewflow `
        -Context 'Linux stopped Viewflow' -Names @(
            'unit_active_state', 'main_pid', 'exact_process_count',
            'udp_44119_listener_count', 'sidecar_socket_present'
        )
    $deploymentMarkerTool = $Proof.stopped_runtime.deployment_marker_tool
    $deskflow = $Proof.stopped_runtime.deskflow
    $viewflow = $Proof.stopped_runtime.viewflow
    if (-not (Test-JsonInteger $deploymentMarkerTool.exact_process_count) -or
        [long]$deploymentMarkerTool.exact_process_count -ne 0 -or
        $deskflow.unit_active_state -isnot [string] -or
        $deskflow.unit_active_state -cne 'inactive' -or
        -not (Test-JsonInteger $deskflow.main_pid) -or [long]$deskflow.main_pid -ne 0 -or
        -not (Test-JsonInteger $deskflow.exact_process_count) -or [long]$deskflow.exact_process_count -ne 0 -or
        -not (Test-JsonInteger $deskflow.core_exact_process_count) -or [long]$deskflow.core_exact_process_count -ne 0 -or
        -not (Test-JsonInteger $deskflow.tcp_24800_listener_count) -or [long]$deskflow.tcp_24800_listener_count -ne 0 -or
        $viewflow.unit_active_state -isnot [string] -or
        $viewflow.unit_active_state -cne 'inactive' -or
        -not (Test-JsonInteger $viewflow.main_pid) -or [long]$viewflow.main_pid -ne 0 -or
        -not (Test-JsonInteger $viewflow.exact_process_count) -or [long]$viewflow.exact_process_count -ne 0 -or
        -not (Test-JsonInteger $viewflow.udp_44119_listener_count) -or [long]$viewflow.udp_44119_listener_count -ne 0 -or
        $viewflow.sidecar_socket_present -isnot [bool] -or
        [bool]$viewflow.sidecar_socket_present) {
        throw 'Linux deactivation proof does not establish both runtimes inactive'
    }
    Assert-ExactPropertySet -Value $Proof.loaded_configuration `
        -Context 'Linux loaded_configuration' -Names @(
            'daemon_reload_completed', 'viewflow_fragment_path',
            'deskflow_dropin_paths'
        )
    if ($Proof.loaded_configuration.daemon_reload_completed -isnot [bool] -or
        -not [bool]$Proof.loaded_configuration.daemon_reload_completed -or
        $Proof.loaded_configuration.viewflow_fragment_path -isnot [string] -or
        $Proof.loaded_configuration.viewflow_fragment_path -cne
            $artifactPaths.viewflow_unit -or
        $Proof.loaded_configuration.deskflow_dropin_paths -isnot [string] -or
        @(([string]$Proof.loaded_configuration.deskflow_dropin_paths) -split '\s+' |
            Where-Object { $_ -ceq $artifactPaths.deskflow_dropin }).Count -ne 1) {
        throw 'Linux deactivation proof loaded configuration is invalid'
    }
    Assert-ExactPropertySet -Value $Proof.observation `
        -Context 'Linux deactivation observation' -Names @(
            'command_output_format', 'command_output_file_name',
            'command_output_sha256', 'completed_at_unix_ms'
        )
    if ($Proof.observation.command_output_format -isnot [string] -or
        $Proof.observation.command_output_format -cne
            'key=value newline-delimited UTF-8 in displayed order') {
        throw 'Linux deactivation transcript format is invalid'
    }
    Assert-BaseNameBinding -Value $Proof.observation.command_output_file_name `
        -Path $LinuxDeactivationTranscriptPath `
        -Name 'Linux deactivation transcript file name'
    Assert-LowerSha256 -Value $Proof.observation.command_output_sha256 `
        -Name 'Linux deactivation transcript hash'
    if ([string]$Proof.observation.command_output_sha256 -cne $TranscriptSha256 -or
        -not (Test-JsonInteger $Proof.observation.completed_at_unix_ms) -or
        [long]$Proof.observation.completed_at_unix_ms -le 0) {
        throw 'Linux deactivation transcript hash or completion time is invalid'
    }
}

function Assert-RuntimeReceiptContract {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)][string]$OperationId
    )

    Assert-ExactPropertySet -Value $Receipt -Context 'Runtime receipt' -Names @(
        'schema_version', 'state', 'daemon_instance_id', 'operation_id',
        'daemon_pid', 'daemon_start_ticks', 'boot_id', 'daemon_sha256',
        'protocol_version', 'local_device', 'target_device', 'cleanup',
        'route_status', 'peer_disconnect_status', 'daemon_exit_required',
        'sidecar_session_disconnected', 'artifact_hashes',
        'completed_at_unix_ms'
    )
    Assert-Uint53 -Value $Receipt.daemon_pid -Name 'Runtime daemon_pid' -Positive
    Assert-Uint53 -Value $Receipt.daemon_start_ticks `
        -Name 'Runtime daemon_start_ticks' -Positive
    Assert-Uint53 -Value $Receipt.completed_at_unix_ms `
        -Name 'Runtime completed_at_unix_ms' -Positive
    if ($Receipt.schema_version -isnot [int] -or $Receipt.schema_version -ne 4 -or
        $Receipt.state -isnot [string] -or
        $Receipt.state -cne 'viewflow-input-quiesced' -or
        $Receipt.operation_id -isnot [string] -or
        $Receipt.operation_id -cne $OperationId -or
        $Receipt.boot_id -isnot [string] -or
        $Receipt.boot_id -cnotmatch
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'Runtime receipt schema, state, operation, or boot identity is invalid'
    }
    $expectedInstance = '{0}-{1}-{2}' -f @(
        $Receipt.boot_id,
        [long]$Receipt.daemon_pid,
        [long]$Receipt.daemon_start_ticks
    )
    Assert-LowerSha256 -Value $Receipt.daemon_sha256 `
        -Name 'Runtime daemon_sha256'
    if ($Receipt.daemon_instance_id -isnot [string] -or
        $Receipt.daemon_instance_id -cne $expectedInstance -or
        $Receipt.protocol_version -isnot [string] -or
        $Receipt.protocol_version -cne '2.1' -or
        $Receipt.local_device -isnot [string] -or
        $Receipt.local_device -cne $expectedLocalDeviceId -or
        $Receipt.target_device -isnot [string] -or
        $Receipt.target_device -cne $expectedDeviceId -or
        $Receipt.route_status -isnot [string] -or
        $Receipt.route_status -cne 'removed' -or
        $Receipt.peer_disconnect_status -isnot [string] -or
        $Receipt.peer_disconnect_status -cne 'initiated_before_daemon_exit' -or
        $Receipt.daemon_exit_required -isnot [bool] -or
        -not [bool]$Receipt.daemon_exit_required -or
        $Receipt.sidecar_session_disconnected -isnot [bool] -or
        -not [bool]$Receipt.sidecar_session_disconnected) {
        throw 'Runtime receipt daemon, endpoint, or quiesce binding is invalid'
    }

    $cleanup = $Receipt.cleanup
    Assert-ExactPropertySet -Value $cleanup -Context 'Runtime cleanup' -Names @(
        'route_ever_activated', 'route_was_active', 'active_lease_generation',
        'last_input_sequence', 'release_all', 'lease_revoke',
        'bound_peer_epoch', 'bound_peer_socket', 'source_display',
        'route_generation'
    )
    Assert-ExactPropertySet -Value $cleanup.release_all `
        -Context 'Runtime ReleaseAll evidence' -Names @('status', 'ack')
    Assert-ExactPropertySet -Value $cleanup.lease_revoke `
        -Context 'Runtime LeaseRevoke evidence' `
        -Names @('status', 'generation', 'ack')
    if ($cleanup.route_ever_activated -isnot [bool] -or
        $cleanup.route_was_active -isnot [bool]) {
        throw 'Runtime cleanup activation fields must be boolean'
    }
    if (-not [bool]$cleanup.route_was_active) {
        if ([bool]$cleanup.route_ever_activated -or
            $null -ne $cleanup.source_display -or
            $null -ne $cleanup.route_generation -or
            $null -ne $cleanup.active_lease_generation -or
            $null -ne $cleanup.last_input_sequence -or
            $cleanup.release_all.status -isnot [string] -or
            $cleanup.release_all.status -cne 'not_required_no_active_route' -or
            $null -ne $cleanup.release_all.ack -or
            $cleanup.lease_revoke.status -isnot [string] -or
            $cleanup.lease_revoke.status -cne 'not_required_no_active_route' -or
            $null -ne $cleanup.lease_revoke.generation -or
            $null -ne $cleanup.lease_revoke.ack -or
            $null -ne $cleanup.bound_peer_epoch -or
            $null -ne $cleanup.bound_peer_socket) {
            throw 'Inactive-route cleanup evidence is inconsistent'
        }
    } else {
        $ack = $cleanup.release_all.ack
        $revokeAck = $cleanup.lease_revoke.ack
        Assert-ExactPropertySet -Value $ack -Context 'Runtime Applied ACK' `
            -Names @('lease_generation', 'target_device', 'event_sequence', 'result')
        Assert-ExactPropertySet -Value $revokeAck `
            -Context 'Runtime LeaseRevoke Applied ACK' -Names @(
                'operation_id', 'lease_generation', 'owner_device',
                'target_device', 'state', 'result'
            )
        foreach ($number in @(
            @($cleanup.active_lease_generation, 'Runtime active_lease_generation'),
            @($cleanup.route_generation, 'Runtime route_generation'),
            @($cleanup.bound_peer_epoch, 'Runtime bound_peer_epoch'),
            @($ack.lease_generation, 'Runtime ReleaseAll ACK lease_generation'),
            @($cleanup.lease_revoke.generation, 'Runtime revoke generation'),
            @($revokeAck.lease_generation, 'Runtime revoke ACK lease_generation')
        )) {
            Assert-Uint53 -Value $number[0] -Name $number[1] -Positive
        }
        Assert-Uint53 -Value $cleanup.last_input_sequence `
            -Name 'Runtime last_input_sequence'
        Assert-Uint53 -Value $ack.event_sequence `
            -Name 'Runtime ReleaseAll ACK event_sequence'
        $socketMatch = [regex]::Match(
            [string]$cleanup.bound_peer_socket,
            '^172\.16\.105\.70:(?<port>[0-9]{1,5})$'
        )
        if (-not [bool]$cleanup.route_ever_activated -or
            $cleanup.source_display -isnot [string] -or
            $cleanup.source_display -cne $expectedSourceDisplayId -or
            [long]$cleanup.active_lease_generation -eq $maximumJsonInteger -or
            [long]$cleanup.last_input_sequence -eq $maximumJsonInteger -or
            $cleanup.bound_peer_socket -isnot [string] -or
            -not $socketMatch.Success -or
            [int]$socketMatch.Groups['port'].Value -lt 1 -or
            [int]$socketMatch.Groups['port'].Value -gt 65535 -or
            $cleanup.release_all.status -isnot [string] -or
            $cleanup.release_all.status -cne 'applied' -or
            $ack.result -isnot [string] -or $ack.result -cne 'applied' -or
            [long]$ack.lease_generation -ne
                [long]$cleanup.active_lease_generation -or
            $ack.target_device -isnot [string] -or
            $ack.target_device -cne $expectedDeviceId -or
            [long]$ack.event_sequence -ne
                ([long]$cleanup.last_input_sequence + 1) -or
            $cleanup.lease_revoke.status -isnot [string] -or
            $cleanup.lease_revoke.status -cne 'applied' -or
            [long]$cleanup.lease_revoke.generation -ne
                ([long]$cleanup.active_lease_generation + 1) -or
            $revokeAck.operation_id -isnot [string] -or
            $revokeAck.operation_id -cnotmatch '^[0-9a-f]{32}$' -or
            $revokeAck.operation_id -ceq ('0' * 32) -or
            $revokeAck.operation_id.Substring(0, 16) -cne
                ('{0:x16}' -f [long]$cleanup.bound_peer_epoch) -or
            [long]$revokeAck.lease_generation -ne
                [long]$cleanup.lease_revoke.generation -or
            $revokeAck.owner_device -isnot [string] -or
            $revokeAck.owner_device -cne $expectedLocalDeviceId -or
            $revokeAck.target_device -isnot [string] -or
            $revokeAck.target_device -cne $expectedDeviceId -or
            $revokeAck.state -isnot [string] -or
            $revokeAck.state -cne 'revoked' -or
            $revokeAck.result -isnot [string] -or
            $revokeAck.result -cne 'applied') {
            throw 'Active-route cleanup evidence is inconsistent'
        }
    }

    Assert-ExactPropertySet -Value $Receipt.artifact_hashes `
        -Context 'Runtime artifact_hashes' -Names @(
            'linux_viewflowd', 'linux_peer_certificate',
            'linux_peer_private_key', 'linux_certificate_authority'
        )
    foreach ($property in $Receipt.artifact_hashes.PSObject.Properties) {
        Assert-LowerSha256 -Value $property.Value `
            -Name "Runtime artifact hash $($property.Name)"
    }
    if ($Receipt.artifact_hashes.linux_viewflowd -cne
        $Receipt.daemon_sha256) {
        throw 'Runtime linux_viewflowd artifact does not match daemon_sha256'
    }
}

function Assert-NormalDaemonExitEvidenceContract {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)]$Evidence,
        [Parameter(Mandatory = $true)]$Observation,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$ReceiptSha256,
        [Parameter(Mandatory = $true)][string]$ObservationSha256
    )

    $compactNames = @(
        'active_state', 'boot_id', 'command_outputs', 'daemon_instance_id',
        'daemon_pid', 'daemon_sha256', 'daemon_start_ticks',
        'exact_process_count', 'exit_status', 'invocation_id', 'journal',
        'main_pid', 'observation_file_name', 'observation_sha256',
        'observed_at_unix_ms', 'operation_id', 'protocol_version',
        'runtime_receipt_sha256', 'schema_version', 'sidecar_socket_present',
        'state', 'udp_listener_count', 'unit'
    )
    $rawNames = @(
        'command_outputs', 'daemon_identity', 'journal_query',
        'observed_at_unix_ms', 'operation_id', 'runtime_receipt_sha256',
        'schema_version', 'state'
    )
    $commandNames = @(
        'exact_process_pids', 'journal_entries', 'journal_json_sha256',
        'journal_selected_invocation_id', 'original_daemon_pid_present',
        'sidecar_socket_lstat', 'systemctl_invocation_id',
        'systemctl_is_active', 'systemctl_main_pid', 'udp_listener_output'
    )
    Assert-ExactPropertySet -Value $Evidence `
        -Context 'Daemon-exit compact evidence' -Names $compactNames
    Assert-ExactPropertySet -Value $Observation `
        -Context 'Raw daemon-exit observation' -Names $rawNames
    Assert-ExactPropertySet -Value $Observation.daemon_identity `
        -Context 'Raw daemon identity' -Names @(
            'boot_id', 'daemon_instance_id', 'daemon_pid', 'daemon_sha256',
            'daemon_start_ticks', 'invocation_id'
        )
    Assert-ExactPropertySet -Value $Evidence.journal `
        -Context 'Daemon-exit journal' -Names @(
            'entry_count', 'exit_realtime_us', 'first_realtime_us',
            'last_realtime_us', 'query', 'quiescence_exit_count',
            'slice_sha256', 'startup_count'
        )
    $queryNames = @('_BOOT_ID', '_PID', '_SYSTEMD_INVOCATION_ID')
    Assert-ExactPropertySet -Value $Evidence.journal.query `
        -Context 'Daemon-exit journal query' -Names $queryNames
    Assert-ExactPropertySet -Value $Observation.journal_query `
        -Context 'Raw journal query' -Names $queryNames
    Assert-ExactPropertySet -Value $Evidence.exit_status `
        -Context 'Daemon-exit status' -Names @(
            'exact_process_count', 'main_pid_zero',
            'original_daemon_pid_present', 'sidecar_socket_present',
            'udp_listener_count', 'unit_inactive'
        )
    Assert-ExactPropertySet -Value $Evidence.command_outputs `
        -Context 'Daemon-exit command outputs' -Names $commandNames
    Assert-ExactPropertySet -Value $Observation.command_outputs `
        -Context 'Raw command outputs' -Names $commandNames

    foreach ($binding in @(
        @($Evidence.runtime_receipt_sha256, 'Daemon-exit runtime_receipt_sha256'),
        @($Observation.runtime_receipt_sha256, 'Raw runtime_receipt_sha256'),
        @($Evidence.observation_sha256, 'Daemon-exit observation_sha256'),
        @($Evidence.daemon_sha256, 'Daemon-exit daemon_sha256'),
        @($Observation.daemon_identity.daemon_sha256, 'Raw daemon_sha256'),
        @($Evidence.journal.slice_sha256, 'Daemon-exit journal slice_sha256'),
        @($Evidence.command_outputs.journal_json_sha256,
            'Daemon-exit journal_json_sha256')
    )) {
        Assert-LowerSha256 -Value $binding[0] -Name $binding[1]
    }
    foreach ($number in @(
        @($Evidence.daemon_pid, 'Daemon-exit daemon_pid', $true),
        @($Evidence.daemon_start_ticks, 'Daemon-exit daemon_start_ticks', $true),
        @($Evidence.observed_at_unix_ms, 'Daemon-exit observed_at_unix_ms', $true),
        @($Evidence.main_pid, 'Daemon-exit main_pid', $false),
        @($Evidence.exact_process_count, 'Daemon-exit exact_process_count', $false),
        @($Evidence.udp_listener_count, 'Daemon-exit udp_listener_count', $false),
        @($Evidence.journal.entry_count, 'Daemon-exit journal entry_count', $true),
        @($Evidence.journal.startup_count, 'Daemon-exit startup_count', $false),
        @($Evidence.journal.quiescence_exit_count,
            'Daemon-exit quiescence_exit_count', $false),
        @($Evidence.journal.first_realtime_us,
            'Daemon-exit first_realtime_us', $true),
        @($Evidence.journal.last_realtime_us,
            'Daemon-exit last_realtime_us', $true),
        @($Evidence.journal.exit_realtime_us,
            'Daemon-exit exit_realtime_us', $true),
        @($Observation.daemon_identity.daemon_pid, 'Raw daemon_pid', $true),
        @($Observation.daemon_identity.daemon_start_ticks,
            'Raw daemon_start_ticks', $true),
        @($Observation.observed_at_unix_ms, 'Raw observed_at_unix_ms', $true)
    )) {
        if ($number[2]) {
            Assert-Uint53 -Value $number[0] -Name $number[1] -Positive
        } else {
            Assert-Uint53 -Value $number[0] -Name $number[1]
        }
    }

    $journal = $Evidence.journal
    $commands = $Evidence.command_outputs
    $expectedInstance = '{0}-{1}-{2}' -f @(
        $Receipt.boot_id,
        [long]$Receipt.daemon_pid,
        [long]$Receipt.daemon_start_ticks
    )
    $completedMicros = [long]$Receipt.completed_at_unix_ms * 1000L
    if ($Evidence.schema_version -isnot [int] -or
        $Evidence.schema_version -ne 1 -or
        $Evidence.state -isnot [string] -or
        $Evidence.state -cne 'viewflow-daemon-exited' -or
        $Observation.schema_version -isnot [int] -or
        $Observation.schema_version -ne 1 -or
        $Observation.state -isnot [string] -or
        $Observation.state -cne 'viewflow-daemon-exit-observation' -or
        $Evidence.operation_id -isnot [string] -or
        $Evidence.operation_id -cne $OperationId -or
        $Observation.operation_id -isnot [string] -or
        $Observation.operation_id -cne $OperationId -or
        $Evidence.runtime_receipt_sha256 -cne $ReceiptSha256 -or
        $Observation.runtime_receipt_sha256 -cne $ReceiptSha256 -or
        $Evidence.observation_sha256 -cne $ObservationSha256 -or
        $Evidence.observation_file_name -isnot [string] -or
        $Evidence.observation_file_name -cne
            [System.IO.Path]::GetFileName($DaemonExitObservationPath) -or
        $Evidence.daemon_instance_id -isnot [string] -or
        $Evidence.daemon_instance_id -cne $expectedInstance -or
        [long]$Evidence.daemon_pid -ne [long]$Receipt.daemon_pid -or
        [long]$Evidence.daemon_start_ticks -ne
            [long]$Receipt.daemon_start_ticks -or
        $Evidence.boot_id -isnot [string] -or
        $Evidence.boot_id -cne $Receipt.boot_id -or
        $Evidence.daemon_sha256 -cne $Receipt.daemon_sha256 -or
        $Evidence.invocation_id -isnot [string] -or
        $Evidence.invocation_id -cnotmatch '^[0-9a-f]{32}$' -or
        $Evidence.protocol_version -isnot [string] -or
        $Evidence.protocol_version -cne '2.1' -or
        $Evidence.unit -isnot [string] -or
        $Evidence.unit -cne 'viewflow-peer.service' -or
        $journal.query._SYSTEMD_INVOCATION_ID -isnot [string] -or
        $journal.query._SYSTEMD_INVOCATION_ID -cne $Evidence.invocation_id -or
        $journal.query._PID -isnot [string] -or
        $journal.query._PID -cne ([long]$Evidence.daemon_pid).ToString() -or
        $journal.query._BOOT_ID -isnot [string] -or
        $journal.query._BOOT_ID -cne
            ([string]$Evidence.boot_id).Replace('-', '') -or
        [long]$journal.startup_count -ne 1 -or
        [long]$journal.quiescence_exit_count -ne 1 -or
        [long]$journal.last_realtime_us -lt [long]$journal.first_realtime_us -or
        [long]$journal.exit_realtime_us -lt [long]$journal.first_realtime_us -or
        [long]$journal.exit_realtime_us -gt [long]$journal.last_realtime_us -or
        [long]$journal.exit_realtime_us -lt $completedMicros -or
        $Evidence.active_state -isnot [string] -or
        $Evidence.active_state -cne 'inactive' -or
        [long]$Evidence.main_pid -ne 0 -or
        [long]$Evidence.exact_process_count -ne 0 -or
        [long]$Evidence.udp_listener_count -ne 0 -or
        $Evidence.sidecar_socket_present -isnot [bool] -or
        [bool]$Evidence.sidecar_socket_present) {
        throw 'Daemon-exit evidence, raw observation, and runtime receipt are inconsistent'
    }
    $identity = $Observation.daemon_identity
    if ($identity.daemon_instance_id -isnot [string] -or
        $identity.daemon_instance_id -cne $Evidence.daemon_instance_id -or
        [long]$identity.daemon_pid -ne [long]$Evidence.daemon_pid -or
        [long]$identity.daemon_start_ticks -ne
            [long]$Evidence.daemon_start_ticks -or
        $identity.boot_id -isnot [string] -or
        $identity.boot_id -cne $Evidence.boot_id -or
        $identity.daemon_sha256 -isnot [string] -or
        $identity.daemon_sha256 -cne $Evidence.daemon_sha256 -or
        $identity.invocation_id -isnot [string] -or
        $identity.invocation_id -cne $Evidence.invocation_id) {
        throw 'Raw daemon identity does not match compact evidence'
    }
    Assert-JsonDeepEqual -Left $Observation.journal_query `
        -Right $journal.query -Context 'Raw journal query'
    Assert-JsonDeepEqual -Left $Observation.command_outputs `
        -Right $commands -Context 'Raw command outputs'

    $status = $Evidence.exit_status
    if ($status.unit_inactive -isnot [bool] -or
        -not [bool]$status.unit_inactive -or
        $status.main_pid_zero -isnot [bool] -or
        -not [bool]$status.main_pid_zero -or
        $status.original_daemon_pid_present -isnot [bool] -or
        [bool]$status.original_daemon_pid_present -or
        -not (Test-JsonInteger $status.exact_process_count) -or
        [long]$status.exact_process_count -ne 0 -or
        -not (Test-JsonInteger $status.udp_listener_count) -or
        [long]$status.udp_listener_count -ne 0 -or
        $status.sidecar_socket_present -isnot [bool] -or
        [bool]$status.sidecar_socket_present) {
        throw 'Daemon-exit status is not the required fixed quiescence state'
    }
    if ($commands.systemctl_is_active -isnot [string] -or
        $commands.systemctl_is_active -cne 'inactive' -or
        $commands.systemctl_main_pid -isnot [string] -or
        $commands.systemctl_main_pid -cne '0' -or
        $commands.systemctl_invocation_id -isnot [string] -or
        ($commands.systemctl_invocation_id -cne '' -and
            $commands.systemctl_invocation_id -cne $Evidence.invocation_id) -or
        $commands.journal_selected_invocation_id -isnot [string] -or
        $commands.journal_selected_invocation_id -cne $Evidence.invocation_id -or
        $commands.original_daemon_pid_present -isnot [string] -or
        $commands.original_daemon_pid_present -cne 'false' -or
        $commands.exact_process_pids -isnot [string] -or
        $commands.exact_process_pids -cne '' -or
        $commands.udp_listener_output -isnot [string] -or
        $commands.udp_listener_output -cne '' -or
        $commands.sidecar_socket_lstat -isnot [string] -or
        $commands.sidecar_socket_lstat -cne 'absent' -or
        $commands.journal_json_sha256 -cne $journal.slice_sha256 -or
        $commands.journal_entries -isnot [Array] -or
        $commands.journal_entries.Count -ne [long]$journal.entry_count -or
        [long]$Evidence.observed_at_unix_ms -lt
            [long]$Receipt.completed_at_unix_ms -or
        [long]$Observation.observed_at_unix_ms -ne
            [long]$Evidence.observed_at_unix_ms) {
        throw 'Daemon-exit command outputs or observation order are inconsistent'
    }
}

function Assert-ForceReleaseReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$ToolSha256,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][long]$ObservedPid,
        [Parameter(Mandatory = $true)][string]$ObservedStartFileTime
    )

    $read = Read-StrictUtf8JsonObject -Path $Path `
        -Name 'Recovery force-release receipt'
    $receipt = $read.Value
    Assert-ExactPropertySet -Value $receipt `
        -Context 'Recovery force-release receipt' -Names @(
            'schema_version', 'state', 'operation_id', 'tool_executable_sha256',
            'linux_frozen_evidence_sha256', 'tool_pid',
            'tool_process_start_filetime', 'tool_session_id', 'tool_user_sid',
            'input_desktop', 'requested_input_count', 'inserted_input_count',
            'verification_stable_ms', 'completed_at_utc'
        )
    if ($receipt.schema_version -isnot [int] -or $receipt.schema_version -ne 3 -or
        $receipt.state -isnot [string] -or
        $receipt.state -cne 'viewflow-force-release-completed' -or
        $receipt.operation_id -isnot [string] -or
        $receipt.operation_id -cne $OperationId -or
        $receipt.tool_executable_sha256 -isnot [string] -or
        $receipt.tool_executable_sha256 -cne $ToolSha256 -or
        $receipt.linux_frozen_evidence_sha256 -isnot [string] -or
        $receipt.linux_frozen_evidence_sha256 -cne $LinuxEvidenceSha256 -or
        -not (Test-JsonInteger $receipt.tool_pid) -or
        [long]$receipt.tool_pid -ne $ObservedPid -or
        $receipt.tool_process_start_filetime -isnot [string] -or
        $receipt.tool_process_start_filetime -cne $ObservedStartFileTime -or
        -not (Test-JsonInteger $receipt.tool_session_id) -or
        [long]$receipt.tool_session_id -ne 1 -or
        $receipt.tool_user_sid -isnot [string] -or
        $receipt.tool_user_sid -cne $currentUserSid -or
        $receipt.input_desktop -isnot [string] -or
        $receipt.input_desktop -cne 'Default' -or
        -not (Test-JsonInteger $receipt.requested_input_count) -or
        [long]$receipt.requested_input_count -ne 135 -or
        -not (Test-JsonInteger $receipt.inserted_input_count) -or
        [long]$receipt.inserted_input_count -ne 135 -or
        -not (Test-JsonInteger $receipt.verification_stable_ms) -or
        [long]$receipt.verification_stable_ms -ne $forceReleaseStableMs) {
        throw 'Recovery force-release receipt execution evidence is invalid'
    }
    try {
        $null = [uint64]::Parse(
            [string]$receipt.tool_process_start_filetime,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw 'Recovery force-release process FILETIME is invalid'
    }
    $null = Assert-ExactUtcTimestamp -Value $receipt.completed_at_utc `
        -Name 'Recovery force-release completed_at_utc'
    [pscustomobject]@{
        Value = $receipt
        Sha256 = [string]$read.Sha256
    }
}

function Get-RecoveryForceReleaseTaskContract {
    param(
        [Parameter(Mandatory = $true)][string]$ToolPath,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )

    $arguments = (
        'force-release-input --receipt "{0}" --operation-id {1} ' +
        '--linux-evidence-sha256 {2}'
    ) -f @($ReceiptPath, $OperationId, $LinuxEvidenceSha256)
    [pscustomobject]@{
        TaskPath = '\'
        TaskName = "Viewflow Rollback Force Release $OperationId"
        FullTaskName = "\Viewflow Rollback Force Release $OperationId"
        ToolPath = $ToolPath
        Arguments = $arguments
        WorkingDirectory = [System.IO.Path]::GetDirectoryName($ToolPath)
        Description = $forceReleaseTaskDescription
    }
}

function Assert-RecoveryForceReleaseTask {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)]$Contract,
        [ValidateSet('Ready', 'Running')][string]$RequiredState
    )

    if ([string]$Task.State -cne $RequiredState) {
        throw "$($Contract.FullTaskName) must be $RequiredState"
    }
    $actions = @($Task.Actions | Where-Object { $null -ne $_ })
    if ($actions.Count -ne 1) {
        throw 'Recovery force-release task must have exactly one action'
    }
    $actionExecutable = Get-CanonicalAbsolutePath -Value (
        [Environment]::ExpandEnvironmentVariables(
            ([string]$actions[0].Execute).Trim('"')
        )
    ) -Name 'Recovery force-release task executable'
    Assert-SamePath -Actual $actionExecutable -Expected $Contract.ToolPath `
        -Name 'Recovery force-release task executable'
    if ([string]$actions[0].Arguments -cne $Contract.Arguments) {
        throw 'Recovery force-release task arguments changed'
    }
    $workingDirectory = Get-CanonicalAbsolutePath `
        -Value ([string]$actions[0].WorkingDirectory) `
        -Name 'Recovery force-release task working directory'
    Assert-SamePath -Actual $workingDirectory -Expected $Contract.WorkingDirectory `
        -Name 'Recovery force-release task working directory'

    $principalSid = Resolve-AccountSid -Account ([string]$Task.Principal.UserId) `
        -Context 'Recovery force-release task principal'
    if ($principalSid -cne $currentUserSid -or
        [string]$Task.Principal.LogonType -cne 'Interactive' -or
        [string]$Task.Principal.RunLevel -cne 'Limited') {
        throw 'Recovery force-release task principal is not the current interactive limited user'
    }
    Assert-NoTaskTriggers -Task $Task -Context $Contract.FullTaskName
    if ([string]$Task.Settings.MultipleInstances -cne 'IgnoreNew' -or
        $null -eq $Task.Settings.Enabled -or
        -not [Convert]::ToBoolean($Task.Settings.Enabled) -or
        $null -eq $Task.Settings.AllowHardTerminate -or
        -not [Convert]::ToBoolean($Task.Settings.AllowHardTerminate) -or
        $null -eq $Task.Settings.DisallowStartIfOnBatteries -or
        [Convert]::ToBoolean($Task.Settings.DisallowStartIfOnBatteries) -or
        $null -eq $Task.Settings.StopIfGoingOnBatteries -or
        [Convert]::ToBoolean($Task.Settings.StopIfGoingOnBatteries) -or
        $null -eq $Task.Settings.RestartCount -or
        [int]$Task.Settings.RestartCount -ne 0 -or
        [string]$Task.Settings.ExecutionTimeLimit -cne 'PT30S') {
        throw 'Recovery force-release task settings changed'
    }
}

function Assert-RecoveryForceReleaseTaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Xml,
        [Parameter(Mandatory = $true)]$Contract
    )

    try {
        [xml]$document = $Xml
    } catch {
        throw 'Recovery force-release task XML is invalid'
    }
    $namespace = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $namespace.AddNamespace(
        't',
        'http://schemas.microsoft.com/windows/2004/02/mit/task'
    )
    $taskNodes = @($document.SelectNodes('/t:Task', $namespace))
    $uriNodes = @($document.SelectNodes(
        '/t:Task/t:RegistrationInfo/t:URI',
        $namespace
    ))
    $descriptionNodes = @($document.SelectNodes(
        '/t:Task/t:RegistrationInfo/t:Description',
        $namespace
    ))
    $triggerContainers = @($document.SelectNodes('/t:Task/t:Triggers', $namespace))
    $triggers = @($document.SelectNodes('/t:Task/t:Triggers/*', $namespace))
    $principalNodes = @($document.SelectNodes(
        '/t:Task/t:Principals/t:Principal',
        $namespace
    ))
    $actionContainers = @($document.SelectNodes('/t:Task/t:Actions', $namespace))
    $actionChildren = @($document.SelectNodes('/t:Task/t:Actions/*', $namespace))
    $execNodes = @($document.SelectNodes('/t:Task/t:Actions/t:Exec', $namespace))
    if ($taskNodes.Count -ne 1 -or $uriNodes.Count -ne 1 -or
        [string]$uriNodes[0].InnerText -cne $Contract.FullTaskName -or
        $descriptionNodes.Count -ne 1 -or
        [string]$descriptionNodes[0].InnerText -cne $Contract.Description -or
        $triggerContainers.Count -ne 1 -or $triggers.Count -ne 0 -or
        $principalNodes.Count -ne 1 -or $actionContainers.Count -ne 1 -or
        $actionChildren.Count -ne 1 -or $execNodes.Count -ne 1) {
        throw 'Recovery force-release task XML structure or identity changed'
    }

    $userNodes = @($principalNodes[0].SelectNodes('t:UserId', $namespace))
    $logonNodes = @($principalNodes[0].SelectNodes('t:LogonType', $namespace))
    $runLevelNodes = @($principalNodes[0].SelectNodes('t:RunLevel', $namespace))
    if ($userNodes.Count -ne 1 -or $logonNodes.Count -ne 1 -or
        $runLevelNodes.Count -gt 1 -or
        (Resolve-AccountSid -Account ([string]$userNodes[0].InnerText) `
            -Context 'Recovery force-release task XML principal') -cne
            $currentUserSid -or
        [string]$logonNodes[0].InnerText -cne 'InteractiveToken' -or
        ($runLevelNodes.Count -eq 1 -and
            [string]$runLevelNodes[0].InnerText -cne 'LeastPrivilege')) {
        throw 'Recovery force-release task XML principal changed'
    }

    $commandNodes = @($execNodes[0].SelectNodes('t:Command', $namespace))
    $argumentNodes = @($execNodes[0].SelectNodes('t:Arguments', $namespace))
    $workingNodes = @($execNodes[0].SelectNodes(
        't:WorkingDirectory',
        $namespace
    ))
    if ($commandNodes.Count -ne 1 -or $argumentNodes.Count -ne 1 -or
        $workingNodes.Count -ne 1) {
        throw 'Recovery force-release task XML action is incomplete'
    }
    $xmlExecutable = Get-CanonicalAbsolutePath `
        -Value ([string]$commandNodes[0].InnerText) `
        -Name 'Recovery force-release task XML executable'
    $xmlWorkingDirectory = Get-CanonicalAbsolutePath `
        -Value ([string]$workingNodes[0].InnerText) `
        -Name 'Recovery force-release task XML working directory'
    Assert-SamePath -Actual $xmlExecutable -Expected $Contract.ToolPath `
        -Name 'Recovery force-release task XML executable'
    Assert-SamePath -Actual $xmlWorkingDirectory `
        -Expected $Contract.WorkingDirectory `
        -Name 'Recovery force-release task XML working directory'
    if ([string]$argumentNodes[0].InnerText -cne $Contract.Arguments) {
        throw 'Recovery force-release task XML arguments changed'
    }

    $settingsNode = $document.SelectSingleNode('/t:Task/t:Settings', $namespace)
    if ($null -eq $settingsNode) {
        throw 'Recovery force-release task XML settings are missing'
    }
    $requiredSettings = @{
        MultipleInstancesPolicy = 'IgnoreNew'
        DisallowStartIfOnBatteries = 'false'
        StopIfGoingOnBatteries = 'false'
        ExecutionTimeLimit = 'PT30S'
    }
    foreach ($settingName in $requiredSettings.Keys) {
        $nodes = @($settingsNode.SelectNodes("t:$settingName", $namespace))
        if ($nodes.Count -ne 1 -or
            [string]$nodes[0].InnerText -cne $requiredSettings[$settingName]) {
            throw "Recovery force-release task XML setting changed: $settingName"
        }
    }
    if ($null -ne $settingsNode.SelectSingleNode('t:RestartOnFailure', $namespace)) {
        throw 'Recovery force-release task XML must not contain restart-on-failure'
    }
}

function Get-ExactRecoveryForceReleaseProcesses {
    param([Parameter(Mandatory = $true)][string]$ToolPath)

    @(
        Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and
            [System.IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals(
                $ToolPath,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
    )
}

function Get-ProcessStartFileTimeString {
    param([Parameter(Mandatory = $true)][long]$ProcessId)

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Assert-RecoveryForceReleaseProcess {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$Contract,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )

    if ($null -eq $Process.SessionId -or [long]$Process.SessionId -ne 1 -or
        (Get-ProcessOwnerSid -Process $Process) -cne $currentUserSid) {
        throw 'Recovery force-release process must run as the current user in Session 1'
    }
    $actual = @(Split-WindowsCommandLine -CommandLine ([string]$Process.CommandLine))
    $expected = @(
        $Contract.ToolPath,
        'force-release-input',
        '--receipt', $ReceiptPath,
        '--operation-id', $OperationId,
        '--linux-evidence-sha256', $LinuxEvidenceSha256
    )
    Assert-ExactArguments -Actual $actual -Expected $expected `
        -Context 'Recovery force-release process command line' `
        -PathIndexes @('0', '3')
}

function Wait-RecoveryForceReleaseProcessAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$ToolPath,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $wait = [Diagnostics.Stopwatch]::StartNew()
    $stableSinceMs = $null
    do {
        $processes = @(Get-ExactRecoveryForceReleaseProcesses -ToolPath $ToolPath)
        if ($processes.Count -eq 0) {
            if ($null -eq $stableSinceMs) {
                $stableSinceMs = $wait.ElapsedMilliseconds
            }
            if (($wait.ElapsedMilliseconds - $stableSinceMs) -ge
                $forceReleaseCleanupStableMs) {
                return
            }
        } else {
            $stableSinceMs = $null
        }
        Start-Sleep -Milliseconds 100
    } while ($wait.ElapsedMilliseconds -lt 10000)
    throw "$Context did not reach stable exact process zero"
}

function Assert-RecoveryForceReleasePreflight {
    param([Parameter(Mandatory = $true)]$Contract)

    $existing = Get-ScheduledTask -TaskPath $Contract.TaskPath `
        -TaskName $Contract.TaskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        throw "$($Contract.FullTaskName) already exists"
    }
    if (@(Get-ExactRecoveryForceReleaseProcesses `
            -ToolPath $Contract.ToolPath).Count -ne 0) {
        throw 'Recovery force-release tool is already running'
    }
}

function Invoke-RecoveryForceRelease {
    param(
        [Parameter(Mandatory = $true)][string]$ToolPath,
        [Parameter(Mandatory = $true)][string]$ToolSha256,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )

    $contract = Get-RecoveryForceReleaseTaskContract -ToolPath $ToolPath `
        -OperationId $OperationId -LinuxEvidenceSha256 $LinuxEvidenceSha256 `
        -ReceiptPath $ReceiptPath
    Assert-RecoveryForceReleasePreflight -Contract $contract
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $action = New-ScheduledTaskAction -Execute $contract.ToolPath `
        -Argument $contract.Arguments -WorkingDirectory $contract.WorkingDirectory
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromSeconds(
            $forceReleaseTaskTimeoutSeconds
        )) -RestartCount 0
    $taskRegistered = $false
    $registeredTaskXml = $null
    $observedPid = $null
    $observedStartFileTime = $null
    $receiptRead = $null
    try {
        Register-ScheduledTask -TaskPath $contract.TaskPath `
            -TaskName $contract.TaskName -Action $action -Principal $principal `
            -Settings $settings -Description $contract.Description `
            -ErrorAction Stop | Out-Null
        $taskRegistered = $true
        $registered = Get-ScheduledTask -TaskPath $contract.TaskPath `
            -TaskName $contract.TaskName -ErrorAction Stop
        Assert-RecoveryForceReleaseTask -Task $registered -Contract $contract `
            -RequiredState Ready
        $registeredTaskXml = Export-ScheduledTask -TaskPath $contract.TaskPath `
            -TaskName $contract.TaskName -ErrorAction Stop
        Assert-RecoveryForceReleaseTaskXml -Xml $registeredTaskXml `
            -Contract $contract

        $taskWindowStartUtc = [DateTime]::UtcNow
        Start-ScheduledTask -TaskPath $contract.TaskPath `
            -TaskName $contract.TaskName -ErrorAction Stop
        $wait = [Diagnostics.Stopwatch]::StartNew()
        do {
            $task = Get-ScheduledTask -TaskPath $contract.TaskPath `
                -TaskName $contract.TaskName -ErrorAction Stop
            if ([string]$task.State -cne 'Ready' -and
                [string]$task.State -cne 'Running') {
                throw 'Recovery force-release task entered an invalid state'
            }
            $processes = @(Get-ExactRecoveryForceReleaseProcesses `
                -ToolPath $contract.ToolPath)
            if ($processes.Count -gt 1) {
                throw 'Recovery force-release observed multiple exact tool processes'
            }
            if ($processes.Count -eq 1) {
                Assert-RecoveryForceReleaseProcess -Process $processes[0] `
                    -Contract $contract -OperationId $OperationId `
                    -LinuxEvidenceSha256 $LinuxEvidenceSha256 `
                    -ReceiptPath $ReceiptPath
                $candidatePid = [long]$processes[0].ProcessId
                $candidateStartFileTime = Get-ProcessStartFileTimeString `
                    -ProcessId $candidatePid
                if ($null -eq $observedPid) {
                    $observedPid = $candidatePid
                    $observedStartFileTime = $candidateStartFileTime
                } elseif ($observedPid -ne $candidatePid -or
                    $observedStartFileTime -cne $candidateStartFileTime) {
                    throw 'Recovery force-release process identity changed'
                }
            }
            if ([string]$task.State -ceq 'Ready' -and
                $processes.Count -eq 0 -and
                (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
                if ($null -eq $observedPid) {
                    throw 'Recovery force-release process was never observed'
                }
                $taskInfo = Get-ScheduledTaskInfo -TaskPath $contract.TaskPath `
                    -TaskName $contract.TaskName -ErrorAction Stop
                $lastRunUtc = ([DateTime]$taskInfo.LastRunTime).ToUniversalTime()
                if ([long]$taskInfo.LastTaskResult -ne 0 -or
                    $lastRunUtc -lt $taskWindowStartUtc.AddSeconds(-1) -or
                    $lastRunUtc -gt [DateTime]::UtcNow.AddSeconds(5)) {
                    throw 'Recovery force-release task result or run time is invalid'
                }
                $receiptRead = Assert-ForceReleaseReceipt -Path $ReceiptPath `
                    -OperationId $OperationId -ToolSha256 $ToolSha256 `
                    -LinuxEvidenceSha256 $LinuxEvidenceSha256 `
                    -ObservedPid $observedPid `
                    -ObservedStartFileTime $observedStartFileTime
                break
            }
            Start-Sleep -Milliseconds 100
        } while ($wait.Elapsed.TotalSeconds -lt $forceReleaseTaskTimeoutSeconds)
        if ($null -eq $receiptRead) {
            throw "$($contract.FullTaskName) did not complete with a valid receipt"
        }
    } finally {
        if ($taskRegistered) {
            $cleanupFailures = New-Object System.Collections.Generic.List[string]
            try {
                $cleanupTask = Get-ScheduledTask -TaskPath $contract.TaskPath `
                    -TaskName $contract.TaskName -ErrorAction SilentlyContinue
                if ($null -ne $cleanupTask) {
                    Stop-ScheduledTask -TaskPath $contract.TaskPath `
                        -TaskName $contract.TaskName -ErrorAction Stop
                }
            } catch {
                $null = $cleanupFailures.Add("stop: $($_.Exception.Message)")
            }
            try {
                Wait-RecoveryForceReleaseProcessAbsent `
                    -ToolPath $contract.ToolPath `
                    -Context 'Recovery force-release cleanup'
            } catch {
                $null = $cleanupFailures.Add(
                    "process-zero before removal: $($_.Exception.Message)"
                )
            }
            try {
                $cleanupTask = Get-ScheduledTask -TaskPath $contract.TaskPath `
                    -TaskName $contract.TaskName -ErrorAction SilentlyContinue
                if ($null -ne $cleanupTask) {
                    $cleanupTaskXml = Export-ScheduledTask `
                        -TaskPath $contract.TaskPath -TaskName $contract.TaskName `
                        -ErrorAction Stop
                    if ($cleanupTaskXml -cne $registeredTaskXml) {
                        $null = $cleanupFailures.Add(
                            'task XML changed before removal'
                        )
                    }
                    Unregister-ScheduledTask -TaskPath $contract.TaskPath `
                        -TaskName $contract.TaskName -Confirm:$false `
                        -ErrorAction Stop
                }
            } catch {
                $null = $cleanupFailures.Add(
                    "unregister: $($_.Exception.Message)"
                )
            }
            try {
                $remainingTask = Get-ScheduledTask `
                    -TaskPath $contract.TaskPath -TaskName $contract.TaskName `
                    -ErrorAction SilentlyContinue
                if ($null -ne $remainingTask) {
                    throw 'Recovery force-release one-shot task was not removed'
                }
            } catch {
                $null = $cleanupFailures.Add(
                    "task absence: $($_.Exception.Message)"
                )
            }
            try {
                Wait-RecoveryForceReleaseProcessAbsent `
                    -ToolPath $contract.ToolPath `
                    -Context 'Recovery force-release post-removal cleanup'
            } catch {
                $null = $cleanupFailures.Add(
                    "process-zero after removal: $($_.Exception.Message)"
                )
            }
            if ($cleanupFailures.Count -ne 0) {
                throw ('Recovery force-release cleanup failed: ' +
                    ($cleanupFailures -join '; '))
            }
        }
    }
    $receiptRead
}

function Get-Utf16TaskXmlBytes {
    param([Parameter(Mandatory = $true)][string]$Xml)
    $encoding = [System.Text.UnicodeEncoding]::new($false, $true)
    $preamble = $encoding.GetPreamble()
    $body = $encoding.GetBytes($Xml)
    $bytes = New-Object byte[] ($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    $bytes
}

$ManifestPath = Get-CanonicalAbsolutePath -Value $ManifestPath -Name 'Manifest path'
$TokenPath = Get-CanonicalAbsolutePath -Value $TokenPath -Name 'Token path'
$RecoveryBundlePath = Get-CanonicalAbsolutePath -Value $RecoveryBundlePath `
    -Name 'Recovery bundle path'
$hasLinuxDeactivationProof =
    -not [string]::IsNullOrWhiteSpace($LinuxDeactivationProofPath)
$hasLinuxDeactivationTranscript =
    -not [string]::IsNullOrWhiteSpace($LinuxDeactivationTranscriptPath)
$hasRuntimeReceipt = -not [string]::IsNullOrWhiteSpace($RuntimeReceiptPath)
$hasDaemonExitEvidence =
    -not [string]::IsNullOrWhiteSpace($DaemonExitEvidencePath)
$hasDaemonExitObservation =
    -not [string]::IsNullOrWhiteSpace($DaemonExitObservationPath)
if ($hasLinuxDeactivationProof) {
    $LinuxDeactivationProofPath = Get-CanonicalAbsolutePath `
        -Value $LinuxDeactivationProofPath `
        -Name 'Linux deactivation proof path'
}
if ($hasLinuxDeactivationTranscript) {
    $LinuxDeactivationTranscriptPath = Get-CanonicalAbsolutePath `
        -Value $LinuxDeactivationTranscriptPath `
        -Name 'Linux deactivation transcript path'
}
if ($hasRuntimeReceipt) {
    $RuntimeReceiptPath = Get-CanonicalAbsolutePath `
        -Value $RuntimeReceiptPath -Name 'Runtime receipt path'
}
if ($hasDaemonExitEvidence) {
    $DaemonExitEvidencePath = Get-CanonicalAbsolutePath `
        -Value $DaemonExitEvidencePath -Name 'Daemon-exit evidence path'
}
if ($hasDaemonExitObservation) {
    $DaemonExitObservationPath = Get-CanonicalAbsolutePath `
        -Value $DaemonExitObservationPath -Name 'Daemon-exit observation path'
}
$RecoveryForceReleaseReceiptPath = Get-CanonicalAbsolutePath `
    -Value $RecoveryForceReleaseReceiptPath `
    -Name 'Recovery force-release receipt path'
if ($ValidateOnly) {
    if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) {
        throw 'ReceiptPath is forbidden with ValidateOnly'
    }
    $ReceiptPath = $ManifestPath + '.rollback-receipt.intended.json'
} elseif ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    throw 'ReceiptPath is mandatory for rollback mutation'
}
$ReceiptPath = Assert-NewOutputPath -Path $ReceiptPath
$RecoveryForceReleaseReceiptPath = Assert-NewOutputPath `
    -Path $RecoveryForceReleaseReceiptPath

$pathBindings = @(
    @{ Path = $ManifestPath; Name = 'Rollback manifest' },
    @{ Path = $TokenPath; Name = 'Rollback token' },
    @{ Path = $RecoveryBundlePath; Name = 'Recovery bundle' },
    @{ Path = $RecoveryForceReleaseReceiptPath; Name = 'Recovery force-release receipt' },
    @{ Path = $ReceiptPath; Name = 'Rollback completion receipt' }
)
if ($hasLinuxDeactivationProof) {
    $pathBindings += @{
        Path = $LinuxDeactivationProofPath
        Name = 'Linux deactivation proof'
    }
}
if ($hasLinuxDeactivationTranscript) {
    $pathBindings += @{
        Path = $LinuxDeactivationTranscriptPath
        Name = 'Linux deactivation transcript'
    }
}
if ($hasRuntimeReceipt) {
    $pathBindings += @{ Path = $RuntimeReceiptPath; Name = 'Runtime receipt' }
}
if ($hasDaemonExitEvidence) {
    $pathBindings += @{
        Path = $DaemonExitEvidencePath
        Name = 'Daemon-exit evidence'
    }
}
if ($hasDaemonExitObservation) {
    $pathBindings += @{
        Path = $DaemonExitObservationPath
        Name = 'Daemon-exit observation'
    }
}
Assert-PairwiseDistinctPaths -Bindings $pathBindings

$inputEvidenceBindings = @(
    @{ Path = $ManifestPath; Name = 'Rollback manifest' },
    @{ Path = $TokenPath; Name = 'Rollback token' },
    @{ Path = $RecoveryBundlePath; Name = 'Recovery bundle' }
)
if ($hasLinuxDeactivationProof) {
    $inputEvidenceBindings += @{
        Path = $LinuxDeactivationProofPath
        Name = 'Linux deactivation proof'
    }
}
if ($hasLinuxDeactivationTranscript) {
    $inputEvidenceBindings += @{
        Path = $LinuxDeactivationTranscriptPath
        Name = 'Linux deactivation transcript'
    }
}
if ($hasRuntimeReceipt) {
    $inputEvidenceBindings += @{
        Path = $RuntimeReceiptPath
        Name = 'Runtime receipt'
    }
}
if ($hasDaemonExitEvidence) {
    $inputEvidenceBindings += @{
        Path = $DaemonExitEvidencePath
        Name = 'Daemon-exit evidence'
    }
}
if ($hasDaemonExitObservation) {
    $inputEvidenceBindings += @{
        Path = $DaemonExitObservationPath
        Name = 'Daemon-exit observation'
    }
}
foreach ($entry in $inputEvidenceBindings) {
    Assert-RegularNonReparseFile -Path $entry.Path -Name $entry.Name
}
$manifestRead = Read-StrictUtf8JsonObject -Path $ManifestPath `
    -Name 'Rollback manifest'
$tokenRead = Read-StrictUtf8JsonObject -Path $TokenPath -Name 'Rollback token'
$manifestSha256 = [string]$manifestRead.Sha256
$tokenSha256 = [string]$tokenRead.Sha256
$manifest = $manifestRead.Value
$token = $tokenRead.Value

$rollbackMode = [string]$manifest.rollback_mode
if ($manifest.rollback_mode -isnot [string] -or
    @('bootstrap-v1.3', 'normal-v2') -cnotcontains $rollbackMode) {
    throw 'Rollback manifest rollback_mode is invalid'
}
$manifestKeys = @(
    'schema_version', 'state', 'rollback_mode', 'operation_id', 'user_sid', 'task_name',
    'installed', 'backup', 'candidate_sha256', 'token_path', 'token_sha256',
    'rollback_nonce', 'force_release_tool', 'recovery_bundle_path',
    'expected_deactivation_evidence_type',
    'recovery_force_release_receipt_path', 'created_at_utc'
)
if ($rollbackMode -ceq 'bootstrap-v1.3') {
    $manifestKeys += @(
        'linux_deactivation_proof_path',
        'linux_deactivation_transcript_path'
    )
    if (-not $hasLinuxDeactivationProof -or
        -not $hasLinuxDeactivationTranscript) {
        throw 'Bootstrap rollback requires deactivation proof and transcript paths'
    }
    if ($hasRuntimeReceipt -or $hasDaemonExitEvidence -or
        $hasDaemonExitObservation) {
        throw 'Normal daemon-exit evidence paths are forbidden for bootstrap rollback'
    }
} else {
    $manifestKeys += @(
        'runtime_receipt_path', 'daemon_exit_evidence_path',
        'daemon_exit_observation_path'
    )
    if (-not $hasRuntimeReceipt -or -not $hasDaemonExitEvidence -or
        -not $hasDaemonExitObservation) {
        throw 'Normal rollback requires runtime receipt, compact evidence, and raw observation paths'
    }
    if ($hasLinuxDeactivationProof -or $hasLinuxDeactivationTranscript) {
        throw 'Bootstrap deactivation evidence paths are forbidden for normal rollback'
    }
}
Assert-ExactPropertySet -Value $manifest -Context 'Rollback manifest' `
    -Names $manifestKeys
if ($manifest.schema_version -isnot [int] -or
    $manifest.schema_version -ne 2 -or
    $manifest.state -isnot [string] -or
    $manifest.state -cne 'viewflow-windows-rollback-armed' -or
    $manifest.operation_id -isnot [string] -or
    $manifest.operation_id -cnotmatch '^[A-Za-z0-9_-]{16,128}$' -or
    $manifest.user_sid -isnot [string] -or
    $manifest.user_sid -cne $currentUserSid -or
    $manifest.task_name -isnot [string] -or
    $manifest.task_name -cne $expectedTaskName -or
    $manifest.rollback_nonce -isnot [string] -or
    $manifest.rollback_nonce -cnotmatch '^[0-9a-f]{64}$' -or
    $manifest.expected_deactivation_evidence_type -isnot [string]) {
    throw 'Rollback manifest schema, state, operation, user, or task binding is invalid'
}
$expectedEvidenceType = if ($rollbackMode -ceq 'bootstrap-v1.3') {
        'schema_version=3;state=viewflow-linux-deactivated'
} else {
    'schema_version=4;state=viewflow-input-quiesced;' +
        'schema_version=1;state=viewflow-daemon-exited;' +
        'schema_version=1;state=viewflow-daemon-exit-observation'
}
if ([string]$manifest.expected_deactivation_evidence_type -cne
    $expectedEvidenceType) {
    throw 'Rollback manifest deactivation evidence type does not match rollback_mode'
}
Assert-LowerSha256 -Value $manifest.candidate_sha256 `
    -Name 'Rollback manifest candidate_sha256'
Assert-LowerSha256 -Value $manifest.token_sha256 `
    -Name 'Rollback manifest token_sha256'
$manifestTokenPath = Get-CanonicalAbsolutePath -Value $manifest.token_path `
    -Name 'Rollback manifest token_path'
Assert-SamePath -Actual $manifestTokenPath -Expected $TokenPath `
    -Name 'Rollback manifest token_path'
if ([string]$manifest.token_sha256 -cne $tokenSha256) {
    throw 'Rollback token hash does not match the manifest'
}
$manifestRecoveryBindings = @(
    @{ Value = $manifest.recovery_bundle_path; Expected = $RecoveryBundlePath; Name = 'recovery_bundle_path' },
    @{ Value = $manifest.recovery_force_release_receipt_path; Expected = $RecoveryForceReleaseReceiptPath; Name = 'recovery_force_release_receipt_path' }
)
if ($rollbackMode -ceq 'bootstrap-v1.3') {
    $manifestRecoveryBindings += @(
        @{ Value = $manifest.linux_deactivation_proof_path; Expected = $LinuxDeactivationProofPath; Name = 'linux_deactivation_proof_path' },
        @{ Value = $manifest.linux_deactivation_transcript_path; Expected = $LinuxDeactivationTranscriptPath; Name = 'linux_deactivation_transcript_path' }
    )
} else {
    $manifestRecoveryBindings += @(
        @{ Value = $manifest.runtime_receipt_path; Expected = $RuntimeReceiptPath; Name = 'runtime_receipt_path' },
        @{ Value = $manifest.daemon_exit_evidence_path; Expected = $DaemonExitEvidencePath; Name = 'daemon_exit_evidence_path' },
        @{ Value = $manifest.daemon_exit_observation_path; Expected = $DaemonExitObservationPath; Name = 'daemon_exit_observation_path' }
    )
}
foreach ($binding in $manifestRecoveryBindings) {
    $boundPath = Get-CanonicalAbsolutePath -Value $binding.Value `
        -Name "Rollback manifest $($binding.Name)"
    Assert-SamePath -Actual $boundPath -Expected $binding.Expected `
        -Name "Rollback manifest $($binding.Name)"
}
$manifestCreatedAt = Assert-ExactUtcTimestamp -Value $manifest.created_at_utc `
    -Name 'Rollback manifest created_at_utc'

Assert-ExactPropertySet -Value $token -Context 'Rollback token' -Names @(
    'schema_version', 'state', 'rollback_mode', 'operation_id', 'user_sid',
    'nonce', 'created_at_utc'
)
if ($token.schema_version -isnot [int] -or
    $token.schema_version -ne 1 -or
    $token.state -isnot [string] -or
    $token.state -cne 'viewflow-windows-rollback-authorized' -or
    $token.rollback_mode -isnot [string] -or
    $token.rollback_mode -cne $rollbackMode -or
    $token.operation_id -isnot [string] -or
    $token.operation_id -cne [string]$manifest.operation_id -or
    $token.user_sid -isnot [string] -or
    $token.user_sid -cne $currentUserSid -or
    $token.nonce -isnot [string] -or
    $token.nonce -cnotmatch '^[0-9a-f]{64}$' -or
    $token.nonce -cne [string]$manifest.rollback_nonce) {
    throw 'Rollback token schema, state, operation, user, or nonce is invalid'
}
$tokenCreatedAt = Assert-ExactUtcTimestamp -Value $token.created_at_utc `
    -Name 'Rollback token created_at_utc'
if ($tokenCreatedAt -gt $manifestCreatedAt) {
    throw 'Rollback token creation must not postdate the bound manifest'
}

$privateEvidenceBindings = @(
    @{ Path = $ManifestPath; Name = 'Rollback manifest' },
    @{ Path = $TokenPath; Name = 'Rollback token' },
    @{ Path = $RecoveryBundlePath; Name = 'Recovery bundle' }
)
if ($rollbackMode -ceq 'bootstrap-v1.3') {
    $privateEvidenceBindings += @(
        @{ Path = $LinuxDeactivationProofPath; Name = 'Linux deactivation proof' },
        @{ Path = $LinuxDeactivationTranscriptPath; Name = 'Linux deactivation transcript' }
    )
} else {
    $privateEvidenceBindings += @(
        @{ Path = $RuntimeReceiptPath; Name = 'Runtime receipt' },
        @{ Path = $DaemonExitEvidencePath; Name = 'Daemon-exit evidence' },
        @{ Path = $DaemonExitObservationPath; Name = 'Daemon-exit observation' }
    )
}
Assert-DistinctFileIdentities -Bindings $privateEvidenceBindings
$bundleRead = Read-StrictUtf8JsonObject -Path $RecoveryBundlePath `
    -Name 'Recovery bundle'
$proofRead = $null
$transcriptRead = $null
$runtimeReceiptRead = $null
$daemonExitEvidenceRead = $null
$observationRead = $null
if ($rollbackMode -ceq 'bootstrap-v1.3') {
    $proofRead = Read-StrictUtf8JsonObject -Path $LinuxDeactivationProofPath `
        -Name 'Linux deactivation proof'
    $transcriptRead = Read-PrivateFileSnapshot `
        -Path $LinuxDeactivationTranscriptPath `
        -Name 'Linux deactivation transcript'
    Assert-LinuxDeactivationProofContract -Proof $proofRead.Value `
        -OperationId ([string]$manifest.operation_id) `
        -TranscriptSha256 ([string]$transcriptRead.Sha256)
    Assert-RecoveryBundleContract -Bundle $bundleRead.Value `
        -RollbackMode $rollbackMode `
        -OperationId ([string]$manifest.operation_id) `
        -ManifestSha256 $manifestSha256 -TokenSha256 $tokenSha256 `
        -ProofSha256 ([string]$proofRead.Sha256) `
        -TranscriptSha256 ([string]$transcriptRead.Sha256)
    $primaryLinuxEvidenceSha256 = [string]$proofRead.Sha256
} else {
    $runtimeReceiptRead = Read-StrictUtf8JsonObject -Path $RuntimeReceiptPath `
        -Name 'Runtime receipt'
    $daemonExitEvidenceRead = Read-StrictUtf8JsonObject `
        -Path $DaemonExitEvidencePath -Name 'Daemon-exit compact evidence'
    $observationRead = Read-StrictUtf8JsonObject `
        -Path $DaemonExitObservationPath -Name 'Raw daemon-exit observation'
    Assert-RuntimeReceiptContract -Receipt $runtimeReceiptRead.Value `
        -OperationId ([string]$manifest.operation_id)
    Assert-NormalDaemonExitEvidenceContract `
        -Receipt $runtimeReceiptRead.Value `
        -Evidence $daemonExitEvidenceRead.Value `
        -Observation $observationRead.Value `
        -OperationId ([string]$manifest.operation_id) `
        -ReceiptSha256 ([string]$runtimeReceiptRead.Sha256) `
        -ObservationSha256 ([string]$observationRead.Sha256)
    Assert-RecoveryBundleContract -Bundle $bundleRead.Value `
        -RollbackMode $rollbackMode `
        -OperationId ([string]$manifest.operation_id) `
        -ManifestSha256 $manifestSha256 -TokenSha256 $tokenSha256 `
        -RuntimeReceiptSha256 ([string]$runtimeReceiptRead.Sha256) `
        -DaemonExitEvidenceSha256 ([string]$daemonExitEvidenceRead.Sha256) `
        -ObservationSha256 ([string]$observationRead.Sha256)
    $primaryLinuxEvidenceSha256 = [string]$daemonExitEvidenceRead.Sha256
}

Assert-ExactPropertySet -Value $manifest.installed `
    -Context 'Rollback manifest installed' -Names @(
        'binary_path', 'binary_sha256', 'wrapper_path', 'wrapper_sha256'
    )
Assert-ExactPropertySet -Value $manifest.backup `
    -Context 'Rollback manifest backup' -Names @(
        'binary_path', 'binary_sha256', 'wrapper_path', 'wrapper_sha256',
        'task_xml_path', 'task_xml_sha256'
    )
Assert-ExactPropertySet -Value $manifest.force_release_tool `
    -Context 'Rollback manifest force_release_tool' -Names @('path', 'sha256')

$manifestInstalledBinary = Get-CanonicalAbsolutePath `
    -Value $manifest.installed.binary_path -Name 'Installed binary path'
$manifestInstalledWrapper = Get-CanonicalAbsolutePath `
    -Value $manifest.installed.wrapper_path -Name 'Installed wrapper path'
Assert-SamePath -Actual $manifestInstalledBinary -Expected $installedBinary `
    -Name 'Installed binary path'
Assert-SamePath -Actual $manifestInstalledWrapper -Expected $installedWrapper `
    -Name 'Installed wrapper path'

$backupBinary = Get-CanonicalAbsolutePath -Value $manifest.backup.binary_path `
    -Name 'Backup binary path'
$backupWrapper = Get-CanonicalAbsolutePath -Value $manifest.backup.wrapper_path `
    -Name 'Backup wrapper path'
$backupTaskXml = Get-CanonicalAbsolutePath -Value $manifest.backup.task_xml_path `
    -Name 'Backup task XML path'
$forceReleaseTool = Get-CanonicalAbsolutePath `
    -Value $manifest.force_release_tool.path -Name 'Force-release tool path'
$backupRoot = [System.IO.Path]::GetDirectoryName($backupBinary)
foreach ($path in @($backupWrapper, $backupTaskXml, $forceReleaseTool)) {
    if (-not ([System.IO.Path]::GetDirectoryName($path)).Equals(
        $backupRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'All rollback backup artifacts must share one directory'
    }
}
if (-not ([System.IO.Path]::GetDirectoryName($backupRoot)).Equals(
    $installRoot,
    [StringComparison]::OrdinalIgnoreCase
) -or [System.IO.Path]::GetFileName($backupRoot) -cnotmatch
    '^backup-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$') {
    throw 'Rollback backup must be an immediate timestamped child of the install root'
}
if (((Get-Item -LiteralPath $backupRoot -Force).Attributes -band
    [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Rollback backup directory must not be a reparse point'
}
$expectedLeaves = @{
    $backupBinary = 'viewflowd.exe'
    $backupWrapper = 'viewflow-client.ps1'
    $backupTaskXml = 'Viewflow-Peer.xml'
    $forceReleaseTool = 'force-release-viewflowd.exe'
}
foreach ($path in $expectedLeaves.Keys) {
    if ([System.IO.Path]::GetFileName($path) -cne $expectedLeaves[$path]) {
        throw "Rollback backup artifact has an invalid file name: $path"
    }
    Assert-RegularNonReparseFile -Path $path -Name 'Rollback backup artifact'
}
foreach ($backupAclBinding in @(
    @{ Path = $backupBinary; Name = 'Rollback backup binary' },
    @{ Path = $backupWrapper; Name = 'Rollback backup wrapper' },
    @{ Path = $forceReleaseTool; Name = 'Rollback force-release tool' }
)) {
    Assert-OwnerOnlyFileSecurity -Path $backupAclBinding.Path `
        -Name $backupAclBinding.Name
}
foreach ($path in @($installedBinary, $installedWrapper)) {
    Assert-RegularNonReparseFile -Path $path -Name 'Installed Viewflow artifact'
}

foreach ($hashBinding in @(
    @{ Value = $manifest.installed.binary_sha256; Name = 'installed.binary_sha256' },
    @{ Value = $manifest.installed.wrapper_sha256; Name = 'installed.wrapper_sha256' },
    @{ Value = $manifest.backup.binary_sha256; Name = 'backup.binary_sha256' },
    @{ Value = $manifest.backup.wrapper_sha256; Name = 'backup.wrapper_sha256' },
    @{ Value = $manifest.backup.task_xml_sha256; Name = 'backup.task_xml_sha256' },
    @{ Value = $manifest.force_release_tool.sha256; Name = 'force_release_tool.sha256' }
)) {
    Assert-LowerSha256 -Value $hashBinding.Value -Name $hashBinding.Name
}
if ([string]$manifest.installed.binary_sha256 -cne
        [string]$manifest.candidate_sha256 -or
    [string]$manifest.backup.binary_sha256 -ceq
        [string]$manifest.candidate_sha256) {
    throw 'Rollback candidate/current/backup binary hashes are inconsistent'
}

$currentBinarySha256 = Assert-FileHashOneOf -Path $installedBinary `
    -Expected @(
        [string]$manifest.installed.binary_sha256,
        [string]$manifest.backup.binary_sha256
    ) -Name 'Installed binary'
$currentWrapperSha256 = Assert-FileHashOneOf -Path $installedWrapper `
    -Expected @(
        [string]$manifest.installed.wrapper_sha256,
        [string]$manifest.backup.wrapper_sha256
    ) -Name 'Installed wrapper'
$null = Assert-FileHash -Path $backupBinary `
    -Expected ([string]$manifest.backup.binary_sha256) -Name 'Backup binary'
$null = Assert-FileHash -Path $backupWrapper `
    -Expected ([string]$manifest.backup.wrapper_sha256) -Name 'Backup wrapper'
$null = Assert-FileHash -Path $backupTaskXml `
    -Expected ([string]$manifest.backup.task_xml_sha256) -Name 'Backup task XML'
$null = Assert-FileHash -Path $forceReleaseTool `
    -Expected ([string]$manifest.force_release_tool.sha256) `
    -Name 'Recovery force-release tool'
$taskXml = Read-VerifiedUtf16TaskXml -Path $backupTaskXml `
    -ExpectedSha256 ([string]$manifest.backup.task_xml_sha256)
Assert-TaskXmlContract -Xml $taskXml -AllowLegacyLogonTrigger

$tokenParent = [System.IO.Path]::GetDirectoryName($TokenPath)
$tokenStem = [System.IO.Path]::GetFileNameWithoutExtension($TokenPath)
$tokenExtension = [System.IO.Path]::GetExtension($TokenPath)
$consumedTokenPath = Get-CanonicalAbsolutePath -Value (Join-Path $tokenParent (
    '{0}.consumed.{1}{2}' -f @(
        $tokenStem,
        [string]$manifest.operation_id,
        $tokenExtension
    )
)) -Name 'Consumed rollback token path'
if (Test-Path -LiteralPath $consumedTokenPath) {
    throw "Consumed rollback token path already exists: $consumedTokenPath"
}
$allTransactionPaths = @($pathBindings) + @(
    @{ Path = $consumedTokenPath; Name = 'Consumed rollback token' },
    @{ Path = $backupBinary; Name = 'Backup binary' },
    @{ Path = $backupWrapper; Name = 'Backup wrapper' },
    @{ Path = $backupTaskXml; Name = 'Backup task XML' },
    @{ Path = $forceReleaseTool; Name = 'Force-release tool' },
    @{ Path = $installedBinary; Name = 'Installed binary' },
    @{ Path = $installedWrapper; Name = 'Installed wrapper' }
)
Assert-PairwiseDistinctPaths -Bindings $allTransactionPaths

$expectedOperationId = [string]$manifest.operation_id
$expectedRunningBinarySha256 = [string]$manifest.candidate_sha256
$allowLegacyCurrentTask = (
    $currentBinarySha256 -ceq [string]$manifest.backup.binary_sha256 -and
    $currentWrapperSha256 -ceq [string]$manifest.backup.wrapper_sha256
)
$currentBoundary = Assert-CurrentRollbackBoundary `
    -AllowLegacyLogonTrigger:$allowLegacyCurrentTask
$runningProcess = $currentBoundary.Process
$forceReleaseTaskContract = Get-RecoveryForceReleaseTaskContract `
    -ToolPath $forceReleaseTool `
    -OperationId ([string]$manifest.operation_id) `
    -LinuxEvidenceSha256 $primaryLinuxEvidenceSha256 `
    -ReceiptPath $RecoveryForceReleaseReceiptPath
# This read-only collision/process check deliberately precedes the
# ValidateOnly return and the rollback-token move. A ValidateOnly success is a
# complete pre-mutation proof that the Session-1 one-shot runner can be claimed.
Assert-RecoveryForceReleasePreflight -Contract $forceReleaseTaskContract
$validationResult = [ordered]@{
    schema_version = 1
    state = 'viewflow-windows-rollback-validation-succeeded'
    rollback_mode = $rollbackMode
    operation_id = [string]$manifest.operation_id
    task_name = $expectedTaskName
    task_state = [string]$currentBoundary.TaskState
    process_id = if ($null -eq $runningProcess) {
        $null
    } else {
        [long]$runningProcess.ProcessId
    }
    session_id = if ($null -eq $runningProcess) {
        $null
    } else {
        [long]$runningProcess.SessionId
    }
    current_binary_sha256 = $currentBinarySha256
    current_wrapper_sha256 = $currentWrapperSha256
    candidate_sha256 = [string]$manifest.candidate_sha256
    backup_binary_sha256 = [string]$manifest.backup.binary_sha256
    backup_wrapper_sha256 = [string]$manifest.backup.wrapper_sha256
    backup_task_xml_sha256 = [string]$manifest.backup.task_xml_sha256
    force_release_tool_sha256 = [string]$manifest.force_release_tool.sha256
    rollback_manifest_sha256 = $manifestSha256
    rollback_token_sha256 = $tokenSha256
    recovery_bundle_sha256 = [string]$bundleRead.Sha256
    consumed_token_path = $consumedTokenPath
    recovery_force_release_receipt_path = $RecoveryForceReleaseReceiptPath
    intended_rollback_receipt_path = $ReceiptPath
}
if ($rollbackMode -ceq 'bootstrap-v1.3') {
    $validationResult['linux_deactivation_proof_file_name'] =
        [System.IO.Path]::GetFileName($LinuxDeactivationProofPath)
    $validationResult['linux_deactivation_proof_sha256'] =
        [string]$proofRead.Sha256
    $validationResult['linux_deactivation_transcript_file_name'] =
        [System.IO.Path]::GetFileName($LinuxDeactivationTranscriptPath)
    $validationResult['linux_deactivation_transcript_sha256'] =
        [string]$transcriptRead.Sha256
} else {
    $validationResult['runtime_receipt_file_name'] =
        [System.IO.Path]::GetFileName($RuntimeReceiptPath)
    $validationResult['runtime_receipt_sha256'] =
        [string]$runtimeReceiptRead.Sha256
    $validationResult['daemon_exit_evidence_file_name'] =
        [System.IO.Path]::GetFileName($DaemonExitEvidencePath)
    $validationResult['daemon_exit_evidence_sha256'] =
        [string]$daemonExitEvidenceRead.Sha256
    $validationResult['daemon_exit_observation_file_name'] =
        [System.IO.Path]::GetFileName($DaemonExitObservationPath)
    $validationResult['daemon_exit_observation_sha256'] =
        [string]$observationRead.Sha256
}
if ($ValidateOnly) {
    $validationResult | ConvertTo-Json -Depth 4 -Compress
    return
}

$tokenConsumed = $false
$evidenceClaims = @()
$forceReleaseReceiptRead = $null
$restoredTaskXmlSha256 = $null
try {
    $claimBindings = @(
        @{ Path = $ManifestPath; Name = 'Rollback manifest'; Sha256 = $manifestSha256 },
        @{ Path = $RecoveryBundlePath; Name = 'Recovery bundle'; Sha256 = [string]$bundleRead.Sha256 }
    )
    if ($rollbackMode -ceq 'bootstrap-v1.3') {
        $claimBindings += @(
            @{ Path = $LinuxDeactivationProofPath; Name = 'Linux deactivation proof'; Sha256 = [string]$proofRead.Sha256 },
            @{ Path = $LinuxDeactivationTranscriptPath; Name = 'Linux deactivation transcript'; Sha256 = [string]$transcriptRead.Sha256 }
        )
    } else {
        $claimBindings += @(
            @{ Path = $RuntimeReceiptPath; Name = 'Runtime receipt'; Sha256 = [string]$runtimeReceiptRead.Sha256 },
            @{ Path = $DaemonExitEvidencePath; Name = 'Daemon-exit evidence'; Sha256 = [string]$daemonExitEvidenceRead.Sha256 },
            @{ Path = $DaemonExitObservationPath; Name = 'Daemon-exit observation'; Sha256 = [string]$observationRead.Sha256 }
        )
    }
    foreach ($claimBinding in $claimBindings) {
        $evidenceClaims += Open-PrivateFileClaim -Path $claimBinding.Path `
            -Name $claimBinding.Name -ExpectedSha256 $claimBinding.Sha256
    }
    # Keep both durable restore sources open with FileShare.Read until the
    # transaction finishes. This prevents a same-user writer from changing or
    # deleting them after preflight and token consumption.
    foreach ($backupBinding in @(
        @{
            Path = $backupBinary
            Name = 'Backup binary transaction source'
            Sha256 = [string]$manifest.backup.binary_sha256
        },
        @{
            Path = $backupWrapper
            Name = 'Backup wrapper transaction source'
            Sha256 = [string]$manifest.backup.wrapper_sha256
        }
    )) {
        $evidenceClaims += Open-PrivateFileClaim -Path $backupBinding.Path `
            -Name $backupBinding.Name -ExpectedSha256 $backupBinding.Sha256
    }
    $null = Assert-FileHash -Path $ManifestPath -Expected $manifestSha256 `
        -Name 'Rollback manifest before token consumption'
    $null = Assert-FileHash -Path $TokenPath -Expected $tokenSha256 `
        -Name 'Rollback token before consumption'
    [System.IO.File]::Move($TokenPath, $consumedTokenPath)
    $tokenConsumed = $true
    if ((Test-Path -LiteralPath $TokenPath) -or
        -not (Test-Path -LiteralPath $consumedTokenPath -PathType Leaf)) {
        throw 'Rollback token could not be atomically consumed'
    }
    $null = Assert-FileHash -Path $consumedTokenPath -Expected $tokenSha256 `
        -Name 'Consumed rollback token'
    Assert-OwnerOnlyFileSecurity -Path $consumedTokenPath `
        -Name 'Consumed rollback token'

    $null = Assert-FileHash -Path $forceReleaseTool `
        -Expected ([string]$manifest.force_release_tool.sha256) `
        -Name 'Recovery force-release tool before cleanup'
    $forceReleaseReceiptRead = Invoke-RecoveryForceRelease `
        -ToolPath $forceReleaseTool `
        -ToolSha256 ([string]$manifest.force_release_tool.sha256) `
        -OperationId ([string]$manifest.operation_id) `
        -LinuxEvidenceSha256 $primaryLinuxEvidenceSha256 `
        -ReceiptPath $RecoveryForceReleaseReceiptPath

    Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    $null = Wait-ReadyInactiveBoundary -Context 'Pre-restore rollback boundary'

    Restore-FileAtomically -Source $backupBinary -Destination $installedBinary `
        -ExpectedSha256 ([string]$manifest.backup.binary_sha256)
    Restore-FileAtomically -Source $backupWrapper -Destination $installedWrapper `
        -ExpectedSha256 ([string]$manifest.backup.wrapper_sha256)

    $null = Assert-FileHash -Path $backupTaskXml `
        -Expected ([string]$manifest.backup.task_xml_sha256) `
        -Name 'Backup task XML before registration'
    Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
        -Xml $taskXml -Force | Out-Null
    # A preserved legacy LogonTrigger must never turn restoration into an
    # activation path. Stop again after registration, then prove a stable
    # Ready/inactive boundary before accepting the restored definition.
    Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
        -ErrorAction SilentlyContinue
    $restoredTask = Wait-ReadyInactiveBoundary -Context 'Post-restore rollback boundary'
    Assert-RestoredScheduledTaskContract -Task $restoredTask `
        -AllowLegacyLogonTrigger
    $restoredTaskXml = Export-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    $restoredTaskXmlSha256 = Get-BytesSha256Lower -Bytes (
        Get-Utf16TaskXmlBytes -Xml $restoredTaskXml
    )
    if ($restoredTaskXmlSha256 -cne [string]$manifest.backup.task_xml_sha256) {
        throw 'Independently exported restored task XML does not match the backup'
    }

    $null = Assert-FileHash -Path $installedBinary `
        -Expected ([string]$manifest.backup.binary_sha256) -Name 'Restored binary'
    $null = Assert-FileHash -Path $installedWrapper `
        -Expected ([string]$manifest.backup.wrapper_sha256) -Name 'Restored wrapper'
    $null = Assert-FileHash -Path $backupTaskXml `
        -Expected ([string]$manifest.backup.task_xml_sha256) `
        -Name 'Registered source task XML'
    if (@(Get-ExactInstalledViewflowProcesses).Count -ne 0) {
        throw 'Rollback completion requires zero exact installed processes'
    }

    $receipt = [ordered]@{
        schema_version = 2
        state = 'viewflow-windows-rollback-completed'
        rollback_mode = $rollbackMode
        operation_id = [string]$manifest.operation_id
        user_sid = $currentUserSid
        task_name = $expectedTaskName
        manifest_sha256 = $manifestSha256
        token_sha256 = $tokenSha256
        recovery_bundle_sha256 = [string]$bundleRead.Sha256
        recovery_force_release_receipt_sha256 =
            [string]$forceReleaseReceiptRead.Sha256
        consumed_token_path = $consumedTokenPath
        restored = [ordered]@{
            binary_path = $installedBinary
            binary_sha256 = [string]$manifest.backup.binary_sha256
            wrapper_path = $installedWrapper
            wrapper_sha256 = [string]$manifest.backup.wrapper_sha256
            task_xml_sha256 = [string]$manifest.backup.task_xml_sha256
            restored_task_xml_sha256 = $restoredTaskXmlSha256
        }
        task_state = 'Ready'
        exact_process_count = 0
        stable_observation_ms = $stableObservationMs
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if ($rollbackMode -ceq 'bootstrap-v1.3') {
        $receipt['linux_deactivation_proof_sha256'] =
            [string]$proofRead.Sha256
        $receipt['linux_deactivation_transcript_sha256'] =
            [string]$transcriptRead.Sha256
    } else {
        $receipt['runtime_receipt_sha256'] =
            [string]$runtimeReceiptRead.Sha256
        $receipt['daemon_exit_evidence_sha256'] =
            [string]$daemonExitEvidenceRead.Sha256
        $receipt['daemon_exit_observation_sha256'] =
            [string]$observationRead.Sha256
    }
    Write-OwnerOnlyCreateOnceJson -Path $ReceiptPath -Value $receipt
} catch {
    $rollbackFailure = $_
    try {
        Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
            -ErrorAction SilentlyContinue
        $null = Wait-ReadyInactiveBoundary -Context 'Rollback failure containment'
    } catch {
        $containmentFailure = $_
        $tokenState = if ($tokenConsumed) { 'consumed' } else { 'not consumed' }
        throw (
            'Rollback failed: {0}; inactive containment also failed: {1}; ' +
            'the single-use token was {2} and the task was not started'
        ) -f @(
            $rollbackFailure.Exception.Message,
            $containmentFailure.Exception.Message,
            $tokenState
        )
    }
    throw $rollbackFailure
} finally {
    foreach ($claim in $evidenceClaims) {
        if ($null -ne $claim.Stream) {
            $claim.Stream.Dispose()
        }
    }
}

$result = [ordered]@{
    State = 'viewflow-windows-rollback-completed'
    RollbackMode = $rollbackMode
    OperationId = [string]$manifest.operation_id
    TaskName = $expectedTaskName
    TaskState = 'Ready'
    ExactProcessCount = 0
    BinarySha256 = [string]$manifest.backup.binary_sha256
    WrapperSha256 = [string]$manifest.backup.wrapper_sha256
    BackupTaskXmlSha256 = [string]$manifest.backup.task_xml_sha256
    RestoredTaskXmlSha256 = $restoredTaskXmlSha256
    ManifestSha256 = $manifestSha256
    TokenSha256 = $tokenSha256
    RecoveryBundleSha256 = [string]$bundleRead.Sha256
    RecoveryForceReleaseReceiptSha256 = [string]$forceReleaseReceiptRead.Sha256
    ConsumedTokenPath = $consumedTokenPath
    ReceiptPath = $ReceiptPath
}
if ($rollbackMode -ceq 'bootstrap-v1.3') {
    $result['LinuxDeactivationProofSha256'] = [string]$proofRead.Sha256
    $result['LinuxDeactivationTranscriptSha256'] = [string]$transcriptRead.Sha256
} else {
    $result['RuntimeReceiptSha256'] = [string]$runtimeReceiptRead.Sha256
    $result['DaemonExitEvidenceSha256'] =
        [string]$daemonExitEvidenceRead.Sha256
    $result['DaemonExitObservationSha256'] = [string]$observationRead.Sha256
}
[pscustomobject]$result
