param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'install-viewflow.ps1')
)

$ErrorActionPreference = 'Stop'

function Get-InstallerFunctionText {
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
        throw "Installer function was not found: $Name"
    }
    $functionAst.Extent.Text
}

function Assert-ExactKeys {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $actual = @($Value.PSObject.Properties | ForEach-Object Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count -or
        (Compare-Object -CaseSensitive -ReferenceObject $expected `
            -DifferenceObject $actual)) {
        throw "$Context has an unexpected property set"
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "Installer has $($parseErrors.Count) PowerShell parser error(s)"
}
foreach ($name in @(
    'Initialize-NativeFileIdentityType',
    'Assert-NoReparseAncestors',
    'Open-SafeDirectoryLease',
    'Assert-SafeDirectoryLeaseCurrent',
    'Assert-NewAbsoluteOutputPath',
    'New-OwnerOnlyFileSecurity',
    'Write-OwnerOnlyCreateOnceBytes',
    'Write-OwnerOnlyCreateOnceJson',
    'Get-FileSha256Lower',
    'New-RandomLowerHex',
    'New-RollbackAuthorization',
    'Write-RollbackManifest'
)) {
    Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
}

$expectedTaskUserSid =
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$expectedTaskName = '\Viewflow Peer'
$fixtureRoot = Join-Path $env:TEMP (
    'viewflow-installer-rollback-union-{0}' -f
        [Guid]::NewGuid().ToString('N')
)
$expectedExecutable = Join-Path $fixtureRoot 'installed\viewflowd.exe'
$installedScript = Join-Path $fixtureRoot 'installed\viewflow-client.ps1'
$sha = 'a' * 64
$commonManifestKeys = @(
    'schema_version', 'state', 'rollback_mode', 'operation_id', 'rollback_nonce',
    'user_sid', 'task_name', 'installed', 'backup', 'candidate_sha256',
    'token_path', 'token_sha256', 'force_release_tool',
    'recovery_bundle_path', 'expected_deactivation_evidence_type',
    'recovery_force_release_receipt_path', 'created_at_utc'
)

try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $null = New-Item -ItemType Directory `
        -Path (Split-Path -Parent $expectedExecutable)

    foreach ($mode in @('bootstrap-v1.3', 'normal-v2')) {
        $modeRoot = Join-Path $fixtureRoot ($mode -replace '[^a-z0-9]', '-')
        $null = New-Item -ItemType Directory -Path $modeRoot
        $tokenPath = Join-Path $modeRoot 'rollback-token.json'
        $manifestPath = Join-Path $modeRoot 'rollback-manifest.json'
        $bundlePath = Join-Path $modeRoot 'recovery-bundle.json'
        $recoveryReceiptPath = Join-Path $modeRoot 'force-release-receipt.json'
        $token = New-RollbackAuthorization -OperationId 'rollback-union-test-001' `
            -RollbackMode $mode -TokenPath $tokenPath

        $arguments = @{
            Path = $manifestPath
            RollbackMode = $mode
            OperationId = 'rollback-union-test-001'
            CandidateSha256 = $sha
            NewWrapperSha256 = $sha
            BackupBinaryPath = (Join-Path $modeRoot 'backup\viewflowd.exe')
            BackupBinarySha256 = $sha
            BackupWrapperPath = (Join-Path $modeRoot 'backup\viewflow-client.ps1')
            BackupWrapperSha256 = $sha
            BackupTaskXmlPath = (Join-Path $modeRoot 'backup\Viewflow-Peer.xml')
            BackupTaskXmlSha256 = $sha
            TokenPath = $tokenPath
            TokenSha256 = $token.Sha256
            RollbackNonce = $token.Nonce
            ForceReleaseToolPath = (Join-Path $modeRoot 'backup\force-release.exe')
            ForceReleaseToolSha256 = $sha
            RecoveryBundlePath = $bundlePath
            RecoveryForceReleaseReceiptPath = $recoveryReceiptPath
        }
        if ($mode -ceq 'bootstrap-v1.3') {
            $arguments.LinuxDeactivationProofPath =
                Join-Path $modeRoot 'linux-deactivation-proof.json'
            $arguments.LinuxDeactivationTranscriptPath =
                Join-Path $modeRoot 'linux-deactivation-transcript.txt'
        } else {
            $arguments.RuntimeReceiptPath =
                Join-Path $modeRoot 'runtime-receipt.json'
            $arguments.DaemonExitEvidencePath =
                Join-Path $modeRoot 'daemon-exit-evidence.json'
            $arguments.DaemonExitObservationPath =
                Join-Path $modeRoot 'daemon-exit-observation.json'
        }
        Write-RollbackManifest @arguments

        $tokenValue = Get-Content -LiteralPath $tokenPath -Raw | ConvertFrom-Json
        Assert-ExactKeys -Value $tokenValue -Context "$mode rollback token" `
            -Names @(
                'schema_version', 'state', 'rollback_mode', 'operation_id',
                'user_sid', 'nonce', 'created_at_utc'
            )
        if ($tokenValue.rollback_mode -cne $mode -or
            $tokenValue.nonce -cne $token.Nonce) {
            throw "$mode rollback token lost its mode or nonce binding"
        }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw |
            ConvertFrom-Json
        $modeKeys = if ($mode -ceq 'bootstrap-v1.3') {
            @('linux_deactivation_proof_path',
                'linux_deactivation_transcript_path')
        } else {
            @('runtime_receipt_path', 'daemon_exit_evidence_path',
                'daemon_exit_observation_path')
        }
        Assert-ExactKeys -Value $manifest -Context "$mode rollback manifest" `
            -Names ($commonManifestKeys + $modeKeys)
        if ($manifest.rollback_mode -cne $mode -or
            $manifest.token_sha256 -cne $token.Sha256 -or
            $manifest.rollback_nonce -cne $token.Nonce -or
            $manifest.user_sid -cne $expectedTaskUserSid -or
            $manifest.task_name -cne $expectedTaskName) {
            throw "$mode rollback manifest lost a hash, nonce, or identity binding"
        }
        if ($mode -ceq 'bootstrap-v1.3' -and
            $null -ne $manifest.PSObject.Properties['daemon_exit_observation_path']) {
            throw 'Bootstrap rollback manifest retained forbidden daemon observation'
        }
        if ($mode -ceq 'bootstrap-v1.3' -and
            $manifest.expected_deactivation_evidence_type -cne
                'schema_version=3;state=viewflow-linux-deactivated') {
            throw 'Bootstrap rollback manifest did not require schema-3 proof'
        }
        if ($mode -ceq 'normal-v2' -and
            ($null -ne $manifest.PSObject.Properties['linux_deactivation_proof_path'] -or
                $null -ne $manifest.PSObject.Properties[
                    'linux_deactivation_transcript_path'
                ])) {
            throw 'Normal rollback manifest retained forbidden bootstrap evidence'
        }
    }

    Write-Output 'viewflow installer rollback union PS5.1 fixture passed'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
