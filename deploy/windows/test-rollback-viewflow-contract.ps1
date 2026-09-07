param(
    [string]$RollbackPath = (Join-Path $PSScriptRoot 'rollback-viewflow.ps1')
)

$ErrorActionPreference = 'Stop'

function Get-RollbackFunctionText {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $functionAst = $Ast.Find(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $Node.Name -ceq $Name
        },
        $true
    )
    if ($null -eq $functionAst) {
        throw "Rollback function was not found: $Name"
    }
    $functionAst.Extent.Text
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $threw = $false
    try {
        & $Action
    } catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "Expected rollback fixture to fail: $Name"
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $RollbackPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "Rollback script has $($parseErrors.Count) parser error(s)"
}
foreach ($name in @(
    'Test-JsonInteger',
    'Assert-Uint53',
    'Assert-ExactPropertySet',
    'Assert-LowerSha256',
    'Assert-ExactUtcTimestamp',
    'Get-CanonicalAbsolutePath',
    'Assert-SamePath',
    'Assert-PairwiseDistinctPaths',
    'Get-FileLinkIdentity',
    'Assert-DistinctFileIdentities',
    'Assert-BaseNameBinding',
    'Assert-RecoveryBundleContract',
    'Assert-LinuxDeactivationProofContract',
    'Assert-RuntimeReceiptContract',
    'New-OwnerOnlyFileSecurity',
    'Assert-OwnerOnlyFileSecurity',
    'Resolve-AccountSid',
    'Split-WindowsCommandLine',
    'Assert-ExactArguments',
    'Assert-ActionArguments',
    'Assert-TaskSettingsContract',
    'Assert-NoTaskTriggers',
    'Assert-LegacyOrNoTaskTriggers',
    'Assert-RestoredScheduledTaskContract',
    'Assert-CurrentRollbackBoundary',
    'Assert-TaskXmlContract',
    'Assert-RegularNonReparseFile',
    'Read-FileBytesExclusive',
    'Get-BytesSha256Lower',
    'Read-VerifiedUtf16TaskXml',
    'Get-FileSha256Lower',
    'Assert-FileHash',
    'Restore-FileAtomically',
    'Get-ProcessOwnerSid',
    'Get-RecoveryForceReleaseTaskContract',
    'Assert-RecoveryForceReleaseTask',
    'Assert-RecoveryForceReleaseTaskXml',
    'Assert-RecoveryForceReleaseProcess',
    'Wait-RecoveryForceReleaseProcessAbsent',
    'Assert-RecoveryForceReleasePreflight',
    'Invoke-RecoveryForceRelease'
)) {
    Invoke-Expression (Get-RollbackFunctionText -Ast $ast -Name $name)
}

$taskPath = '\'
$taskName = 'Viewflow Peer'
$expectedTaskName = '\Viewflow Peer'
$installRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA 'Programs\Viewflow')
)
$installedWrapper = [System.IO.Path]::GetFullPath(
    (Join-Path $installRoot 'viewflow-client.ps1')
)
$expectedPowerShell = [System.IO.Path]::GetFullPath(
    (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
$expectedLocalDeviceId = '00000000000000000000000000000001'
$expectedDeviceId = '00000000000000000000000000000002'
$expectedSourceDisplayId = '00000000000000000000000000000101'
$maximumJsonInteger = 9007199254740991L
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$currentUserSid = $currentIdentity.User.Value
$currentUserName = $currentIdentity.Name
$expectedOperationId = $null
$expectedReadinessReceiptPath = $null
$expectedReadinessLockPath = $null
$v13Arguments = (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-WindowStyle Hidden -File "{0}"'
) -f `
    $installedWrapper

$v13Xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><URI>\Viewflow Peer</URI></RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>$currentUserSid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$expectedPowerShell</Command>
      <Arguments>$v13Arguments</Arguments>
      <WorkingDirectory>$installRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

Assert-TaskXmlContract -Xml $v13Xml
$legacyLogonXml = $v13Xml.Replace(
    '<Triggers />',
    (('<Triggers><LogonTrigger><UserId>{0}</UserId>' +
        '</LogonTrigger></Triggers>') -f $currentUserName)
)
Assert-Throws -Name 'legacy XML LogonTrigger requires compatibility switch' -Action {
    Assert-TaskXmlContract -Xml $legacyLogonXml
}
Assert-TaskXmlContract -Xml $legacyLogonXml -AllowLegacyLogonTrigger
$defaultedLegacyLogonXml = $legacyLogonXml.Replace(
    '      <RunLevel>LeastPrivilege</RunLevel>',
    ''
).Replace(
    '    <AllowHardTerminate>true</AllowHardTerminate>',
    ''
).Replace(
    '    <Enabled>true</Enabled>',
    ''
)
Assert-TaskXmlContract -Xml $defaultedLegacyLogonXml -AllowLegacyLogonTrigger
$enabledLegacyLogonXml = $legacyLogonXml.Replace(
    '</LogonTrigger>', '<Enabled>true</Enabled></LogonTrigger>'
)
Assert-TaskXmlContract -Xml $enabledLegacyLogonXml -AllowLegacyLogonTrigger
Assert-Throws -Name 'disabled XML LogonTrigger is rejected' -Action {
    Assert-TaskXmlContract -AllowLegacyLogonTrigger -Xml (
        $enabledLegacyLogonXml.Replace('<Enabled>true</Enabled>',
            '<Enabled>false</Enabled>')
    )
}
Assert-Throws -Name 'attributed XML LogonTrigger is rejected' -Action {
    Assert-TaskXmlContract -AllowLegacyLogonTrigger -Xml (
        $legacyLogonXml.Replace('<LogonTrigger>', '<LogonTrigger id="legacy">')
    )
}
Assert-Throws -Name 'missing-user XML LogonTrigger is rejected' -Action {
    Assert-TaskXmlContract -AllowLegacyLogonTrigger -Xml (
        $legacyLogonXml.Replace(
            "<UserId>$currentUserName</UserId>",
            ''
        )
    )
}
Assert-Throws -Name 'wrong-user XML LogonTrigger is rejected' -Action {
    Assert-TaskXmlContract -AllowLegacyLogonTrigger -Xml (
        $legacyLogonXml.Replace($currentUserName, 'S-1-5-18')
    )
}
Assert-Throws -Name 'extra XML LogonTrigger child is rejected' -Action {
    Assert-TaskXmlContract -AllowLegacyLogonTrigger -Xml (
        $legacyLogonXml.Replace('</LogonTrigger>',
            '<Delay>PT1M</Delay></LogonTrigger>')
    )
}
Assert-Throws -Name 'multiple XML LogonTriggers are rejected' -Action {
    Assert-TaskXmlContract -AllowLegacyLogonTrigger -Xml (
        $legacyLogonXml.Replace('</Triggers>',
            ('<LogonTrigger><UserId>{0}</UserId></LogonTrigger></Triggers>' -f
                $currentUserName))
    )
}
Assert-Throws -Name 'non-logon XML trigger is rejected' -Action {
    Assert-TaskXmlContract -AllowLegacyLogonTrigger -Xml (
        $legacyLogonXml.Replace('LogonTrigger', 'BootTrigger')
    )
}
$v13Task = [pscustomobject]@{
    State = 'Ready'
    Actions = @([pscustomobject]@{
        Execute = $expectedPowerShell
        Arguments = $v13Arguments
        WorkingDirectory = $installRoot
    })
    Principal = [pscustomobject]@{
        UserId = $currentUserSid
        LogonType = 'Interactive'
        RunLevel = 'Limited'
    }
    Triggers = @()
    Settings = [pscustomobject]@{
        MultipleInstances = 'IgnoreNew'
        Enabled = $true
        DisallowStartIfOnBatteries = $false
        StopIfGoingOnBatteries = $false
        AllowHardTerminate = $true
        RestartCount = 0
        ExecutionTimeLimit = 'PT0S'
    }
}
Assert-RestoredScheduledTaskContract -Task $v13Task
$v13Task.Triggers = $null
Assert-RestoredScheduledTaskContract -Task $v13Task
$v13Task.Triggers = @()
Assert-Throws -Name 'extra task argument is rejected' -Action {
    $v13Task.Actions[0].Arguments = $v13Arguments + ' -Unexpected value'
    Assert-RestoredScheduledTaskContract -Task $v13Task
}
$v13Task.Actions[0].Arguments = $v13Arguments
Assert-Throws -Name 'relative PowerShell command is rejected' -Action {
    $v13Task.Actions[0].Execute = 'powershell.exe'
    Assert-RestoredScheduledTaskContract -Task $v13Task
}
$v13Task.Actions[0].Execute = $expectedPowerShell

Assert-Throws -Name 'additional action is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '</Actions>',
        '<ComHandler><ClassId>{00000000-0000-0000-0000-000000000000}</ClassId></ComHandler></Actions>'
    ))
}
Assert-Throws -Name 'wrong principal SID is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace($currentUserSid, 'S-1-5-18'))
}
Assert-TaskXmlContract -Xml ($v13Xml.Replace(
    '      <RunLevel>LeastPrivilege</RunLevel>',
    ''
))
Assert-Throws -Name 'wrong explicit RunLevel is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<RunLevel>LeastPrivilege</RunLevel>',
        '<RunLevel>HighestAvailable</RunLevel>'
    ))
}
Assert-Throws -Name 'duplicate RunLevel is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '</Principal>',
        '<RunLevel>LeastPrivilege</RunLevel></Principal>'
    ))
}
Assert-Throws -Name 'wrong wrapper path is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        $installedWrapper,
        (Join-Path $installRoot 'other.ps1')
    ))
}
Assert-Throws -Name 'duplicate URI is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<URI>\Viewflow Peer</URI>',
        '<URI>\Viewflow Peer</URI><URI>\Viewflow Peer</URI>'
    ))
}
Assert-Throws -Name 'duplicate Actions container is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '</Task>',
        '<Actions Context="Author"></Actions></Task>'
    ))
}
Assert-Throws -Name 'action context mismatch is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<Actions Context="Author">',
        '<Actions Context="Other">'
    ))
}
Assert-Throws -Name 'automatic trigger is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<Triggers />',
        '<Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>'
    ))
}
Assert-Throws -Name 'invalid task XML setting is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
        '<MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>'
    ))
}
Assert-Throws -Name 'legacy MultipleInstances XML name is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
        '<MultipleInstances>IgnoreNew</MultipleInstances>'
    ))
}
Assert-Throws -Name 'duplicate required task XML setting is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '</Settings>',
        '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings>'
    ))
}
foreach ($requiredSettingXml in @(
    '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
    '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>',
    '<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>'
)) {
    Assert-Throws -Name 'missing required task XML setting is rejected' -Action {
        Assert-TaskXmlContract -Xml ($v13Xml.Replace($requiredSettingXml, ''))
    }
}
Assert-TaskXmlContract -Xml ($v13Xml.Replace(
    '<AllowHardTerminate>true</AllowHardTerminate>', ''
).Replace('<Enabled>true</Enabled>', ''))
Assert-Throws -Name 'explicit false optional setting is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<AllowHardTerminate>true</AllowHardTerminate>',
        '<AllowHardTerminate>false</AllowHardTerminate>'
    ))
}
Assert-Throws -Name 'explicit false Enabled is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '<Enabled>true</Enabled>',
        '<Enabled>false</Enabled>'
    ))
}
Assert-Throws -Name 'duplicate optional setting is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '</Settings>', '<Enabled>true</Enabled></Settings>'
    ))
}
Assert-Throws -Name 'restart policy is rejected' -Action {
    Assert-TaskXmlContract -Xml ($v13Xml.Replace(
        '</Settings>',
        '<RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings>'
    ))
}

$v13Task.State = 'Running'
Assert-Throws -Name 'restored Running state is rejected' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task
}
$v13Task.State = 'Ready'
$v13Task.Triggers = @([pscustomobject]@{ Enabled = $true })
Assert-Throws -Name 'restored task trigger is rejected' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task
}
$legacyTaskLogonTrigger = [pscustomobject]@{
    CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' }
    UserId = $currentUserName
    Enabled = $null
}
$v13Task.Triggers = @($legacyTaskLogonTrigger)
Assert-Throws -Name 'restored legacy trigger requires compatibility switch' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task
}
Assert-RestoredScheduledTaskContract -Task $v13Task -AllowLegacyLogonTrigger
$legacyTaskLogonTrigger.Enabled = $true
Assert-RestoredScheduledTaskContract -Task $v13Task -AllowLegacyLogonTrigger
$legacyTaskLogonTrigger.Enabled = $false
Assert-Throws -Name 'restored disabled LogonTrigger is rejected' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task `
        -AllowLegacyLogonTrigger
}
$legacyTaskLogonTrigger.Enabled = 'true'
Assert-Throws -Name 'restored non-Boolean LogonTrigger Enabled is rejected' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task `
        -AllowLegacyLogonTrigger
}
$legacyTaskLogonTrigger.Enabled = $null
$legacyTaskLogonTrigger.UserId = 'S-1-5-18'
Assert-Throws -Name 'restored wrong-user LogonTrigger is rejected' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task `
        -AllowLegacyLogonTrigger
}
$legacyTaskLogonTrigger.UserId = $currentUserName
$v13Task.Triggers = @($legacyTaskLogonTrigger, $legacyTaskLogonTrigger)
Assert-Throws -Name 'restored multiple LogonTriggers are rejected' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task `
        -AllowLegacyLogonTrigger
}
$v13Task.Triggers = @()
$v13Task.Settings.MultipleInstances = 'Parallel'
Assert-Throws -Name 'restored task settings drift is rejected' -Action {
    Assert-RestoredScheduledTaskContract -Task $v13Task
}
$v13Task.Settings.MultipleInstances = 'IgnoreNew'

# A resumed rollback may observe the exact restored baseline task before its
# terminal receipt was published. The compatibility switch is explicit: the
# same task remains invalid on the candidate/no-switch path.
$script:boundaryTask = $v13Task
function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskPath, [string]$TaskName)
    $script:boundaryTask
}
function Get-ExactInstalledViewflowProcesses { @() }
$legacyTaskLogonTrigger.Enabled = $true
$v13Task.Triggers = @($legacyTaskLogonTrigger)
Assert-Throws -Name 'current candidate boundary rejects legacy LogonTrigger' -Action {
    Assert-CurrentRollbackBoundary
}
$legacyBoundary = Assert-CurrentRollbackBoundary -AllowLegacyLogonTrigger
if ($legacyBoundary.TaskState -cne 'Ready' -or
    $null -ne $legacyBoundary.Process) {
    throw 'Restored legacy baseline boundary did not remain Ready and inactive'
}
$v13Task.Triggers = @()

$temporary = Join-Path $env:TEMP (
    'viewflow-rollback-task-xml-{0}.xml' -f [Guid]::NewGuid().ToString('N')
)
try {
    $encoding = [System.Text.UnicodeEncoding]::new($false, $true, $true)
    $preamble = $encoding.GetPreamble()
    $body = $encoding.GetBytes($v13Xml)
    $bytes = New-Object byte[] ($preamble.Length + $body.Length)
    [Array]::Copy($preamble, 0, $bytes, 0, $preamble.Length)
    [Array]::Copy($body, 0, $bytes, $preamble.Length, $body.Length)
    [System.IO.File]::WriteAllBytes($temporary, $bytes)
    $hash = Get-BytesSha256Lower -Bytes $bytes
    $verifiedXml = Read-VerifiedUtf16TaskXml -Path $temporary `
        -ExpectedSha256 $hash
    if ($verifiedXml -cne $v13Xml) {
        throw 'Verified task XML text does not match the source fixture'
    }
    Assert-Throws -Name 'task XML hash mismatch is rejected' -Action {
        $null = Read-VerifiedUtf16TaskXml -Path $temporary `
            -ExpectedSha256 ('0' * 64)
    }
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
}

$LinuxDeactivationTranscriptPath = Join-Path $env:TEMP `
    'viewflow-linux-deactivated.txt'
$proofHash = 'a' * 64
$validProof = [pscustomobject][ordered]@{
    schema_version = 3
    state = 'viewflow-linux-deactivated'
    operation_id = 'rollback-test-001'
    identity = [pscustomobject][ordered]@{
        uid = 1000
        home = '/home/wilf'
        boot_id = '12345678-1234-1234-1234-123456789abc'
    }
    installed_artifacts = [pscustomobject][ordered]@{
        viewflowd = [pscustomobject]@{
            path = '/home/wilf/.local/lib/viewflow/viewflowd'; sha256 = $proofHash
        }
        deployment_marker_tool = [pscustomobject]@{
            path = '/home/wilf/.local/lib/viewflow/viewflow-deployment-marker'
            sha256 = $proofHash
        }
        deskflow = [pscustomobject]@{
            path = '/home/wilf/.local/lib/deskflow-scale-fix/deskflow'; sha256 = $proofHash
        }
        deskflow_core = [pscustomobject]@{
            path = '/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core'; sha256 = $proofHash
        }
        viewflow_unit = [pscustomobject]@{
            path = '/home/wilf/.config/systemd/user/viewflow-peer.service'; sha256 = $proofHash
        }
        deskflow_dropin = [pscustomobject]@{
            path = '/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf'; sha256 = $proofHash
        }
    }
    loaded_configuration = [pscustomobject][ordered]@{
        daemon_reload_completed = $true
        viewflow_fragment_path = '/home/wilf/.config/systemd/user/viewflow-peer.service'
        deskflow_dropin_paths = '/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf'
    }
    stopped_runtime = [pscustomobject][ordered]@{
        deployment_marker_tool = [pscustomobject][ordered]@{
            exact_process_count = 0
        }
        deskflow = [pscustomobject][ordered]@{
            unit_active_state = 'inactive'; main_pid = 0; exact_process_count = 0
            core_exact_process_count = 0; tcp_24800_listener_count = 0
        }
        viewflow = [pscustomobject][ordered]@{
            unit_active_state = 'inactive'; main_pid = 0; exact_process_count = 0
            udp_44119_listener_count = 0; sidecar_socket_present = $false
        }
    }
    observation = [pscustomobject][ordered]@{
        command_output_format = 'key=value newline-delimited UTF-8 in displayed order'
        command_output_file_name = 'viewflow-linux-deactivated.txt'
        command_output_sha256 = $proofHash
        completed_at_unix_ms = 1788019200000
    }
}
Assert-LinuxDeactivationProofContract -Proof $validProof `
    -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash

$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.schema_version = 2
Assert-Throws -Name 'legacy schema-2 deactivation proof is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}
$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.identity.uid = 1001
Assert-Throws -Name 'wrong Linux UID is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}
$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.installed_artifacts.viewflowd.path = '/tmp/viewflowd'
Assert-Throws -Name 'wrong Linux artifact path is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}
$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.installed_artifacts.deployment_marker_tool.sha256 = 'A' * 64
Assert-Throws -Name 'uppercase marker-tool hash is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}
$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.installed_artifacts.deployment_marker_tool.path =
    '/tmp/viewflow-deployment-marker'
Assert-Throws -Name 'wrong marker-tool path is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}
$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.installed_artifacts.PSObject.Properties.Remove(
    'deployment_marker_tool'
)
Assert-Throws -Name 'missing marker-tool artifact is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}
$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.stopped_runtime.deployment_marker_tool.exact_process_count = 1
Assert-Throws -Name 'running marker tool is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}
$invalidProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidProof.loaded_configuration.viewflow_fragment_path = '/tmp/viewflow-peer.service'
Assert-Throws -Name 'wrong loaded fragment is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $invalidProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}

$runtimeDaemonHash = '7' * 64
$validInactiveRuntimeReceipt = [pscustomobject][ordered]@{
    schema_version = 4
    state = 'viewflow-input-quiesced'
    daemon_instance_id =
        '12345678-1234-1234-1234-123456789abc-4242-123456'
    operation_id = 'rollback-test-001'
    daemon_pid = 4242
    daemon_start_ticks = 123456
    boot_id = '12345678-1234-1234-1234-123456789abc'
    daemon_sha256 = $runtimeDaemonHash
    protocol_version = '2.1'
    local_device = $expectedLocalDeviceId
    target_device = $expectedDeviceId
    cleanup = [pscustomobject][ordered]@{
        route_ever_activated = $false
        route_was_active = $false
        active_lease_generation = $null
        last_input_sequence = $null
        release_all = [pscustomobject][ordered]@{
            status = 'not_required_no_active_route'
            ack = $null
        }
        lease_revoke = [pscustomobject][ordered]@{
            status = 'not_required_no_active_route'
            generation = $null
            ack = $null
        }
        bound_peer_epoch = $null
        bound_peer_socket = $null
        source_display = $null
        route_generation = $null
    }
    route_status = 'removed'
    peer_disconnect_status = 'initiated_before_daemon_exit'
    daemon_exit_required = $true
    sidecar_session_disconnected = $true
    artifact_hashes = [pscustomobject][ordered]@{
        linux_viewflowd = $runtimeDaemonHash
        linux_peer_certificate = '8' * 64
        linux_peer_private_key = '9' * 64
        linux_certificate_authority = 'a' * 64
    }
    completed_at_unix_ms = 1788019200000
}
Assert-RuntimeReceiptContract -Receipt $validInactiveRuntimeReceipt `
    -OperationId 'rollback-test-001'

$invalidInactiveRuntimeReceipt = $validInactiveRuntimeReceipt |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidInactiveRuntimeReceipt.cleanup.source_display = $expectedSourceDisplayId
Assert-Throws -Name 'inactive cleanup source display is rejected' -Action {
    Assert-RuntimeReceiptContract -Receipt $invalidInactiveRuntimeReceipt `
        -OperationId 'rollback-test-001'
}
$invalidInactiveRuntimeReceipt = $validInactiveRuntimeReceipt |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidInactiveRuntimeReceipt.cleanup.route_generation = 1
Assert-Throws -Name 'inactive cleanup route generation is rejected' -Action {
    Assert-RuntimeReceiptContract -Receipt $invalidInactiveRuntimeReceipt `
        -OperationId 'rollback-test-001'
}

$validActiveRuntimeReceipt = $validInactiveRuntimeReceipt |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$validActiveRuntimeReceipt.cleanup = [pscustomobject][ordered]@{
    route_ever_activated = $true
    route_was_active = $true
    active_lease_generation = 7
    last_input_sequence = 42
    release_all = [pscustomobject][ordered]@{
        status = 'applied'
        ack = [pscustomobject][ordered]@{
            lease_generation = 7
            target_device = $expectedDeviceId
            event_sequence = 43
            result = 'applied'
        }
    }
    lease_revoke = [pscustomobject][ordered]@{
        status = 'applied'
        generation = 8
        ack = [pscustomobject][ordered]@{
            operation_id = '000000000000000a0123456789abcdef'
            lease_generation = 8
            owner_device = $expectedLocalDeviceId
            target_device = $expectedDeviceId
            state = 'revoked'
            result = 'applied'
        }
    }
    bound_peer_epoch = 10
    bound_peer_socket = '172.16.105.70:44119'
    source_display = $expectedSourceDisplayId
    route_generation = 3
}
Assert-RuntimeReceiptContract -Receipt $validActiveRuntimeReceipt `
    -OperationId 'rollback-test-001'

$invalidActiveRuntimeReceipt = $validActiveRuntimeReceipt |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidActiveRuntimeReceipt.cleanup.source_display = '0' * 32
Assert-Throws -Name 'active cleanup source display is rejected' -Action {
    Assert-RuntimeReceiptContract -Receipt $invalidActiveRuntimeReceipt `
        -OperationId 'rollback-test-001'
}
$invalidActiveRuntimeReceipt = $validActiveRuntimeReceipt |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidActiveRuntimeReceipt.cleanup.route_generation = 0
Assert-Throws -Name 'active cleanup route generation is rejected' -Action {
    Assert-RuntimeReceiptContract -Receipt $invalidActiveRuntimeReceipt `
        -OperationId 'rollback-test-001'
}
$invalidActiveRuntimeReceipt = $validActiveRuntimeReceipt |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$invalidActiveRuntimeReceipt.cleanup.lease_revoke.ack.operation_id =
    '000000000000000b0123456789abcdef'
Assert-Throws -Name 'revoke ACK peer epoch prefix is rejected' -Action {
    Assert-RuntimeReceiptContract -Receipt $invalidActiveRuntimeReceipt `
        -OperationId 'rollback-test-001'
}

$bundleTimestamp = [DateTimeOffset]::UtcNow.ToString(
    'yyyy-MM-ddTHH:mm:ss.fffZ',
    [Globalization.CultureInfo]::InvariantCulture
)
$manifestHash = '1' * 64
$tokenHash = '2' * 64
$transcriptHash = '3' * 64
$observationHash = '4' * 64
$runtimeReceiptHash = '5' * 64
$daemonExitEvidenceHash = '6' * 64
$LinuxDeactivationProofPath = Join-Path $env:TEMP `
    'viewflow-linux-deactivated.json'
$LinuxDeactivationTranscriptPath = Join-Path $env:TEMP `
    'viewflow-linux-deactivated.txt'
$RuntimeReceiptPath = Join-Path $env:TEMP `
    'viewflow-input-quiesced.json'
$DaemonExitEvidencePath = Join-Path $env:TEMP `
    'viewflow-daemon-exited.json'
$DaemonExitObservationPath = Join-Path $env:TEMP `
    'viewflow-daemon-exit-observation.txt'

$bootstrapBundle = [pscustomobject][ordered]@{
    schema_version = 1
    state = 'viewflow-cross-host-recovery-authorized'
    rollback_mode = 'bootstrap-v1.3'
    operation_id = 'rollback-test-001'
    rollback_manifest_sha256 = $manifestHash
    rollback_token_sha256 = $tokenHash
    linux_deactivation_proof_file_name =
        [System.IO.Path]::GetFileName($LinuxDeactivationProofPath)
    linux_deactivation_proof_sha256 = $proofHash
    linux_deactivation_transcript_file_name =
        [System.IO.Path]::GetFileName($LinuxDeactivationTranscriptPath)
    linux_deactivation_transcript_sha256 = $transcriptHash
    created_at_utc = $bundleTimestamp
}
Assert-RecoveryBundleContract -Bundle $bootstrapBundle `
    -RollbackMode 'bootstrap-v1.3' -OperationId 'rollback-test-001' `
    -ManifestSha256 $manifestHash -TokenSha256 $tokenHash `
    -ProofSha256 $proofHash -TranscriptSha256 $transcriptHash

$pollutedBootstrapBundle = $bootstrapBundle | ConvertTo-Json -Depth 8 |
    ConvertFrom-Json
$pollutedBootstrapBundle | Add-Member -NotePropertyName `
    daemon_exit_observation_file_name -NotePropertyValue (
        [System.IO.Path]::GetFileName($DaemonExitObservationPath)
    )
$pollutedBootstrapBundle | Add-Member -NotePropertyName `
    daemon_exit_observation_sha256 -NotePropertyValue $observationHash
Assert-Throws -Name 'bootstrap bundle with daemon observation is rejected' -Action {
    Assert-RecoveryBundleContract -Bundle $pollutedBootstrapBundle `
        -RollbackMode 'bootstrap-v1.3' -OperationId 'rollback-test-001' `
        -ManifestSha256 $manifestHash -TokenSha256 $tokenHash `
        -ProofSha256 $proofHash -TranscriptSha256 $transcriptHash `
        -ObservationSha256 $observationHash
}

$normalBundle = [pscustomobject][ordered]@{
    schema_version = 1
    state = 'viewflow-cross-host-recovery-authorized'
    rollback_mode = 'normal-v2'
    operation_id = 'rollback-test-001'
    rollback_manifest_sha256 = $manifestHash
    rollback_token_sha256 = $tokenHash
    runtime_receipt_file_name =
        [System.IO.Path]::GetFileName($RuntimeReceiptPath)
    runtime_receipt_sha256 = $runtimeReceiptHash
    daemon_exit_evidence_file_name =
        [System.IO.Path]::GetFileName($DaemonExitEvidencePath)
    daemon_exit_evidence_sha256 = $daemonExitEvidenceHash
    daemon_exit_observation_file_name =
        [System.IO.Path]::GetFileName($DaemonExitObservationPath)
    daemon_exit_observation_sha256 = $observationHash
    created_at_utc = $bundleTimestamp
}
Assert-RecoveryBundleContract -Bundle $normalBundle `
    -RollbackMode 'normal-v2' -OperationId 'rollback-test-001' `
    -ManifestSha256 $manifestHash -TokenSha256 $tokenHash `
    -RuntimeReceiptSha256 $runtimeReceiptHash `
    -DaemonExitEvidenceSha256 $daemonExitEvidenceHash `
    -ObservationSha256 $observationHash

$normalWithoutObservation = [pscustomobject][ordered]@{
    schema_version = 1
    state = 'viewflow-cross-host-recovery-authorized'
    rollback_mode = 'normal-v2'
    operation_id = 'rollback-test-001'
    rollback_manifest_sha256 = $manifestHash
    rollback_token_sha256 = $tokenHash
    runtime_receipt_file_name =
        [System.IO.Path]::GetFileName($RuntimeReceiptPath)
    runtime_receipt_sha256 = $runtimeReceiptHash
    daemon_exit_evidence_file_name =
        [System.IO.Path]::GetFileName($DaemonExitEvidencePath)
    daemon_exit_evidence_sha256 = $daemonExitEvidenceHash
    created_at_utc = $bundleTimestamp
}
Assert-Throws -Name 'normal bundle without daemon observation is rejected' -Action {
    Assert-RecoveryBundleContract -Bundle $normalWithoutObservation `
        -RollbackMode 'normal-v2' -OperationId 'rollback-test-001' `
        -ManifestSha256 $manifestHash -TokenSha256 $tokenHash `
        -RuntimeReceiptSha256 $runtimeReceiptHash `
        -DaemonExitEvidenceSha256 $daemonExitEvidenceHash `
        -ObservationSha256 $observationHash
}

$pollutedNormalBundle = $normalBundle | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$pollutedNormalBundle | Add-Member -NotePropertyName unexpected `
    -NotePropertyValue 'pollution'
Assert-Throws -Name 'normal bundle exact-key pollution is rejected' -Action {
    Assert-RecoveryBundleContract -Bundle $pollutedNormalBundle `
        -RollbackMode 'normal-v2' -OperationId 'rollback-test-001' `
        -ManifestSha256 $manifestHash -TokenSha256 $tokenHash `
        -RuntimeReceiptSha256 $runtimeReceiptHash `
        -DaemonExitEvidenceSha256 $daemonExitEvidenceHash `
        -ObservationSha256 $observationHash
}

$pollutedProof = $validProof | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$pollutedProof | Add-Member -NotePropertyName unexpected `
    -NotePropertyValue 'pollution'
Assert-Throws -Name 'Linux proof exact-key pollution is rejected' -Action {
    Assert-LinuxDeactivationProofContract -Proof $pollutedProof `
        -OperationId 'rollback-test-001' -TranscriptSha256 $proofHash
}

$samePath = [System.IO.Path]::GetFullPath((Join-Path $env:TEMP 'same.json'))
Assert-Throws -Name 'same recovery path is rejected' -Action {
    Assert-PairwiseDistinctPaths -Bindings @(
        @{ Path = $samePath; Name = 'first evidence' },
        @{ Path = $samePath; Name = 'second evidence' }
    )
}

$hardLinkRoot = Join-Path $env:TEMP (
    'viewflow-rollback-hardlink-{0}' -f [Guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $hardLinkRoot | Out-Null
    $hardLinkSource = Join-Path $hardLinkRoot 'manifest.json'
    $hardLinkAlias = Join-Path $hardLinkRoot 'token.json'
    [System.IO.File]::WriteAllText($hardLinkSource, '{}')
    Set-Acl -LiteralPath $hardLinkSource -AclObject (New-OwnerOnlyFileSecurity)
    New-Item -ItemType HardLink -Path $hardLinkAlias `
        -Target $hardLinkSource | Out-Null
    Assert-Throws -Name 'hard-linked recovery evidence is rejected' -Action {
        Assert-DistinctFileIdentities -Bindings @(
            @{ Path = $hardLinkSource; Name = 'Rollback manifest' },
            @{ Path = $hardLinkAlias; Name = 'Rollback token' }
        )
    }
} finally {
    if (Test-Path -LiteralPath $hardLinkRoot) {
        Remove-Item -LiteralPath $hardLinkRoot -Recurse -Force
    }
}

# Exercise the real Windows PowerShell 5.1/.NET Framework File.Replace path.
# The durable source must remain byte-for-byte and identity stable, and a
# post-replace validation failure must atomically put the old destination back.
$atomicRoot = Join-Path $env:TEMP (
    'viewflow-rollback-atomic-{0}' -f [Guid]::NewGuid().ToString('N')
)
try {
    New-Item -ItemType Directory -Path $atomicRoot | Out-Null
    $atomicSource = Join-Path $atomicRoot 'backup.bin'
    $atomicDestination = Join-Path $atomicRoot 'installed.bin'
    [System.IO.File]::WriteAllBytes($atomicSource, [byte[]](10, 20, 30, 40))
    [System.IO.File]::WriteAllBytes($atomicDestination, [byte[]](1, 2, 3, 4))
    $sourceHashBefore = Get-FileSha256Lower -Path $atomicSource
    $sourceIdentityBefore = Get-FileLinkIdentity -Path $atomicSource `
        -Name 'Atomic fixture durable source'
    $sourceWriteTimeBefore = (Get-Item -LiteralPath $atomicSource).LastWriteTimeUtc.Ticks
    Restore-FileAtomically -Source $atomicSource -Destination $atomicDestination `
        -ExpectedSha256 $sourceHashBefore
    if ((Get-FileSha256Lower -Path $atomicDestination) -cne $sourceHashBefore -or
        (Get-FileSha256Lower -Path $atomicSource) -cne $sourceHashBefore -or
        (Get-FileLinkIdentity -Path $atomicSource `
            -Name 'Atomic fixture durable source after success') -cne
            $sourceIdentityBefore -or
        (Get-Item -LiteralPath $atomicSource).LastWriteTimeUtc.Ticks -ne
            $sourceWriteTimeBefore -or
        @(Get-ChildItem -LiteralPath $atomicRoot -Force | Where-Object {
            $_.Name -like '*.rollback.*'
        }).Count -ne 0) {
        throw 'PS5.1 successful rollback replacement changed its durable source or leaked artifacts'
    }

    [System.IO.File]::WriteAllBytes($atomicDestination, [byte[]](5, 6, 7, 8))
    $oldDestinationHash = Get-FileSha256Lower -Path $atomicDestination
    function Assert-FileHash {
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$Expected,
            [Parameter(Mandatory = $true)][string]$Name
        )
        $actual = Get-FileSha256Lower -Path $Path
        if ($actual -cne $Expected) {
            throw "$Name injected fixture hash mismatch"
        }
        if ($Name -ceq 'Restored artifact') {
            throw 'injected post-replace validation failure'
        }
        $actual
    }
    Assert-Throws -Name 'post-replace validation failure is compensated' -Action {
        Restore-FileAtomically -Source $atomicSource `
            -Destination $atomicDestination -ExpectedSha256 $sourceHashBefore
    }
    Invoke-Expression (Get-RollbackFunctionText -Ast $ast -Name 'Assert-FileHash')
    if ((Get-FileSha256Lower -Path $atomicDestination) -cne
            $oldDestinationHash -or
        (Get-FileSha256Lower -Path $atomicSource) -cne $sourceHashBefore -or
        (Get-FileLinkIdentity -Path $atomicSource `
            -Name 'Atomic fixture durable source after compensation') -cne
            $sourceIdentityBefore -or
        @(Get-ChildItem -LiteralPath $atomicRoot -Force | Where-Object {
            $_.Name -like '*.rollback.*'
        }).Count -ne 0) {
        throw 'PS5.1 rollback replacement compensation did not restore the old destination cleanly'
    }
} finally {
    Invoke-Expression (Get-RollbackFunctionText -Ast $ast -Name 'Assert-FileHash')
    if (Test-Path -LiteralPath $atomicRoot) {
        Remove-Item -LiteralPath $atomicRoot -Recurse -Force
    }
}

# The rollback entry point can run in SSH Session 0, so force-release must be
# delegated to a trigger-free current-user Interactive task and the observed
# tool itself must prove Session 1. ScheduledTasks and process discovery are
# mocked here; no task is registered on the fixture host.
$forceReleaseTaskTimeoutSeconds = 30
$forceReleaseCleanupStableMs = 0
$forceReleaseTaskDescription = 'Viewflow rollback force-release one-shot'
$forceFixtureOperation = '0123456789abcdef0123456789abcdef'
$forceFixtureHash = 'a' * 64
$forceFixtureTool = [System.IO.Path]::GetFullPath(
    (Join-Path $env:TEMP 'force-release-viewflowd.exe')
)
$forceFixtureReceipt = [System.IO.Path]::GetFullPath(
    (Join-Path $env:TEMP (
        'viewflow-force-release-{0}.json' -f [Guid]::NewGuid().ToString('N')
    ))
)
$forceFixtureContract = Get-RecoveryForceReleaseTaskContract `
    -ToolPath $forceFixtureTool -OperationId $forceFixtureOperation `
    -LinuxEvidenceSha256 $forceFixtureHash -ReceiptPath $forceFixtureReceipt
$escapedTool = [Security.SecurityElement]::Escape($forceFixtureTool)
$escapedWorking = [Security.SecurityElement]::Escape(
    $forceFixtureContract.WorkingDirectory
)
$escapedArguments = [Security.SecurityElement]::Escape(
    $forceFixtureContract.Arguments
)
$escapedDescription = [Security.SecurityElement]::Escape(
    $forceReleaseTaskDescription
)
$forceFixtureXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$escapedDescription</Description>
    <URI>$($forceFixtureContract.FullTaskName)</URI>
  </RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author">
    <UserId>$currentUserSid</UserId><LogonType>InteractiveToken</LogonType>
    <RunLevel>LeastPrivilege</RunLevel>
  </Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT30S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author"><Exec>
    <Command>$escapedTool</Command><Arguments>$escapedArguments</Arguments>
    <WorkingDirectory>$escapedWorking</WorkingDirectory>
  </Exec></Actions>
</Task>
"@
$script:forceTaskRegistered = $false
$script:forceTaskStarted = $false
$script:forceTaskReads = 0
$script:forceProcessReads = 0
$script:forceStartCount = 0
$script:forceReceiptChecks = 0
$script:forceEvents = New-Object System.Collections.Generic.List[string]
$script:forceMockTask = [pscustomobject]@{
    State = 'Ready'
    Actions = @([pscustomobject]@{
        Execute = $forceFixtureTool
        Arguments = $forceFixtureContract.Arguments
        WorkingDirectory = $forceFixtureContract.WorkingDirectory
    })
    Principal = [pscustomobject]@{
        UserId = $currentUserSid
        LogonType = 'Interactive'
        RunLevel = 'Limited'
    }
    Triggers = @()
    Settings = [pscustomobject]@{
        MultipleInstances = 'IgnoreNew'
        Enabled = $true
        AllowHardTerminate = $true
        DisallowStartIfOnBatteries = $false
        StopIfGoingOnBatteries = $false
        RestartCount = 0
        ExecutionTimeLimit = 'PT30S'
    }
}

function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskPath, [string]$TaskName)
    if (-not $script:forceTaskRegistered) { return $null }
    if ($script:forceTaskStarted) {
        $script:forceTaskReads++
        $script:forceMockTask.State = if ($script:forceTaskReads -eq 1) {
            'Running'
        } else {
            'Ready'
        }
    }
    $script:forceMockTask
}
function New-ScheduledTaskAction {
    param([string]$Execute, [string]$Argument, [string]$WorkingDirectory)
    if ($Execute -cne $forceFixtureTool -or
        $Argument -cne $forceFixtureContract.Arguments -or
        $WorkingDirectory -cne $forceFixtureContract.WorkingDirectory) {
        throw 'Fixture observed a non-canonical recovery task action'
    }
    $script:forceMockTask.Actions[0]
}
function New-ScheduledTaskPrincipal {
    param([string]$UserId, [string]$LogonType, [string]$RunLevel)
    if ($UserId -cne $currentIdentity.Name -or $LogonType -cne 'Interactive' -or
        $RunLevel -cne 'Limited') {
        throw 'Fixture observed a non-interactive recovery task principal'
    }
    $script:forceMockTask.Principal
}
function New-ScheduledTaskSettingsSet {
    param(
        [string]$MultipleInstances,
        [switch]$AllowStartIfOnBatteries,
        [switch]$DontStopIfGoingOnBatteries,
        [TimeSpan]$ExecutionTimeLimit,
        [int]$RestartCount
    )
    if ($MultipleInstances -cne 'IgnoreNew' -or
        -not $AllowStartIfOnBatteries -or -not $DontStopIfGoingOnBatteries -or
        $ExecutionTimeLimit.TotalSeconds -ne 30 -or $RestartCount -ne 0) {
        throw 'Fixture observed unsafe recovery task settings'
    }
    $script:forceMockTask.Settings
}
function Register-ScheduledTask {
    [CmdletBinding()]
    param(
        [string]$TaskPath, [string]$TaskName, $Action, $Principal, $Settings,
        [string]$Description
    )
    if ($script:forceTaskRegistered -or
        $TaskName -cne $forceFixtureContract.TaskName -or
        $Description -cne $forceReleaseTaskDescription) {
        throw 'Fixture observed an unsafe recovery task registration'
    }
    $script:forceTaskRegistered = $true
    $null = $script:forceEvents.Add('register')
}
function Export-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskPath, [string]$TaskName)
    $forceFixtureXml
}
function Start-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskPath, [string]$TaskName)
    $script:forceStartCount++
    if ($script:forceStartCount -ne 1) {
        throw 'Fixture observed repeated one-shot task start'
    }
    $script:forceTaskStarted = $true
    $null = $script:forceEvents.Add('start')
}
function Stop-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskPath, [string]$TaskName)
    $null = $script:forceEvents.Add('stop')
}
function Unregister-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskPath, [string]$TaskName, [switch]$Confirm)
    $script:forceTaskRegistered = $false
    $null = $script:forceEvents.Add('unregister')
}
function Get-ExactRecoveryForceReleaseProcesses {
    param([string]$ToolPath)
    if (-not $script:forceTaskStarted) { return @() }
    $script:forceProcessReads++
    if ($script:forceProcessReads -eq 1) {
        return ,([pscustomobject]@{
            ProcessId = 4242
            SessionId = 1
            CommandLine = ('"{0}" force-release-input --receipt "{1}" ' +
                '--operation-id {2} --linux-evidence-sha256 {3}') -f @(
                    $forceFixtureTool, $forceFixtureReceipt,
                    $forceFixtureOperation, $forceFixtureHash
                )
        })
    }
    if ($script:forceProcessReads -eq 2) {
        [System.IO.File]::WriteAllText($forceFixtureReceipt, '{}')
    }
    @()
}
function Get-ProcessOwnerSid { param($Process) $currentUserSid }
function Get-ProcessStartFileTimeString { param([long]$ProcessId) '133700000000000000' }
function Get-ScheduledTaskInfo {
    [CmdletBinding()]
    param([string]$TaskPath, [string]$TaskName)
    [pscustomobject]@{ LastTaskResult = 0; LastRunTime = [DateTime]::Now }
}
function Assert-ForceReleaseReceipt {
    param(
        [string]$Path, [string]$OperationId, [string]$ToolSha256,
        [string]$LinuxEvidenceSha256, [long]$ObservedPid,
        [string]$ObservedStartFileTime
    )
    if ($Path -cne $forceFixtureReceipt -or
        $OperationId -cne $forceFixtureOperation -or
        $ToolSha256 -cne $forceFixtureHash -or
        $LinuxEvidenceSha256 -cne $forceFixtureHash -or
        $ObservedPid -ne 4242 -or
        $ObservedStartFileTime -cne '133700000000000000') {
        throw 'Fixture observed an incorrectly bound force-release receipt check'
    }
    $script:forceReceiptChecks++
    [pscustomobject]@{ Value = [pscustomobject]@{}; Sha256 = ('b' * 64) }
}

try {
    $forceResult = Invoke-RecoveryForceRelease -ToolPath $forceFixtureTool `
        -ToolSha256 $forceFixtureHash -OperationId $forceFixtureOperation `
        -LinuxEvidenceSha256 $forceFixtureHash -ReceiptPath $forceFixtureReceipt
    if ($forceResult.Sha256 -cne ('b' * 64) -or
        $script:forceStartCount -ne 1 -or $script:forceReceiptChecks -ne 1 -or
        $script:forceTaskRegistered -or
        ($script:forceEvents -join ',') -cne
            'register,start,stop,unregister') {
        throw 'Session-1 recovery force-release task fixture did not complete or clean up exactly once'
    }

    $script:forceMockTask.Triggers = @([pscustomobject]@{ Enabled = $true })
    Assert-Throws -Name 'force-release task trigger is rejected' -Action {
        Assert-RecoveryForceReleaseTask -Task $script:forceMockTask `
            -Contract $forceFixtureContract -RequiredState Ready
    }
    $script:forceMockTask.Triggers = @()
    $script:forceMockTask.Principal.RunLevel = 'Highest'
    Assert-Throws -Name 'force-release elevated principal is rejected' -Action {
        Assert-RecoveryForceReleaseTask -Task $script:forceMockTask `
            -Contract $forceFixtureContract -RequiredState Ready
    }
    $script:forceMockTask.Principal.RunLevel = 'Limited'
    $sessionZeroProcess = [pscustomobject]@{
        ProcessId = 99
        SessionId = 0
        CommandLine = 'unused'
    }
    Assert-Throws -Name 'force-release Session 0 process is rejected' -Action {
        Assert-RecoveryForceReleaseProcess -Process $sessionZeroProcess `
            -Contract $forceFixtureContract -OperationId $forceFixtureOperation `
            -LinuxEvidenceSha256 $forceFixtureHash `
            -ReceiptPath $forceFixtureReceipt
    }
    $script:forceTaskRegistered = $true
    Assert-Throws -Name 'pre-existing force-release task is rejected' -Action {
        Assert-RecoveryForceReleasePreflight -Contract $forceFixtureContract
    }
} finally {
    if (Test-Path -LiteralPath $forceFixtureReceipt) {
        Remove-Item -LiteralPath $forceFixtureReceipt -Force
    }
}

Write-Output 'viewflow standalone rollback behavioral fixture passed'
