[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{32}$')][string]$OperationId,
    [Parameter(Mandatory = $true)][string]$OperationRoot,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')][string]$ManifestSha256,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')][string]$IncidentSha256,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')][string]$TombstoneSha256,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-f]{64}$')][string]$WindowsInventorySha256,
    [string]$TaskPath = '\',
    [string]$TaskName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([string]::IsNullOrEmpty($TaskName)) {
    $TaskName = 'Viewflow Deployment ' + $OperationId
}
if ($TaskPath -cne '\' -or
    $TaskName -cne ('Viewflow Deployment ' + $OperationId)) {
    throw 'legacy deployment task identity is not canonical'
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Convert-ToSid {
    param([Parameter(Mandatory = $true)][string]$Identity)
    try {
        ([Security.Principal.SecurityIdentifier]::new($Identity)).Value
    } catch {
        ([Security.Principal.NTAccount]::new($Identity)).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    }
}

function Get-ExactAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    [ordered]@{
        owner_sid = Convert-ToSid -Identity $acl.Owner
        protected = [bool]$acl.AreAccessRulesProtected
        rules = @($acl.Access | ForEach-Object {
            [ordered]@{
                sid = Convert-ToSid -Identity $_.IdentityReference.Value
                type = [string]$_.AccessControlType
                rights = [string]$_.FileSystemRights
                inherited = [bool]$_.IsInherited
                inheritance = [string]$_.InheritanceFlags
                propagation = [string]$_.PropagationFlags
            }
        })
    }
}

function Get-LegacyTaskSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotTaskName,
        [Parameter(Mandatory = $true)][string]$ExpectedState
    )
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $SnapshotTaskName -ErrorAction Stop
    if ([string]$task.State -cne $ExpectedState) {
        throw ("scheduled task state differs for " + $SnapshotTaskName)
    }
    $xml = Export-ScheduledTask -TaskPath $TaskPath -TaskName $SnapshotTaskName -ErrorAction Stop
    $encoding = [Text.UnicodeEncoding]::new($false, $true)
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes($xml)
    $actions = @($task.Actions | ForEach-Object {
        [ordered]@{
            execute = [string]$_.Execute
            arguments = [string]$_.Arguments
            working_directory = [string]$_.WorkingDirectory
        }
    })
    [ordered]@{
        task_path = $TaskPath
        task_name = $SnapshotTaskName
        state = [string]$task.State
        task_xml_sha256 = Get-Sha256Hex -Bytes $bytes
        actions = $actions
        principal = [ordered]@{
            user_id = [string]$task.Principal.UserId
            logon_type = [string]$task.Principal.LogonType
            run_level = [string]$task.Principal.RunLevel
        }
    }
}

function Get-LegacyRootSnapshot {
    $rootItem = Get-Item -LiteralPath $OperationRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'legacy operation root must be a non-reparse directory'
    }
    $rootFull = [IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\')
    $members = @(
        Get-ChildItem -LiteralPath $rootFull -Force -Recurse -ErrorAction Stop |
            Sort-Object FullName |
            ForEach-Object {
                if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw ('legacy operation root contains a reparse point: ' + $_.FullName)
                }
                [ordered]@{
                    name = $_.FullName.Substring($rootFull.Length).TrimStart('\')
                    directory = [bool]$_.PSIsContainer
                    reparse = $false
                    length = if ($_.PSIsContainer) { $null } else { [long]$_.Length }
                    sha256 = if ($_.PSIsContainer) { $null } else {
                        Get-FileSha256Hex -Path $_.FullName
                    }
                    acl = Get-ExactAcl -Path $_.FullName
                }
            }
    )
    $snapshot = [ordered]@{
        path = $rootFull
        reparse = $false
        acl = Get-ExactAcl -Path $rootFull
        members = $members
    }
    $snapshotJson = $snapshot |
        ConvertTo-Json -Compress -Depth 8
    $snapshot['census_sha256'] = Get-Sha256Hex -Bytes (
        [Text.UTF8Encoding]::new($false).GetBytes($snapshotJson)
    )
    $snapshot
}

function Get-InstalledCensus {
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Viewflow'
    @('viewflowd.exe', 'viewflow-client.ps1', 'rollback-viewflow.ps1') |
        ForEach-Object {
            $path = Join-Path $installRoot $_
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            [ordered]@{
                name = $_
                path = $item.FullName
                directory = [bool]$item.PSIsContainer
                reparse = [bool](($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
                length = [long]$item.Length
                sha256 = Get-FileSha256Hex -Path $path
                acl = Get-ExactAcl -Path $path
            }
        }
}

function Get-PeerTaskSnapshot {
    Get-LegacyTaskSnapshot -SnapshotTaskName 'Viewflow Peer' -ExpectedState 'Running'
}

function Get-SystemViewflowdCensus {
    @(Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'" -ErrorAction Stop |
        ForEach-Object {
            [ordered]@{
                name = [string]$_.Name
                path = [string]$_.ExecutablePath
                pid = [int]$_.ProcessId
                parent_pid = [int]$_.ParentProcessId
                creation_date = $_.CreationDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
                session_id = [int]$_.SessionId
                owner_sid = [string](Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction Stop).Sid
                exe_sha256 = Get-FileSha256Hex -Path $_.ExecutablePath
                command_line = [string]$_.CommandLine
            }
        })
}

# Two read-only snapshots bracket construction. A concurrent change fails
# closed. There is no task, root, installed-peer, or process mutation here.
$taskBefore = Get-LegacyTaskSnapshot -SnapshotTaskName $TaskName -ExpectedState 'Disabled'
$rootBefore = Get-LegacyRootSnapshot
$installed = @(Get-InstalledCensus)
$peerTask = Get-PeerTaskSnapshot
$viewflowdProcesses = @(Get-SystemViewflowdCensus)
$taskAfter = Get-LegacyTaskSnapshot -SnapshotTaskName $TaskName -ExpectedState 'Disabled'
$rootAfter = Get-LegacyRootSnapshot
if ($taskBefore.state -cne $taskAfter.state -or
    $taskBefore.task_xml_sha256 -cne $taskAfter.task_xml_sha256 -or
    $rootBefore.path -cne $rootAfter.path -or
    $rootBefore.census_sha256 -cne $rootAfter.census_sha256) {
    throw 'legacy deployment task or operation root changed during census'
}

$value = [ordered]@{
    schema_version = 1
    state = 'viewflow-post-vfdqa-windows-legacy-census'
    operation_id = $OperationId
    observed_at_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    policy = 'FREEZE_ONLY_NO_MUTATION'
    operation_root = [ordered]@{
        path = $rootBefore.path
        reparse = $rootBefore.reparse
        acl = $rootBefore.acl
        members = $rootBefore.members
        before_census_sha256 = $rootBefore.census_sha256
        after_census_sha256 = $rootAfter.census_sha256
        disposition = 'FROZEN_PRESENT_UNCHANGED'
    }
    deployment_task = [ordered]@{
        task_path = $taskBefore.task_path
        task_name = $taskBefore.task_name
        state = $taskBefore.state
        task_xml_sha256 = $taskBefore.task_xml_sha256
        actions = $taskBefore.actions
        principal = $taskBefore.principal
        disposition = 'FROZEN_DISABLED_UNCHANGED'
    }
    installed = $installed
    peer_task = $peerTask
    viewflowd_processes = $viewflowdProcesses
    prohibited_actions = @('ENABLE', 'REPLACE', 'DELETE')
    reconciliation_binding = [ordered]@{
        manifest_sha256 = $ManifestSha256
        incident_sha256 = $IncidentSha256
        tombstone_sha256 = $TombstoneSha256
        windows_inventory_sha256 = $WindowsInventorySha256
    }
    classification = [ordered]@{
        physical_abort = 'VFDQA_COMMITTED'
        authorization_provenance = 'AUTHZ_PROVENANCE_INVALID'
        prior_normal_terminal = 'TERMINAL_ABSENT'
        windows_baseline = 'WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION'
        normal_release_ready = $false
        fresh_bridge_ready = $false
    }
}
$json = $value | ConvertTo-Json -Compress -Depth 8
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
$stdout = [Console]::OpenStandardOutput()
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
