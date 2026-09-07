param(
    [string]$LauncherPath = (Join-Path $PSScriptRoot 'start-viewflow-bootstrap.ps1')
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) {
    throw 'This fixture must run under Windows PowerShell 5.1'
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "Expected fixture case to fail: $Name" }
}

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $LauncherPath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "Launcher has $($parseErrors.Count) parser error(s)"
}
$launcherText = [IO.File]::ReadAllText($LauncherPath)
if ($launcherText -notmatch 'Join-Path \$env:SystemRoot ''System32\\conhost\.exe''') {
    throw 'Stop descendant allowance must pin conhost to System32'
}
if ($launcherText -match 'Join-Path \$env:SystemRoot ''conhost\.exe''') {
    throw 'Stop descendant allowance must reject non-System32 conhost'
}
function Test-IsTopLevelCommand {
    param([Management.Automation.Language.CommandAst]$CommandAst)
    $cursor = $CommandAst.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [Management.Automation.Language.FunctionDefinitionAst]) {
            return $false
        }
        $cursor = $cursor.Parent
    }
    return $true
}
$functionAsts = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true))
foreach ($functionAst in $functionAsts) {
    Invoke-Expression $functionAst.Extent.Text
}

$setOperationAclCalls = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Set-AndAssert-OperationAcl'
}, $true) | Where-Object { Test-IsTopLevelCommand $_ })
if ($setOperationAclCalls.Count -ne 1) {
    throw 'Set-AndAssert-OperationAcl call must occur exactly once'
}
$assertOperationAclCalls = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Assert-OperationAcl'
}, $true) | Where-Object { Test-IsTopLevelCommand $_ })
if ($assertOperationAclCalls.Count -ne 1) {
    throw 'Assert-OperationAcl call must occur exactly once'
}
$aclDispatch = $null
$cursor = $setOperationAclCalls[0]
while ($null -ne $cursor) {
    if ($cursor -is [Management.Automation.Language.IfStatementAst] -and
        $cursor.Clauses.Count -eq 1 -and
        $cursor.Clauses[0].Item1.Extent.Text -ceq '$Mode -ceq ''Start''' -and
        $cursor.Clauses[0].Item2.Extent.StartOffset -le
            $setOperationAclCalls[0].Extent.StartOffset -and
        $cursor.Clauses[0].Item2.Extent.EndOffset -ge
            $setOperationAclCalls[0].Extent.EndOffset) {
        $aclDispatch = $cursor
        break
    }
    $cursor = $cursor.Parent
}
if ($null -eq $aclDispatch) {
    throw 'Set-AndAssert-OperationAcl must only be reachable from Start'
}
if ($null -eq $aclDispatch.ElseClause -or
    $aclDispatch.ElseClause.Extent.StartOffset -gt
        $assertOperationAclCalls[0].Extent.StartOffset -or
    $aclDispatch.ElseClause.Extent.EndOffset -lt
        $assertOperationAclCalls[0].Extent.EndOffset) {
    throw 'Worker, Status, and Stop must use Assert-OperationAcl'
}
$writerAst = @($functionAsts | Where-Object {
    $_.Name -ceq 'Write-OwnerSystemCreateOnceBytes'
})
if ($writerAst.Count -ne 1 -or
    $writerAst[0].Extent.Text -cnotmatch 'FileSecurity\]::new' -or
    $writerAst[0].Extent.Text -cnotmatch 'FileStream\]::new' -or
    $writerAst[0].Extent.Text -cnotmatch '\[IO\.FileMode\]::CreateNew' -or
    $writerAst[0].Extent.Text -cnotmatch '\[IO\.File\]::Move\(\$temporary, \$Path\)') {
    throw 'create-once writer must create secured temp bytes then Move them'
}
$writerSetAclCalls = @($writerAst[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Set-Acl'
}, $true))
if ($writerSetAclCalls.Count -ne 0) {
    throw 'create-once writer must not call Set-Acl'
}
$workerAst = @($functionAsts | Where-Object { $_.Name -ceq 'Invoke-Worker' })
if ($workerAst.Count -ne 1) {
    throw 'Invoke-Worker AST was not found exactly once'
}
$successReceiptAssertions = @($workerAst[0].FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq 'Assert-OwnerOnlyRegularFile' -and
        $node.Extent.Text -cmatch
            '-Path \$Request\.install_success_receipt_path' -and
        $node.Extent.Text -cmatch '-OwnerSid \$CurrentSid' -and
        $node.Extent.Text -cmatch 'Windows install-success receipt'
}, $true))
if ($successReceiptAssertions.Count -ne 1) {
    throw 'Invoke-Worker must contain exactly one success receipt assertion'
}
$successReceiptGuard = $null
$cursor = $successReceiptAssertions[0]
while ($null -ne $cursor) {
    if ($cursor -is [Management.Automation.Language.IfStatementAst] -and
        $cursor.Clauses.Count -eq 1 -and
        $cursor.Clauses[0].Item1.Extent.Text -ceq '$exitCode -eq 0' -and
        $cursor.Clauses[0].Item2.Extent.StartOffset -le
            $successReceiptAssertions[0].Extent.StartOffset -and
        $cursor.Clauses[0].Item2.Extent.EndOffset -ge
            $successReceiptAssertions[0].Extent.EndOffset) {
        $successReceiptGuard = $cursor
        break
    }
    $cursor = $cursor.Parent
}
if ($null -eq $successReceiptGuard) {
    throw 'success receipt assertion must be guarded by child exit code zero'
}
if ($workerAst[0].Extent.Text -cnotmatch '(?s)\.WaitForExit\(\).*\$exitCode = \[int\]\$child\.ExitCode.*Assert-OwnerOnlyRegularFile') {
    throw 'Windows success receipt must be owner-only regular after child completion'
}

$maximumJsonInteger = 9007199254740991L
$deploymentTaskPath = '\'
$expectedPeer = '172.16.105.62:44119'
$expectedServerName = 'viewflow-linux'
$expectedLocalDeviceId = '00000000000000000000000000000001'
$expectedDeviceId = '00000000000000000000000000000002'
$expectedSourceDisplayId = '00000000000000000000000000000101'
$fixtureRoot = Join-Path $env:TEMP (
    'viewflow-bootstrap-launcher-' + [Guid]::NewGuid().ToString('N')
)
$operationId = '0123456789abcdef0123456789abcdef'
$operationRoot = Join-Path $fixtureRoot $operationId
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = $currentIdentity.User.Value
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId

try {
    New-Item -ItemType Directory -Path $operationRoot | Out-Null
    Set-AndAssert-OperationAcl -Path $operationRoot -OwnerSid $currentSid
    $fixed = Get-FixedOperationPaths -OperationRoot $operationRoot
    foreach ($name in @(
        'launcher_path', 'installer_path', 'candidate_path', 'wrapper_path',
        'rollback_script_path', 'marker_handoff_receipt_path',
        'linux_frozen_evidence_path'
    )) {
        Write-OwnerSystemCreateOnceBytes -Path $fixed[$name] -Bytes (
            [Text.UTF8Encoding]::new($false).GetBytes("fixture-$name`n")
        )
    }
    $requestValues = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-requested'
        operation_id = $operationId
        user_sid = $currentSid
        expected_session_id = 1
        expected_peer = $expectedPeer
        expected_server_name = $expectedServerName
        expected_local_device_id = $expectedLocalDeviceId
        expected_device_id = $expectedDeviceId
        expected_source_display_id = $expectedSourceDisplayId
        launcher_path = [IO.Path]::GetFullPath($fixed.launcher_path)
        launcher_sha256 = Get-Sha256Lower $fixed.launcher_path
        installer_path = [IO.Path]::GetFullPath($fixed.installer_path)
        installer_sha256 = Get-Sha256Lower $fixed.installer_path
        candidate_path = [IO.Path]::GetFullPath($fixed.candidate_path)
        candidate_sha256 = Get-Sha256Lower $fixed.candidate_path
        wrapper_path = [IO.Path]::GetFullPath($fixed.wrapper_path)
        wrapper_sha256 = Get-Sha256Lower $fixed.wrapper_path
        rollback_script_path = [IO.Path]::GetFullPath($fixed.rollback_script_path)
        rollback_script_sha256 = Get-Sha256Lower $fixed.rollback_script_path
        marker_handoff_receipt_path = [IO.Path]::GetFullPath(
            $fixed.marker_handoff_receipt_path
        )
        marker_handoff_receipt_sha256 = Get-Sha256Lower `
            $fixed.marker_handoff_receipt_path
        linux_frozen_evidence_path = [IO.Path]::GetFullPath(
            $fixed.linux_frozen_evidence_path
        )
        linux_frozen_evidence_sha256 = Get-Sha256Lower `
            $fixed.linux_frozen_evidence_path
        prepared_receipt_path = [IO.Path]::GetFullPath($fixed.prepared_receipt_path)
        mutation_permit_path = [IO.Path]::GetFullPath($fixed.mutation_permit_path)
        raw_force_release_receipt_path = [IO.Path]::GetFullPath(
            $fixed.raw_force_release_receipt_path
        )
        force_release_envelope_path = [IO.Path]::GetFullPath(
            $fixed.force_release_envelope_path
        )
        linux_stage_receipt_path = [IO.Path]::GetFullPath(
            $fixed.linux_stage_receipt_path
        )
        install_success_receipt_path = [IO.Path]::GetFullPath(
            $fixed.install_success_receipt_path
        )
        installer_exit_receipt_path = [IO.Path]::GetFullPath(
            $fixed.installer_exit_receipt_path
        )
        readiness_receipt_path = [IO.Path]::GetFullPath($fixed.readiness_receipt_path)
        readiness_lock_path = [IO.Path]::GetFullPath($fixed.readiness_lock_path)
        readiness_commit_request_path = [IO.Path]::GetFullPath(
            $fixed.readiness_commit_request_path
        )
        rollback_manifest_path = [IO.Path]::GetFullPath($fixed.rollback_manifest_path)
        rollback_token_path = [IO.Path]::GetFullPath($fixed.rollback_token_path)
        recovery_bundle_path = [IO.Path]::GetFullPath($fixed.recovery_bundle_path)
        linux_deactivation_proof_path = [IO.Path]::GetFullPath(
            $fixed.linux_deactivation_proof_path
        )
        linux_deactivation_transcript_path = [IO.Path]::GetFullPath(
            $fixed.linux_deactivation_transcript_path
        )
        recovery_force_release_receipt_path = [IO.Path]::GetFullPath(
            $fixed.recovery_force_release_receipt_path
        )
        created_at_utc = '2026-08-29T12:34:56.789Z'
    }
    $request = [pscustomobject]$requestValues
    Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
        -CurrentUserSid $currentSid -CurrentSessionId 1 -RequireFreshOutputs

    $requestWithUnknown = $request | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $requestWithUnknown | Add-Member NoteProperty unknown_field 'forbidden'
    Assert-Throws -Name 'unknown request field' -Action {
        Assert-BootstrapRequest -Request $requestWithUnknown `
            -OperationRoot $operationRoot -CurrentUserSid $currentSid `
            -CurrentSessionId 1
    }
    $badHash = $request | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $badHash.candidate_sha256 = 'A' * 64
    Assert-Throws -Name 'uppercase artifact hash' -Action {
        Assert-BootstrapRequest -Request $badHash -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1
    }
    $badPath = $request | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $badPath.prepared_receipt_path = Join-Path $operationRoot 'outputs\different.json'
    Assert-Throws -Name 'non-fixed output path' -Action {
        Assert-BootstrapRequest -Request $badPath -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1
    }

    $originalEvidencePath = $fixed.linux_frozen_evidence_path
    $consumedEvidencePath = Get-ConsumedLinuxFrozenEvidencePath `
        -OperationRoot $operationRoot -OperationId $operationId
    $originalEvidenceBytes = [IO.File]::ReadAllBytes($originalEvidencePath)
    Write-OwnerSystemCreateOnceBytes -Path $consumedEvidencePath `
        -Bytes $originalEvidenceBytes
    Assert-Throws -Name 'original plus consumed evidence' -Action {
        Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1 `
            -AllowConsumedLinuxFrozenEvidence
    }
    Remove-Item -LiteralPath $consumedEvidencePath -Force

    [IO.File]::Move($originalEvidencePath, $consumedEvidencePath)
    Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
        -CurrentUserSid $currentSid -CurrentSessionId 1 `
        -AllowConsumedLinuxFrozenEvidence
    Assert-Throws -Name 'Start or Worker consumed evidence' -Action {
        Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1
    }
    Remove-Item -LiteralPath $consumedEvidencePath -Force

    Write-OwnerSystemCreateOnceBytes -Path $consumedEvidencePath `
        -Bytes ([byte[]]($originalEvidenceBytes + [byte]0))
    Assert-Throws -Name 'wrong consumed evidence hash' -Action {
        Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1 `
            -AllowConsumedLinuxFrozenEvidence
    }
    Remove-Item -LiteralPath $consumedEvidencePath -Force

    $extraConsumedEvidencePath = Join-Path $operationRoot (
        'linux-v13-frozen-evidence.consumed.ffffffffffffffffffffffffffffffff.json'
    )
    Write-OwnerSystemCreateOnceBytes -Path $consumedEvidencePath `
        -Bytes $originalEvidenceBytes
    Write-OwnerSystemCreateOnceBytes -Path $extraConsumedEvidencePath `
        -Bytes $originalEvidenceBytes
    Assert-Throws -Name 'multiple consumed evidence candidates' -Action {
        Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1 `
            -AllowConsumedLinuxFrozenEvidence
    }
    Remove-Item -LiteralPath $consumedEvidencePath -Force
    Remove-Item -LiteralPath $extraConsumedEvidencePath -Force

    New-Item -ItemType Directory -Path $consumedEvidencePath | Out-Null
    Assert-Throws -Name 'unsafe consumed evidence candidate' -Action {
        Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1 `
            -AllowConsumedLinuxFrozenEvidence
    }
    Remove-Item -LiteralPath $consumedEvidencePath -Force
    Write-OwnerSystemCreateOnceBytes -Path $originalEvidencePath `
        -Bytes $originalEvidenceBytes

    $createOncePath = Join-Path $operationRoot 'create-once.bin'
    Write-OwnerSystemCreateOnceBytes -Path $createOncePath `
        -Bytes ([byte[]](1, 2, 3, 4))
    Assert-Throws -Name 'create-once replay' -Action {
        Write-OwnerSystemCreateOnceBytes -Path $createOncePath `
            -Bytes ([byte[]](5))
    }
    $duplicateJsonPath = Join-Path $operationRoot 'duplicate.json'
    [IO.File]::WriteAllText(
        $duplicateJsonPath,
        "{`"field`":1,`"field`":2}`n",
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Throws -Name 'duplicate JSON key' -Action {
        $null = Read-StrictJsonBytes -Path $duplicateJsonPath
    }

    $requestPath = Join-Path $operationRoot 'request.json'
    Write-OwnerSystemCreateOnceJson -Path $requestPath -Value $request
    $requestRead = Read-StrictJsonBytes -Path $requestPath
    $requestSha = Get-BytesSha256Lower -Bytes $requestRead.Bytes
    $taskContract = Get-TaskContract -LauncherPath $request.launcher_path `
        -RequestPath $requestPath -OperationRoot $operationRoot `
        -OperationId $operationId
    $installerContract = Get-InstallerContract -Request $request `
        -RequestPath $requestPath
    if ($installerContract.Arguments -cnotmatch '-BootstrapRequestPath' -or
        $installerContract.Arguments -match '-CandidatePath') {
        throw 'Installer command must derive bootstrap arguments only from request.json'
    }

    $script:registeredTask = $null
    $script:registerHadTrigger = $false
    function global:New-ScheduledTaskAction {
        param($Execute, $Argument, $WorkingDirectory)
        [pscustomobject]@{
            Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory
        }
    }
    function global:New-ScheduledTaskPrincipal {
        param($UserId, $LogonType, $RunLevel)
        [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
    }
    function global:New-ScheduledTaskSettingsSet {
        param(
            $MultipleInstances, [switch]$AllowStartIfOnBatteries,
            [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit,
            [uint32]$RestartCount
        )
        [pscustomobject]@{
            MultipleInstances = $MultipleInstances
            RestartCount = $RestartCount
            ExecutionTimeLimit = 'PT0S'
            DisallowStartIfOnBatteries = $false
            StopIfGoingOnBatteries = $false
        }
    }
    function global:Register-ScheduledTask {
        param(
            $TaskPath, $TaskName, $Action, $Principal, $Settings,
            $Description, $Trigger, $ErrorAction
        )
        $script:registerHadTrigger = $PSBoundParameters.ContainsKey('Trigger')
        $script:registeredTask = [pscustomobject]@{
            State = 'Ready'; Triggers = @(); Actions = @($Action)
            Principal = $Principal; Settings = $Settings
        }
        $script:registeredTask
    }
    Register-BootstrapTask -Contract $taskContract -UserName $currentIdentity.Name
    if ($script:registerHadTrigger -or $null -eq $script:registeredTask) {
        throw 'Bootstrap task registration was not trigger-free'
    }
    Assert-BootstrapTask -Task $script:registeredTask -Contract $taskContract `
        -UserSid $currentSid

    $taskXmlSha = Get-TextSha256Lower '<Task fixture="true" />'
    $claimPath = Join-Path $operationRoot 'launcher-claim.json'
    $self = Get-Process -Id $PID
    $claim = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-claimed'
        operation_id = $operationId
        pid = [int]$PID
        process_start_filetime_utc = Get-ProcessStartFileTimeUtc $self
        owner_sid = $currentSid
        session_id = 1
        worker_executable_path = $taskContract.PowerShell
        launcher_path = $request.launcher_path
        launcher_sha256 = $request.launcher_sha256
        request_sha256 = $requestSha
        task_name = $taskContract.TaskName
        task_xml_sha256 = $taskXmlSha
        task_command_sha256 = $taskContract.CommandSha256
        installer_command_sha256 = $installerContract.CommandSha256
        claimed_at_utc = '2026-08-29T12:35:00.000Z'
    }
    Write-OwnerSystemCreateOnceJson -Path $claimPath -Value $claim
    $claimRead = Read-AndValidateClaim -ClaimPath $claimPath `
        -OperationId $operationId -RequestSha256 $requestSha `
        -TaskContract $taskContract -TaskXmlSha256 $taskXmlSha `
        -InstallerContract $installerContract -LauncherPath $request.launcher_path `
        -LauncherSha256 $request.launcher_sha256 `
        -ExpectedOwnerSid $currentSid -ExpectedSessionId 1
    $liveClaim = $claimRead | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $liveClaim.session_id = [int]$self.SessionId
    if (-not (Test-ClaimProcessLive -Claim $liveClaim)) {
        throw 'Current launcher claim was not recognized as live'
    }
    $deadClaim = $liveClaim | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $deadClaim.pid = 2147483647
    if (Test-ClaimProcessLive -Claim $deadClaim) {
        throw 'Absent process was recognized as a live launcher claim'
    }

    $claimSha = Get-Sha256Lower $claimPath
    $terminal = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-succeeded'
        operation_id = $operationId
        exit_code = 0
        request_sha256 = $requestSha
        claim_sha256 = $claimSha
        installer_command_sha256 = $installerContract.CommandSha256
        completed_at_utc = '2026-08-29T12:36:00.000Z'
    }
    Write-OwnerSystemCreateOnceJson -Path $request.installer_exit_receipt_path `
        -Value $terminal
    $terminalRead = Read-TerminalReceipt `
        -Path $request.installer_exit_receipt_path -OperationId $operationId `
        -RequestSha256 $requestSha -ClaimSha256 $claimSha `
        -InstallerCommandSha256 $installerContract.CommandSha256
    if ($terminalRead.exit_code -ne 0) {
        throw 'Terminal receipt replay changed the installer exit code'
    }
    $stopPath = Join-Path $operationRoot 'launcher-stop-evidence.json'
    $stopEvidence = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-stopped'
        operation_id = $operationId
        request_sha256 = $requestSha
        claim_sha256 = $claimSha
        task_name = $taskContract.TaskName
        task_xml_sha256 = $taskXmlSha
        worker_pid = [int]$claim.pid
        worker_process_start_filetime_utc =
            [string]$claim.process_start_filetime_utc
        installer_process_count = 0
        task_state = 'Disabled'
        stopped_at_utc = '2026-08-29T12:37:00.000Z'
    }
    Write-OwnerSystemCreateOnceJson -Path $stopPath -Value $stopEvidence
    $stopRead = Read-StopEvidence -Path $stopPath -OperationId $operationId `
        -RequestSha256 $requestSha -ClaimSha256 $claimSha -Claim $claimRead
    if ($stopRead.task_state -cne 'Disabled' -or
        $stopRead.installer_process_count -ne 0) {
        throw 'Stop evidence did not prove a Disabled zero-process boundary'
    }
    $badStop = $stopEvidence | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $badStop.installer_process_count = 1
    $badStopPath = Join-Path $operationRoot 'bad-stop-evidence.json'
    Write-OwnerSystemCreateOnceJson -Path $badStopPath -Value $badStop
    Assert-Throws -Name 'nonzero stopped installer process count' -Action {
        $null = Read-StopEvidence -Path $badStopPath `
            -OperationId $operationId -RequestSha256 $requestSha `
            -ClaimSha256 $claimSha -Claim $claimRead
    }
    Assert-Throws -Name 'terminal receipt overwrite' -Action {
        Write-OwnerSystemCreateOnceJson `
            -Path $request.installer_exit_receipt_path -Value $terminal
    }
    Assert-Throws -Name 'fresh outputs after terminal' -Action {
        Assert-BootstrapRequest -Request $request -OperationRoot $operationRoot `
            -CurrentUserSid $currentSid -CurrentSessionId 1 -RequireFreshOutputs
    }

    Write-Output 'viewflow bootstrap launcher PS5.1 fixture passed'
} finally {
    foreach ($name in @(
        'New-ScheduledTaskAction', 'New-ScheduledTaskPrincipal',
        'New-ScheduledTaskSettingsSet', 'Register-ScheduledTask'
    )) {
        Remove-Item -LiteralPath "Function:\global:$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
