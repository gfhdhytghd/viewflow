param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'install-viewflow.ps1')
)

$ErrorActionPreference = 'Stop'

function Get-InstallerFunctionText {
    param($Ast, [string]$Name)
    $node = $Ast.Find({
        param($candidate)
        $candidate -is
            [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -ceq $Name
    }, $true)
    if ($null -eq $node) { throw "Installer function not found: $Name" }
    $node.Extent.Text
}

function Assert-ThrowsMessage {
    param([scriptblock]$Action, [string]$ExpectedMessage)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Unexpected schema-5 rejection: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected schema-5 rejection was absent: $ExpectedMessage"
}

function Copy-JsonObject {
    param($Value)
    $Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerPath, [ref]$tokens, [ref]$errors
)
if ($errors.Count -ne 0) {
    throw "Installer has $($errors.Count) parser error(s)"
}
foreach ($name in @(
    'Test-JsonInteger', 'Assert-ExactPropertySet', 'Assert-LowerSha256',
    'Assert-FreshUtcTimestamp', 'Assert-DaemonInstallSuccessReceipt'
)) {
    Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
}

$expectedPeer = 'fixture.invalid:44119'
$expectedDeviceId = 'fixture-device'
$expectedTaskUserSid =
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$QuiescedMarkerMaxAgeSeconds = 300
function global:Assert-ViewflowProcessIdentityCurrent {
    param($Identity)
    if ($Identity.ProcessId -ne 4242) { throw 'Unexpected process identity' }
}

$now = [DateTimeOffset]::UtcNow.ToString(
    'yyyy-MM-ddTHH:mm:ss.fffZ',
    [Globalization.CultureInfo]::InvariantCulture
)
$chain = @('a', 'b', 'c', 'd', 'e', 'f') | ForEach-Object { $_ * 64 }
$commitRequest = [pscustomobject]@{
    Nonce = '0123456789abcdef0123456789abcdef'
    Sha256 = '7' * 64
    Mode = 'bootstrap-v1.3'
}
$processIdentity = [pscustomobject]@{
    ProcessId = 4242
    ProcessStartFileTime = '133700000000000000'
    SessionId = 1
    OwnerSid = $expectedTaskUserSid
}
$readiness = [pscustomobject]@{
    ReceiptSha256 = '8' * 64
    LockSha256 = '9' * 64
    ConnectionGeneration = 17
    EstablishedAtUtc = $now
}
$base = [pscustomobject][ordered]@{
    schema_version = 5
    state = 'viewflow-v2-windows-installed'
    operation_id = 'schema5-install-success-fixture'
    commit_nonce = $commitRequest.Nonce
    commit_request_sha256 = $commitRequest.Sha256
    commit_mode = $commitRequest.Mode
    committed_by_daemon = $true
    linux_frozen_evidence_sha256 = '0' * 64
    force_release_receipt_sha256 = $chain[0]
    marker_handoff_receipt_sha256 = $chain[1]
    windows_prepared_receipt_sha256 = $chain[2]
    mutation_permit_sha256 = $chain[3]
    linux_stage_receipt_sha256 = $chain[4]
    bootstrap_request_sha256 = $chain[5]
    readiness_receipt_sha256 = $readiness.ReceiptSha256
    readiness_lock_sha256 = $readiness.LockSha256
    readiness_connection_generation = 17
    readiness_established_at_utc = $now
    old_viewflow_executable_sha256 = '1' * 64
    new_viewflow_executable_sha256 = '2' * 64
    installed_wrapper_sha256 = '3' * 64
    scheduled_task_xml_sha256 = '4' * 64
    new_process_pid = 4242
    new_process_start_filetime = $processIdentity.ProcessStartFileTime
    new_process_session_id = 1
    new_process_user_sid = $expectedTaskUserSid
    protocol_version = '2.1'
    peer = $expectedPeer
    device_id = $expectedDeviceId
    completed_at_utc = $now
    committed_at_utc = $now
}

$common = @{
    CommitRequest = $commitRequest
    OperationId = $base.operation_id
    LinuxEvidenceSha256 = $base.linux_frozen_evidence_sha256
    ForceReceiptSha256 = $chain[0]
    MarkerHandoffReceiptSha256 = $chain[1]
    WindowsPreparedReceiptSha256 = $chain[2]
    MutationPermitSha256 = $chain[3]
    LinuxStageReceiptSha256 = $chain[4]
    BootstrapRequestSha256 = $chain[5]
    OldBinarySha256 = $base.old_viewflow_executable_sha256
    NewBinarySha256 = $base.new_viewflow_executable_sha256
    WrapperSha256 = $base.installed_wrapper_sha256
    TaskXmlSha256 = $base.scheduled_task_xml_sha256
    ProcessIdentity = $processIdentity
    Readiness = $readiness
}
Assert-DaemonInstallSuccessReceipt -Receipt $base @common

$duplicate = Copy-JsonObject $base
$duplicate.bootstrap_request_sha256 = $duplicate.linux_stage_receipt_sha256
$duplicateCommon = @{} + $common
$duplicateCommon.BootstrapRequestSha256 = $chain[4]
Assert-ThrowsMessage -ExpectedMessage 'must be pairwise distinct' -Action {
    Assert-DaemonInstallSuccessReceipt -Receipt $duplicate @duplicateCommon
}

$normal = Copy-JsonObject $base
$normal.commit_mode = 'normal-v2'
foreach ($field in @(
    'force_release_receipt_sha256', 'marker_handoff_receipt_sha256',
    'windows_prepared_receipt_sha256', 'mutation_permit_sha256',
    'linux_stage_receipt_sha256', 'bootstrap_request_sha256'
)) {
    $normal.$field = $null
}
$normalCommit = [pscustomobject]@{
    Nonce = $commitRequest.Nonce
    Sha256 = $commitRequest.Sha256
    Mode = 'normal-v2'
}
$normalCommon = @{} + $common
$normalCommon.CommitRequest = $normalCommit
foreach ($name in @(
    'ForceReceiptSha256', 'MarkerHandoffReceiptSha256',
    'WindowsPreparedReceiptSha256', 'MutationPermitSha256',
    'LinuxStageReceiptSha256', 'BootstrapRequestSha256'
)) {
    $normalCommon[$name] = $null
}
Assert-DaemonInstallSuccessReceipt -Receipt $normal @normalCommon

Write-Output 'viewflow daemon install-success schema-5 PS5.1 fixture passed'
