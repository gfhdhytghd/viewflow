param(
    [string]$RollbackPath = (Join-Path $PSScriptRoot 'rollback-viewflow.ps1')
)

$ErrorActionPreference = 'Stop'
$fixtureTokens = $null
$fixtureParseErrors = $null
$fixtureAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $PSCommandPath,
    [ref]$fixtureTokens,
    [ref]$fixtureParseErrors
)
if ($fixtureParseErrors.Count -ne 0) {
    throw 'Rollback static fixture has PowerShell parser errors'
}
$fixtureCommandNames = @($fixtureAst.FindAll(
    {
        param($Node)
        $Node -is [System.Management.Automation.Language.CommandAst]
    },
    $true
) | ForEach-Object { $_.GetCommandName() })
foreach ($scheduledTaskCommand in @(
    'Get-ScheduledTask',
    'Register-ScheduledTask',
    'Start-ScheduledTask',
    'Stop-ScheduledTask',
    'Unregister-ScheduledTask',
    'New-ScheduledTaskAction',
    'New-ScheduledTaskPrincipal',
    'New-ScheduledTaskSettingsSet'
)) {
    if ($fixtureCommandNames -icontains $scheduledTaskCommand) {
        throw "Static fixture must not invoke ScheduledTasks: $scheduledTaskCommand"
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
    $messages = @($parseErrors | ForEach-Object Message) -join '; '
    throw "Rollback script has PowerShell parser errors: $messages"
}

$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object {
    $_.Name.VariablePath.UserPath
})
$expectedParameters = @(
    'ManifestPath', 'TokenPath', 'RecoveryBundlePath',
    'LinuxDeactivationProofPath', 'LinuxDeactivationTranscriptPath',
    'RuntimeReceiptPath', 'DaemonExitEvidencePath',
    'DaemonExitObservationPath',
    'RecoveryForceReleaseReceiptPath',
    'ValidateOnly', 'ReceiptPath'
)
if ($parameterNames.Count -ne $expectedParameters.Count -or
    (Compare-Object -ReferenceObject $expectedParameters `
        -DifferenceObject $parameterNames)) {
    throw 'Rollback CLI parameter set changed'
}
foreach ($required in @(
    'ManifestPath', 'TokenPath', 'RecoveryBundlePath',
    'RecoveryForceReleaseReceiptPath'
)) {
    $parameter = $ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -ceq $required
    }
    if ($parameter.Extent.Text -notmatch
        '(?s)\[Parameter\s*\(\s*Mandatory\s*=\s*\$true\s*\)\]') {
        throw "Rollback CLI parameter must remain mandatory: $required"
    }
}
foreach ($optionalEvidencePath in @(
    'LinuxDeactivationProofPath', 'LinuxDeactivationTranscriptPath',
    'RuntimeReceiptPath', 'DaemonExitEvidencePath',
    'DaemonExitObservationPath'
)) {
    $parameter = $ast.ParamBlock.Parameters | Where-Object {
        $_.Name.VariablePath.UserPath -ceq $optionalEvidencePath
    }
    if ($parameter.StaticType.FullName -cne 'System.String' -or
        $parameter.Extent.Text -match
            '(?s)\[Parameter\s*\(\s*Mandatory\s*=\s*\$true\s*\)\]') {
        throw "Rollback evidence path must remain an optional string: $optionalEvidencePath"
    }
}
$validateOnlyParameter = $ast.ParamBlock.Parameters | Where-Object {
    $_.Name.VariablePath.UserPath -ceq 'ValidateOnly'
}
if ($validateOnlyParameter.StaticType.FullName -cne
    'System.Management.Automation.SwitchParameter') {
    throw 'ValidateOnly must remain a switch'
}

$requiredFunctions = @(
    'Assert-ExactPropertySet',
    'Split-WindowsCommandLine',
    'Assert-ExactArguments',
    'Assert-PairwiseDistinctPaths',
    'Get-FileLinkIdentity',
    'Assert-DistinctFileIdentities',
    'Open-PrivateFileClaim',
    'Assert-RecoveryBundleContract',
    'Assert-LinuxDeactivationProofContract',
    'Assert-RuntimeReceiptContract',
    'Assert-NormalDaemonExitEvidenceContract',
    'Assert-ForceReleaseReceipt',
    'Get-RecoveryForceReleaseTaskContract',
    'Assert-RecoveryForceReleaseTask',
    'Assert-RecoveryForceReleaseTaskXml',
    'Get-ExactRecoveryForceReleaseProcesses',
    'Get-ProcessStartFileTimeString',
    'Assert-RecoveryForceReleaseProcess',
    'Wait-RecoveryForceReleaseProcessAbsent',
    'Assert-RecoveryForceReleasePreflight',
    'Invoke-RecoveryForceRelease',
    'Assert-FileHashOneOf',
    'Assert-OwnerOnlyFileSecurity',
    'Assert-TaskSettingsContract',
    'Assert-NoTaskTriggers',
    'Assert-LegacyOrNoTaskTriggers',
    'Assert-ScheduledTaskContract',
    'Assert-RestoredScheduledTaskContract',
    'Assert-TaskXmlContract',
    'Read-FileBytesExclusive',
    'Read-StrictUtf8JsonObject',
    'Read-VerifiedUtf16TaskXml',
    'Get-ExactInstalledViewflowProcesses',
    'Get-ProcessOwnerSid',
    'Assert-CurrentRollbackBoundary',
    'Wait-ReadyInactiveBoundary',
    'Restore-FileAtomically',
    'Write-OwnerOnlyCreateOnceJson'
)
$functionNames = @($ast.FindAll(
    {
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    },
    $true
) | ForEach-Object Name)
foreach ($name in $requiredFunctions) {
    if ($functionNames -cnotcontains $name) {
        throw "Rollback function is missing: $name"
    }
}

$commands = @($ast.FindAll(
    {
        param($Node)
        $Node -is [System.Management.Automation.Language.CommandAst]
    },
    $true
))
$commandNames = @($commands | ForEach-Object { $_.GetCommandName() })
foreach ($forbidden in @(
    'Start-Process',
    'Stop-Process',
    'taskkill.exe',
    'taskkill',
    'Invoke-Expression',
    'Invoke-Command'
)) {
    if ($commandNames -icontains $forbidden) {
        throw "Rollback script contains a forbidden command: $forbidden"
    }
}
if (@($commandNames | Where-Object { $_ -ieq 'Register-ScheduledTask' }).Count -ne 2) {
    throw 'Rollback script must register one force-release task and one baseline task'
}
if (@($commandNames | Where-Object { $_ -ieq 'Start-ScheduledTask' }).Count -ne 1) {
    throw 'Rollback script must start exactly one force-release one-shot task'
}
if (@($commandNames | Where-Object { $_ -ieq 'Unregister-ScheduledTask' }).Count -ne 1) {
    throw 'Rollback script must unregister exactly one force-release one-shot task'
}
if (@($commandNames | Where-Object { $_ -ieq 'Stop-ScheduledTask' }).Count -lt 2) {
    throw 'Rollback script must stop the task in the normal and containment paths'
}

$forceReleaseFunction = $ast.Find(
    {
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $Node.Name -ceq 'Invoke-RecoveryForceRelease'
    },
    $true
)
$forceReleaseFunctionCommands = @($forceReleaseFunction.Body.FindAll(
    {
        param($Node)
        $Node -is [System.Management.Automation.Language.CommandAst]
    },
    $true
) | ForEach-Object { $_.GetCommandName() })
foreach ($singleCommand in @(
    'Register-ScheduledTask',
    'Start-ScheduledTask',
    'Unregister-ScheduledTask'
)) {
    if (@($forceReleaseFunctionCommands | Where-Object {
            $_ -ieq $singleCommand
        }).Count -ne 1) {
        throw "Recovery force-release must invoke $singleCommand exactly once"
    }
}
$forceReleaseText = $forceReleaseFunction.Extent.Text
$forceRegister = $forceReleaseText.IndexOf(
    'Register-ScheduledTask',
    [StringComparison]::Ordinal
)
$forceTaskValidate = $forceReleaseText.IndexOf(
    'Assert-RecoveryForceReleaseTask -Task $registered',
    [StringComparison]::Ordinal
)
$forceXmlValidate = $forceReleaseText.IndexOf(
    'Assert-RecoveryForceReleaseTaskXml -Xml $registeredTaskXml',
    [StringComparison]::Ordinal
)
$forceStart = $forceReleaseText.IndexOf(
    'Start-ScheduledTask',
    [StringComparison]::Ordinal
)
$forceProcessValidate = $forceReleaseText.IndexOf(
    'Assert-RecoveryForceReleaseProcess -Process $processes[0]',
    [StringComparison]::Ordinal
)
$forceReceiptValidate = $forceReleaseText.IndexOf(
    '$receiptRead = Assert-ForceReleaseReceipt',
    [StringComparison]::Ordinal
)
$forceFinally = $forceReleaseText.IndexOf(
    '} finally {',
    [StringComparison]::Ordinal
)
$forceStop = $forceReleaseText.IndexOf(
    'Stop-ScheduledTask',
    $forceFinally,
    [StringComparison]::Ordinal
)
$forceProcessZero = $forceReleaseText.IndexOf(
    'Wait-RecoveryForceReleaseProcessAbsent',
    $forceStop,
    [StringComparison]::Ordinal
)
$forceUnregister = $forceReleaseText.IndexOf(
    'Unregister-ScheduledTask',
    $forceProcessZero,
    [StringComparison]::Ordinal
)
$forceAbsent = $forceReleaseText.IndexOf(
    'Recovery force-release one-shot task was not removed',
    $forceUnregister,
    [StringComparison]::Ordinal
)
if ($forceRegister -lt 0 -or $forceTaskValidate -le $forceRegister -or
    $forceXmlValidate -le $forceTaskValidate -or $forceStart -le $forceXmlValidate -or
    $forceProcessValidate -le $forceStart -or
    $forceReceiptValidate -le $forceProcessValidate -or
    $forceFinally -le $forceReceiptValidate -or $forceStop -le $forceFinally -or
    $forceProcessZero -le $forceStop -or
    $forceUnregister -le $forceProcessZero -or $forceAbsent -le $forceUnregister) {
    throw 'Recovery force-release Session-1 task ordering changed'
}

$restoreFunction = $ast.Find(
    {
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $Node.Name -ceq 'Restore-FileAtomically'
    },
    $true
)
$restoreText = $restoreFunction.Extent.Text
if ($restoreText.IndexOf(
        '[System.IO.File]::Replace($temporary, $Destination, $null',
        [StringComparison]::OrdinalIgnoreCase
    ) -ge 0 -or
    @($restoreFunction.Body.FindAll(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $Node.Member.Value -ceq 'Replace'
        },
        $true
    )).Count -ne 2 -or
    $restoreText.IndexOf('$replacementBackup,', [StringComparison]::Ordinal) -lt 0 -or
    $restoreText.IndexOf('$failedReplacement,', [StringComparison]::Ordinal) -lt 0 -or
    $restoreText.IndexOf(
        "-Name 'Recovered pre-rollback destination'",
        [StringComparison]::Ordinal
    ) -lt 0 -or
    $restoreText.IndexOf(
        "-Name 'Durable rollback source artifact after recovery'",
        [StringComparison]::Ordinal
    ) -lt 0) {
    throw 'Rollback PS5.1 replacement/recovery contract changed'
}

$source = [System.IO.File]::ReadAllText($RollbackPath)
foreach ($requiredFragment in @(
    "state -cne 'viewflow-windows-rollback-armed'",
    "state -cne 'viewflow-windows-rollback-authorized'",
    "state = 'viewflow-windows-rollback-completed'",
    '$manifest.schema_version -ne 2',
    "'rollback_nonce', 'force_release_tool', 'recovery_bundle_path'",
    "'candidate_sha256', 'token_path', 'token_sha256'",
    "'binary_path', 'binary_sha256', 'wrapper_path', 'wrapper_sha256'",
    "'task_xml_path', 'task_xml_sha256'",
    '$manifest.installed.binary_sha256 -cne',
    '$manifest.candidate_sha256',
    "'^backup-[0-9]{8}-[0-9]{6}-[0-9a-f]{8}$'",
    '$currentBinarySha256 = Assert-FileHashOneOf',
    '$currentWrapperSha256 = Assert-FileHashOneOf',
    'A Ready Viewflow task must have zero exact installed processes',
    'A Running Viewflow task must have exactly one installed process',
    '$manifest.token_sha256 -cne $tokenSha256',
    'Assert-SamePath -Actual $manifestTokenPath -Expected $TokenPath',
    '$tokenCreatedAt -gt $manifestCreatedAt',
    '$stableObservationMs = 6000',
    'Assert-PairwiseDistinctPaths -Bindings $allTransactionPaths',
    'Assert-DistinctFileIdentities -Bindings $privateEvidenceBindings',
    "state -cne 'viewflow-cross-host-recovery-authorized'",
    "state -cne 'viewflow-linux-deactivated'",
    '$Proof.schema_version -ne 3',
    "@('bootstrap-v1.3', 'normal-v2') -cnotcontains `$rollbackMode",
    "Bootstrap rollback requires deactivation proof and transcript paths",
    "Normal daemon-exit evidence paths are forbidden for bootstrap rollback",
    "Normal rollback requires runtime receipt, compact evidence, and raw observation paths",
    "Bootstrap deactivation evidence paths are forbidden for normal rollback",
    "'schema_version', 'state', 'rollback_mode', 'operation_id'",
    "'schema_version', 'state', 'rollback_mode', 'operation_id', 'user_sid'",
    '$token.rollback_mode -cne $rollbackMode',
    "'runtime_receipt_file_name', 'runtime_receipt_sha256'",
    "'daemon_exit_evidence_file_name'",
    "'daemon_exit_evidence_sha256'",
    "'daemon_exit_observation_file_name'",
    "'daemon_exit_observation_sha256'",
    "'bound_peer_epoch', 'bound_peer_socket', 'source_display'",
    "'route_generation'",
    '$cleanup.source_display -cne $expectedSourceDisplayId',
    '$revokeAck.operation_id.Substring(0, 16) -cne',
    "('{0:x16}' -f [long]`$cleanup.bound_peer_epoch)",
    '-RollbackMode $rollbackMode',
    '-RuntimeReceiptSha256',
    '-DaemonExitEvidenceSha256',
    '-ObservationSha256',
    '$primaryLinuxEvidenceSha256 = [string]$proofRead.Sha256',
    '$primaryLinuxEvidenceSha256 = [string]$daemonExitEvidenceRead.Sha256',
    '-LinuxEvidenceSha256 $primaryLinuxEvidenceSha256',
    "Linux deactivation proof identity is invalid",
    "Linux installed_artifacts",
    'deployment_marker_tool =',
    "'/home/wilf/.local/lib/viewflow/viewflow-deployment-marker'",
    "'deployment_marker_tool', 'deskflow', 'viewflow'",
    '$deploymentMarkerTool.exact_process_count',
    "Linux deactivation proof loaded configuration is invalid",
    'Invoke-RecoveryForceRelease',
    '$forceReleaseTaskTimeoutSeconds = 30',
    '$forceReleaseCleanupStableMs = 500',
    'Viewflow rollback force-release one-shot',
    '-LogonType Interactive -RunLevel Limited',
    'Assert-RecoveryForceReleaseTaskXml -Xml $registeredTaskXml',
    'Start-ScheduledTask -TaskPath $contract.TaskPath',
    '[long]$Process.SessionId -ne 1',
    'Recovery force-release process identity changed',
    'Get-ScheduledTaskInfo -TaskPath $contract.TaskPath',
    'Assert-ForceReleaseReceipt -Path $ReceiptPath',
    'Wait-RecoveryForceReleaseProcessAbsent',
    'Unregister-ScheduledTask -TaskPath $contract.TaskPath',
    'Recovery force-release one-shot task was not removed',
    '$forceReleaseTaskContract = Get-RecoveryForceReleaseTaskContract',
    'Assert-RecoveryForceReleasePreflight -Contract $forceReleaseTaskContract',
    '.rollback.replace-backup',
    '.rollback.failed-replacement',
    '[System.IO.File]::Replace(',
    '$replacementBackup,',
    '$failedReplacement,',
    "Name = 'Backup binary transaction source'",
    "Name = 'Backup wrapper transaction source'",
    'Independently exported restored task XML does not match the backup',
    '$allowLegacyCurrentTask = (',
    '$currentBinarySha256 -ceq [string]$manifest.backup.binary_sha256 -and',
    '$currentWrapperSha256 -ceq [string]$manifest.backup.wrapper_sha256',
    '-AllowLegacyLogonTrigger:$allowLegacyCurrentTask',
    "state = 'viewflow-windows-rollback-validation-succeeded'",
    '$tokenConsumed = $false',
    '$tokenConsumed = $true',
    '[System.IO.File]::Move($TokenPath, $consumedTokenPath)',
    '''{0}.consumed.{1}{2}'' -f @(',
    'Read-VerifiedUtf16TaskXml -Path $backupTaskXml',
    'Assert-TaskXmlContract -Xml $taskXml -AllowLegacyLogonTrigger',
    'Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName',
    'Assert-RestoredScheduledTaskContract -Task $restoredTask `',
    '-AllowLegacyLogonTrigger',
    "Backup task XML legacy trigger is not an exact LogonTrigger",
    "Backup task XML legacy LogonTrigger has an unexpected child set",
    "Backup task XML legacy LogonTrigger must be enabled",
    "Backup task XML legacy LogonTrigger user does not match the current user",
    '$runLevel.Count -gt 1',
    '$runLevelNodes.Count -gt 1',
    '$runLevelNodes.Count -eq 1',
    'Recovery force-release task XML principal changed',
    'MultipleInstancesPolicy = ''IgnoreNew''',
    "foreach (`$optionalTrueSetting in @('AllowHardTerminate', 'Enabled'))",
    "Backup task XML must not contain a restart-on-failure policy",
    'Viewflow process command line',
    'consumed_token_path = $consumedTokenPath',
    'exact_process_count = 0',
    'Assert-OwnerOnlyFileSecurity -Path $Path -Name ''Rollback receipt'''
)) {
    if ($source.IndexOf($requiredFragment, [StringComparison]::Ordinal) -lt 0) {
        throw "Rollback source contract fragment is missing: $requiredFragment"
    }
}

$privateEvidenceStart = $source.IndexOf(
    '$privateEvidenceBindings = @(',
    [StringComparison]::Ordinal
)
$privateEvidenceEnd = $source.IndexOf(
    'Assert-DistinctFileIdentities -Bindings $privateEvidenceBindings',
    [StringComparison]::Ordinal
)
if ($privateEvidenceStart -lt 0 -or $privateEvidenceEnd -le $privateEvidenceStart) {
    throw 'Rollback private-evidence identity gate was not found'
}
$privateEvidenceSection = $source.Substring(
    $privateEvidenceStart,
    $privateEvidenceEnd - $privateEvidenceStart
)
foreach ($normalEvidencePath in @(
    '$RuntimeReceiptPath',
    '$DaemonExitEvidencePath',
    '$DaemonExitObservationPath'
)) {
    if ($privateEvidenceSection.IndexOf(
            $normalEvidencePath,
            [StringComparison]::Ordinal
        ) -lt 0) {
        throw "Normal-v2 evidence must enter the private file-identity gate: $normalEvidencePath"
    }
}

$claimBindingsStart = $source.IndexOf(
    '$claimBindings = @(',
    [StringComparison]::Ordinal
)
$claimBindingsEnd = $source.IndexOf(
    'foreach ($claimBinding in $claimBindings)',
    [StringComparison]::Ordinal
)
if ($claimBindingsStart -lt 0 -or $claimBindingsEnd -le $claimBindingsStart) {
    throw 'Rollback exclusive evidence-claim section was not found'
}
$claimBindingsSection = $source.Substring(
    $claimBindingsStart,
    $claimBindingsEnd - $claimBindingsStart
)
foreach ($normalEvidencePath in @(
    '$RuntimeReceiptPath',
    '$DaemonExitEvidencePath',
    '$DaemonExitObservationPath'
)) {
    if ($claimBindingsSection.IndexOf(
            $normalEvidencePath,
            [StringComparison]::Ordinal
        ) -lt 0) {
        throw "Normal-v2 evidence must enter the exclusive file claim: $normalEvidencePath"
    }
}
foreach ($forbiddenFragment in @(
    'install-viewflow.ps1',
    '-ErrorAction Ignore',
    'Stop-Process',
    'Start-Process',
    '[System.IO.File]::Replace($temporary, $Destination, $null',
    'Remove-Item -LiteralPath $TokenPath'
)) {
    if ($source.IndexOf($forbiddenFragment, [StringComparison]::OrdinalIgnoreCase) `
        -ge 0) {
        throw "Rollback source contains forbidden text: $forbiddenFragment"
    }
}

$validateGate = $source.LastIndexOf('if ($ValidateOnly)', [StringComparison]::Ordinal)
$legacyArtifactGate = $source.LastIndexOf(
    '$allowLegacyCurrentTask = (',
    [StringComparison]::Ordinal
)
$currentBoundaryCheck = $source.LastIndexOf(
    '-AllowLegacyLogonTrigger:$allowLegacyCurrentTask',
    [StringComparison]::Ordinal
)
$forceReleasePreflight = $source.LastIndexOf(
    'Assert-RecoveryForceReleasePreflight -Contract $forceReleaseTaskContract',
    [StringComparison]::Ordinal
)
$backupOwnerOnlyGate = $source.IndexOf(
    '$backupAclBinding in @(',
    [StringComparison]::Ordinal
)
$backupOwnerOnlyValidation = if ($backupOwnerOnlyGate -lt 0) {
    -1
} else {
    $source.IndexOf(
        'Assert-OwnerOnlyFileSecurity -Path $backupAclBinding.Path',
        $backupOwnerOnlyGate,
        [StringComparison]::Ordinal
    )
}
$tokenConsume = $source.IndexOf(
    '[System.IO.File]::Move($TokenPath, $consumedTokenPath)',
    [StringComparison]::Ordinal
)
$taskXmlRead = $source.IndexOf(
    'Read-VerifiedUtf16TaskXml -Path $backupTaskXml',
    [StringComparison]::Ordinal
)
$taskXmlValidation = $source.IndexOf(
    'Assert-TaskXmlContract -Xml $taskXml -AllowLegacyLogonTrigger',
    [StringComparison]::Ordinal
)
$transactionTry = $source.IndexOf(
    '$evidenceClaims = @()',
    [StringComparison]::Ordinal
)
$exclusiveClaim = $source.IndexOf(
    '$evidenceClaims += Open-PrivateFileClaim',
    [StringComparison]::Ordinal
)
$forceRelease = $source.IndexOf(
    '$forceReleaseReceiptRead = Invoke-RecoveryForceRelease',
    [StringComparison]::Ordinal
)
$stableStop = $source.IndexOf(
    'Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName',
    $forceRelease,
    [StringComparison]::Ordinal
)
$restore = $source.IndexOf(
    'Restore-FileAtomically -Source $backupBinary',
    [StringComparison]::Ordinal
)
$register = $source.IndexOf(
    'Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName',
    $restore,
    [StringComparison]::Ordinal
)
$postRestoreStop = if ($register -lt 0) {
    -1
} else {
    $source.IndexOf(
        'Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName',
        $register,
        [StringComparison]::Ordinal
    )
}
$postRestoreBoundary = if ($postRestoreStop -lt 0) {
    -1
} else {
    $source.IndexOf(
        "Wait-ReadyInactiveBoundary -Context 'Post-restore rollback boundary'",
        $postRestoreStop,
        [StringComparison]::Ordinal
    )
}
if ($legacyArtifactGate -lt 0 -or
    $currentBoundaryCheck -le $legacyArtifactGate -or
    $forceReleasePreflight -le $currentBoundaryCheck -or
    $backupOwnerOnlyGate -lt 0 -or
    $backupOwnerOnlyValidation -le $backupOwnerOnlyGate -or
    $validateGate -le $backupOwnerOnlyValidation -or
    $validateGate -le $forceReleasePreflight -or $taskXmlRead -lt 0 -or
    $taskXmlValidation -le $taskXmlRead -or
    $validateGate -le $taskXmlValidation -or
    $transactionTry -le $validateGate -or $exclusiveClaim -le $transactionTry -or
    $tokenConsume -le $exclusiveClaim -or $forceRelease -le $tokenConsume -or
    $stableStop -le $forceRelease -or $restore -le $stableStop -or
    $register -le $restore -or $postRestoreStop -le $register -or
    $postRestoreBoundary -le $postRestoreStop) {
    throw 'Rollback mutation ordering changed'
}

Write-Output 'viewflow standalone rollback static/AST fixture passed'
