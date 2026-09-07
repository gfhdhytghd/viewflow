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
            throw "Unexpected bootstrap-chain rejection: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected bootstrap-chain rejection was absent: $ExpectedMessage"
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
    'Get-StringSha256Lower', 'Assert-FreshUnixMilliseconds',
    'Assert-V13BootstrapEvidence', 'Assert-FreshUtcTimestamp',
    'Wait-BootstrapMutationPermit',
    'Wait-BootstrapLinuxStageReceipt'
)) {
    Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
}

$fixtureRoot = Join-Path $env:TEMP (
    'viewflow-bootstrap-chain-{0}' -f [Guid]::NewGuid().ToString('N')
)
$permitPath = Join-Path $fixtureRoot 'mutation-permit.json'
$stagePath = Join-Path $fixtureRoot 'linux-stage.json'
$operationId = '0123456789abcdef0123456789abcdef'
$expectedTaskUserSid =
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$expectedSourceDisplayUuid = '00000000-0000-0000-0000-000000000001'
$expectedTargetDeviceUuid = '00000000-0000-0000-0000-000000000002'
$QuiescedMarkerMaxAgeSeconds = 300
$chain = @('1','2','3','4','5','6','7','8','9','a','b','c','d','e','f') |
    ForEach-Object { $_ * 64 }
$now = [DateTimeOffset]::UtcNow.ToString(
    'yyyy-MM-ddTHH:mm:ss.fffZ',
    [Globalization.CultureInfo]::InvariantCulture
)

$bootstrapBootId = '01234567-89ab-cdef-0123-456789abcdef'
$bootstrapInvocationId = '0123456789abcdef0123456789abcdef'
$bootstrapCompletedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$bootstrapTranscript = (
    "systemctl_is_active=inactive`n" +
    "systemctl_main_pid=0`n" +
    "exact_viewflow_pids=`n" +
    "udp_44119_listeners=`n" +
    "sidecar_socket_present=false`n" +
    "original_daemon_pid_present=false`n"
)
$bootstrapEvidence = [pscustomobject][ordered]@{
    schema_version = 1
    state = 'viewflow-v13-bootstrap-frozen'
    operation_id = $operationId
    daemon = [ordered]@{
        pid = 4242
        start_ticks = 123456
        boot_id = $bootstrapBootId
        daemon_instance_id = "$bootstrapBootId-4242-123456"
        sha256 = $chain[0]
        executable = '/home/wilf/.local/lib/viewflow/viewflowd'
        systemd_invocation_id = $bootstrapInvocationId
    }
    journal = [ordered]@{
        query_boot_id = $bootstrapBootId.Replace('-', '')
        query_pid = '4242'
        query_systemd_invocation_id = $bootstrapInvocationId
        start_cursor = 's=1'
        start_realtime_timestamp_us = 1000
        protocol_startup_cursor = 'p=1'
        protocol_startup_realtime_timestamp_us = 1100
        end_cursor = 'e=1'
        end_realtime_timestamp_us = 1200
        entry_count = 1
        slice_sha256 = $chain[1]
        counts = [ordered]@{
            protocol_1_3_startup = 1
            lease_offered = 0
            input_event = 0
            input_sidecar_activation = 0
            cleanup_or_release_error = 0
        }
    }
    pre_stop = [ordered]@{
        deskflow_unit_active_state = 'inactive'
        deskflow_main_pid = 0
        deskflow_exact_process_count = 0
        deskflow_core_exact_process_count = 0
        deskflow_tcp_24800_listener_count = 0
    }
    post_stop = [ordered]@{
        unit_active_state = 'inactive'
        main_pid = 0
        exact_process_count = 0
        udp_44119_listener_count = 0
        sidecar_socket_present = $false
        original_daemon_pid_present = $false
        command_outputs = [ordered]@{
            systemctl_is_active = 'inactive'
            systemctl_main_pid = '0'
            exact_viewflow_pids = ''
            udp_44119_listeners = ''
            sidecar_socket_present = 'false'
            original_daemon_pid_present = 'false'
        }
        command_output_format = 'key=value newline-delimited UTF-8 in displayed order'
        command_output_sha256 = Get-StringSha256Lower -Value $bootstrapTranscript
    }
    completed_at_unix_ms = $bootstrapCompletedAt
}
$bootstrapEvidence = $bootstrapEvidence | ConvertTo-Json -Depth 12 |
    ConvertFrom-Json
$null = Assert-V13BootstrapEvidence -Marker $bootstrapEvidence
$bootstrapEvidence.journal.query_boot_id = $bootstrapBootId
Assert-ThrowsMessage -ExpectedMessage 'Bootstrap journal identity' -Action {
    Assert-V13BootstrapEvidence -Marker $bootstrapEvidence
}
$bootstrapEvidence.journal.query_boot_id = $bootstrapBootId.Replace('-', '')

function global:Assert-PinnedBootstrapRequestCurrent {}
function global:Read-OwnerOnlyUtf8JsonSnapshot {
    param([string]$Path, [string]$Name)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    ).Replace('-', '').ToLowerInvariant()
    [pscustomobject]@{
        Value = ([Text.UTF8Encoding]::new($false, $true).GetString($bytes) |
            ConvertFrom-Json)
        Sha256 = $sha
    }
}

try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $permit = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-mutation-permitted'
        operation_id = $operationId
        user_sid = $expectedTaskUserSid
        coordinator_instance_id = 'coordinator-fixture'
        permit_nonce = $chain[0]
        bootstrap_request_sha256 = $chain[1]
        marker_handoff_receipt_sha256 = $chain[2]
        windows_prepared_receipt_sha256 = $chain[3]
        linux_frozen_evidence_sha256 = $chain[4]
        candidate_sha256 = $chain[5]
        wrapper_sha256 = $chain[6]
        rollback_script_sha256 = $chain[7]
        rollback_manifest_sha256 = $chain[8]
        rollback_token_sha256 = $chain[9]
        linux_viewflowd_sha256 = $chain[10]
        linux_deployment_marker_sha256 = $chain[11]
        linux_viewflow_unit_sha256 = $chain[12]
        issued_at_utc = $now
    }
    [IO.File]::WriteAllText(
        $permitPath,
        (($permit | ConvertTo-Json -Depth 12) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $permitResult = Wait-BootstrapMutationPermit -Path $permitPath `
        -OperationId $operationId -CoordinatorInstanceId 'coordinator-fixture' `
        -BootstrapRequestSha256 $chain[1] -MarkerHandoffSha256 $chain[2] `
        -PreparedReceiptSha256 $chain[3] -LinuxEvidenceSha256 $chain[4] `
        -CandidateSha256 $chain[5] -WrapperSha256 $chain[6] `
        -RollbackScriptSha256 $chain[7] -ManifestSha256 $chain[8] `
        -TokenSha256 $chain[9]

    $markerHandoff = [pscustomobject]@{
        deployment_publish_receipt_sha256 = $chain[13]
        deployment_marker_path = '/home/wilf/.local/state/viewflow/deployment-quarantine.v1'
        deployment_marker_sha256 = $chain[14]
        coordinator_instance_id = 'coordinator-fixture'
        marker_generation = '1'
        marker_cli_sha256 = $chain[11]
        deskflow_executable_sha256 = $chain[8]
        deskflow_core_executable_sha256 = $chain[9]
    }
    $stage = [ordered]@{
        schema_version = 1
        state = 'viewflow-linux-bootstrap-staged'
        operation_id = $operationId
        protocol_version = '2.1'
        source_display_id = $expectedSourceDisplayUuid
        target_device_id = $expectedTargetDeviceUuid
        windows_viewflow_sha256 = $chain[5]
        evidence_hashes = [ordered]@{
            bootstrap_request = $chain[1]
            linux_frozen_evidence = $chain[4]
            marker_handoff_receipt = $chain[2]
            mutation_permit = $permitResult.Sha256
            windows_force_release_envelope = $chain[7]
            windows_prepared_receipt = $chain[3]
            deployment_publish_receipt = $chain[13]
        }
        freeze_state = [ordered]@{
            deskflow_unit_active_state = 'inactive'
            deskflow_unit_main_pid = 0
            deskflow_exact_process_count = 0
            deskflow_core_exact_process_count = 0
            deskflow_tcp_listener_count = 0
            runtime_marker_path = '/home/wilf/.local/state/viewflow/deskflow-quarantine.v2'
            runtime_marker_present = $false
        }
        marker = [ordered]@{
            path = $markerHandoff.deployment_marker_path
            identity = 'VFDQT001-fixture'
            sha256 = $chain[14]
            coordinator_instance_id = 'coordinator-fixture'
            marker_generation = '1'
        }
        artifact_hashes = [ordered]@{
            old_viewflowd = $chain[0]
            old_deployment_marker_tool = $chain[11]
            old_viewflow_unit = $chain[1]
            staged_viewflowd = $chain[10]
            staged_deployment_marker_tool = $chain[11]
            staged_viewflow_unit = $chain[12]
            preserved_deskflow = $chain[8]
            preserved_deskflow_core = $chain[9]
            preserved_deskflow_dropin = $chain[6]
        }
        backup_directory = '/home/wilf/.local/state/viewflow/backups/fixture'
        backup_manifest_sha256 = $chain[5]
        runtime = [ordered]@{
            pid = 4242
            start_ticks = 123456
            boot_id = '01234567-89ab-cdef-0123-456789abcdef'
            invocation_id = '0123456789abcdef0123456789abcdef'
            authenticated_peer_ip = '172.16.105.70'
            authenticated_peer_record_sha256 = $chain[4]
            authenticated_at_unix_ms = 1788048000000
        }
        completed_at_unix_ms = 1788048000001
    }
    [IO.File]::WriteAllText(
        $stagePath,
        (($stage | ConvertTo-Json -Depth 12) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    $common = @{
        Path = $stagePath
        OperationId = $operationId
        BootstrapRequestSha256 = $chain[1]
        MarkerHandoff = $markerHandoff
        MarkerHandoffSha256 = $chain[2]
        PreparedReceiptSha256 = $chain[3]
        MutationPermit = $permitResult.Receipt
        MutationPermitPath = $permitPath
        MutationPermitSha256 = $permitResult.Sha256
        ForceEnvelopeSha256 = $chain[7]
        LinuxEvidenceSha256 = $chain[4]
        WindowsCandidateSha256 = $chain[5]
    }
    $null = Wait-BootstrapLinuxStageReceipt @common

    $stage.artifact_hashes.staged_viewflowd = $chain[6]
    [IO.File]::WriteAllText(
        $stagePath,
        (($stage | ConvertTo-Json -Depth 12) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-ThrowsMessage -ExpectedMessage `
        'Linux stage installed or preserved artifact binding is invalid' -Action {
        Wait-BootstrapLinuxStageReceipt @common
    }

    $permit.linux_viewflowd_sha256 = 'A' * 64
    [IO.File]::WriteAllText(
        $permitPath,
        (($permit | ConvertTo-Json -Depth 12) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Assert-ThrowsMessage -ExpectedMessage 'must be a lowercase' -Action {
        Wait-BootstrapMutationPermit -Path $permitPath `
            -OperationId $operationId `
            -CoordinatorInstanceId 'coordinator-fixture' `
            -BootstrapRequestSha256 $chain[1] -MarkerHandoffSha256 $chain[2] `
            -PreparedReceiptSha256 $chain[3] -LinuxEvidenceSha256 $chain[4] `
            -CandidateSha256 $chain[5] -WrapperSha256 $chain[6] `
            -RollbackScriptSha256 $chain[7] -ManifestSha256 $chain[8] `
            -TokenSha256 $chain[9]
    }
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'viewflow bootstrap permit/Ls chain PS5.1 fixture passed'
