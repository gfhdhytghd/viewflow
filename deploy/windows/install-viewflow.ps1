param(
    [string]$BootstrapRequestPath,

    [string]$CandidatePath,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedSha256,

    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedWrapperSha256,

    # The reviewed marker producer creates this JSON file from the schema-4
    # daemon receipt plus independently captured Linux daemon-exit evidence.
    # The installer consumes that evidence; it never accepts operator booleans.
    [string]$QuiescedMarkerPath,

    [string]$ReadinessReceiptPath,

    [string]$ReadinessLockPath,

    [string]$ReadinessCommitRequestPath,

    [ValidateRange(1, 1800)]
    [int]$QuiescedMarkerMaxAgeSeconds = 300,

    # Explicit one-time protocol-1.3 bootstrap gate. These output paths are
    # required with the switch and forbidden for a normal schema-4 update.
    [switch]$AllowV13Bootstrap,

    [string]$ForceReleaseReceiptPath,

    [string]$InstallSuccessReceiptPath,

    [string]$RollbackManifestPath,

    [string]$RollbackTokenPath,

    [string]$RecoveryBundlePath,

    # Bootstrap-only create-once receipt published before the old peer is
    # stopped. The coordinator waits for this durable recovery boundary before
    # allowing the Linux bootstrap stage to proceed.
    [string]$BootstrapRecoveryPreparedReceiptPath,

    [string]$MarkerHandoffReceiptPath,

    [string]$BootstrapMutationPermitPath,

    [string]$BootstrapForceReleaseEnvelopePath,

    [string]$LinuxStageReceiptPath,

    [string]$BootstrapInstallerExitReceiptPath,

    [string]$LinuxDeactivationProofPath,

    [string]$LinuxDeactivationTranscriptPath,

    [string]$RuntimeReceiptPath,

    [string]$DaemonExitEvidencePath,

    [string]$DaemonExitObservationPath,

    [string]$RecoveryForceReleaseReceiptPath
)

$ErrorActionPreference = 'Stop'

$taskPath = '\'
$taskName = 'Viewflow Peer'
$expectedTaskName = "${taskPath}${taskName}"
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Viewflow'
$installedBinary = Join-Path $installRoot 'viewflowd.exe'
$installedScript = Join-Path $installRoot 'viewflow-client.ps1'
$sourceScript = Join-Path $PSScriptRoot 'viewflow-client.ps1'
$sourceRollbackScript = Join-Path $PSScriptRoot 'rollback-viewflow.ps1'
$installedRollbackScript = Join-Path $installRoot 'rollback-viewflow.ps1'
$expectedExecutable = [System.IO.Path]::GetFullPath($installedBinary)
$expectedPowerShell = [System.IO.Path]::GetFullPath(
    (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
$expectedTaskUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$identityRoot = Join-Path $installRoot 'identity'
$expectedCert = [System.IO.Path]::GetFullPath((Join-Path $identityRoot 'peer.pem'))
$expectedKey = [System.IO.Path]::GetFullPath((Join-Path $identityRoot 'peer.key'))
$expectedCa = [System.IO.Path]::GetFullPath((Join-Path $identityRoot 'ca.pem'))
$expectedPeer = '172.16.105.62:44119'
$expectedServerName = 'viewflow-linux'
$expectedLocalDeviceId = '00000000000000000000000000000001'
$expectedDeviceId = '00000000000000000000000000000002'
$expectedSourceDisplayId = '00000000000000000000000000000101'
$expectedTargetDeviceUuid = '00000000-0000-0000-0000-000000000002'
$expectedSourceDisplayUuid = '00000000-0000-0000-0000-000000000101'
$bootstrapRequestStream = $null
$bootstrapRequest = $null
$bootstrapRequestSha256 = $null

if (-not [string]::IsNullOrWhiteSpace($BootstrapRequestPath)) {
    if ($PSBoundParameters.Count -ne 1) {
        throw 'BootstrapRequestPath must be the only explicit installer argument'
    }
    $BootstrapRequestPath = [IO.Path]::GetFullPath($BootstrapRequestPath)
    if (-not (Test-Path -LiteralPath $BootstrapRequestPath -PathType Leaf)) {
        throw "Bootstrap request does not exist: $BootstrapRequestPath"
    }
    $requestItem = Get-Item -LiteralPath $BootstrapRequestPath -Force
    if (($requestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Bootstrap request must not be a reparse point'
    }
    $requestAncestor = $requestItem.Directory
    while ($null -ne $requestAncestor) {
        if (($requestAncestor.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Bootstrap request ancestor must not be a reparse point'
        }
        $requestAncestor = $requestAncestor.Parent
    }
    $requestSecurity = Get-Acl -LiteralPath $BootstrapRequestPath
    try {
        $requestOwnerSid = (
            [Security.Principal.NTAccount][string]$requestSecurity.Owner
        ).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        $requestOwnerSid = [string]$requestSecurity.Owner
    }
    $requestRules = @($requestSecurity.GetAccessRules(
        $true, $false, [Security.Principal.SecurityIdentifier]
    ))
    if ($requestOwnerSid -cne $expectedTaskUserSid -or
        -not $requestSecurity.AreAccessRulesProtected -or
        $requestRules.Count -ne 1 -or
        $requestRules[0].IdentityReference.Value -cne $expectedTaskUserSid -or
        $requestRules[0].AccessControlType -ne
            [Security.AccessControl.AccessControlType]::Allow -or
        ($requestRules[0].FileSystemRights -band
            [Security.AccessControl.FileSystemRights]::FullControl) -ne
            [Security.AccessControl.FileSystemRights]::FullControl) {
        throw 'Bootstrap request must be owner-only with one FullControl rule'
    }
    $bootstrapRequestStream = [IO.File]::Open(
        $BootstrapRequestPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $requestMemory = [IO.MemoryStream]::new()
        try {
            $bootstrapRequestStream.CopyTo($requestMemory)
            $requestBytes = $requestMemory.ToArray()
        } finally {
            $requestMemory.Dispose()
        }
        if ($requestBytes.Length -ge 3 -and $requestBytes[0] -eq 0xef -and
            $requestBytes[1] -eq 0xbb -and $requestBytes[2] -eq 0xbf) {
            throw 'Bootstrap request must not contain a UTF-8 BOM'
        }
        $requestUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $bootstrapRequest = ($requestUtf8.GetString($requestBytes)) |
            ConvertFrom-Json
        if ($bootstrapRequest -isnot [pscustomobject]) {
            throw 'Bootstrap request must be a JSON object'
        }
        $requestDigest = [Security.Cryptography.SHA256]::Create()
        try {
            $bootstrapRequestSha256 = (
                [BitConverter]::ToString(
                    $requestDigest.ComputeHash($requestBytes)
                ) -replace '-', ''
            ).ToLowerInvariant()
        } finally {
            $requestDigest.Dispose()
        }
    } catch {
        $bootstrapRequestStream.Dispose()
        $bootstrapRequestStream = $null
        throw
    }

    $requestKeys = @(
        'schema_version', 'state', 'operation_id', 'user_sid',
        'expected_session_id', 'expected_peer', 'expected_server_name',
        'expected_local_device_id', 'expected_device_id',
        'expected_source_display_id', 'launcher_path', 'launcher_sha256',
        'installer_path', 'installer_sha256', 'candidate_path',
        'candidate_sha256', 'wrapper_path', 'wrapper_sha256',
        'rollback_script_path', 'rollback_script_sha256',
        'marker_handoff_receipt_path', 'marker_handoff_receipt_sha256',
        'linux_frozen_evidence_path', 'linux_frozen_evidence_sha256',
        'prepared_receipt_path', 'mutation_permit_path',
        'raw_force_release_receipt_path', 'force_release_envelope_path',
        'linux_stage_receipt_path', 'install_success_receipt_path',
        'installer_exit_receipt_path', 'readiness_receipt_path',
        'readiness_lock_path', 'readiness_commit_request_path',
        'rollback_manifest_path', 'rollback_token_path',
        'recovery_bundle_path', 'linux_deactivation_proof_path',
        'linux_deactivation_transcript_path',
        'recovery_force_release_receipt_path', 'created_at_utc'
    )
    $actualRequestKeys = @(
        $bootstrapRequest.PSObject.Properties | ForEach-Object Name | Sort-Object
    )
    if ($actualRequestKeys.Count -ne $requestKeys.Count -or
        (Compare-Object -CaseSensitive -ReferenceObject ($requestKeys | Sort-Object) `
            -DifferenceObject $actualRequestKeys)) {
        throw 'Bootstrap request has an unexpected property set'
    }
    if ($bootstrapRequest.schema_version -isnot [int] -or
        $bootstrapRequest.schema_version -ne 1 -or
        $bootstrapRequest.state -isnot [string] -or
        $bootstrapRequest.state -cne 'viewflow-windows-bootstrap-requested' -or
        $bootstrapRequest.operation_id -isnot [string] -or
        $bootstrapRequest.operation_id -cnotmatch '^[A-Za-z0-9_-]{16,128}$' -or
        $bootstrapRequest.user_sid -isnot [string] -or
        $bootstrapRequest.user_sid -cne $expectedTaskUserSid -or
        $bootstrapRequest.expected_session_id -isnot [int] -or
        $bootstrapRequest.expected_session_id -ne 1 -or
        $bootstrapRequest.expected_peer -cne $expectedPeer -or
        $bootstrapRequest.expected_server_name -cne $expectedServerName -or
        $bootstrapRequest.expected_local_device_id -cne $expectedLocalDeviceId -or
        $bootstrapRequest.expected_device_id -cne $expectedDeviceId -or
        $bootstrapRequest.expected_source_display_id -cne
            $expectedSourceDisplayId) {
        throw 'Bootstrap request schema, operation, user, or fixed peer binding is invalid'
    }
    foreach ($requestHashName in @(
        'launcher_sha256', 'installer_sha256', 'candidate_sha256',
        'wrapper_sha256', 'rollback_script_sha256',
        'marker_handoff_receipt_sha256', 'linux_frozen_evidence_sha256'
    )) {
        if ($bootstrapRequest.$requestHashName -isnot [string] -or
            $bootstrapRequest.$requestHashName -cnotmatch '^[0-9a-f]{64}$') {
            throw "Bootstrap request hash is invalid: $requestHashName"
        }
    }
    try {
        $null = [DateTimeOffset]::ParseExact(
            [string]$bootstrapRequest.created_at_utc,
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
    } catch {
        throw 'Bootstrap request created_at_utc is invalid'
    }

    $requestRoot = [IO.Path]::GetDirectoryName($BootstrapRequestPath)
    $expectedRequestRoot = Join-Path (
        Join-Path $env:LOCALAPPDATA 'Viewflow\Deployments'
    ) ([string]$bootstrapRequest.operation_id)
    if (-not $requestRoot.Equals(
        [IO.Path]::GetFullPath($expectedRequestRoot),
        [StringComparison]::OrdinalIgnoreCase
    ) -or [IO.Path]::GetFileName($BootstrapRequestPath) -cne 'request.json') {
        throw 'Bootstrap request is outside its fixed operation root'
    }
    $fixedRequestLeaves = [ordered]@{
        launcher_path = 'start-viewflow-bootstrap.ps1'
        installer_path = 'install-viewflow.ps1'
        candidate_path = 'viewflowd.exe'
        wrapper_path = 'viewflow-client.ps1'
        rollback_script_path = 'rollback-viewflow.ps1'
        marker_handoff_receipt_path = 'marker-handoff-receipt.json'
        linux_frozen_evidence_path = 'linux-v13-frozen-evidence.json'
        prepared_receipt_path = 'bootstrap-prepared.json'
        mutation_permit_path = 'mutation-permit.json'
        raw_force_release_receipt_path = 'raw-force-release.json'
        force_release_envelope_path = 'force-release-envelope.json'
        linux_stage_receipt_path = 'linux-stage-receipt.json'
        install_success_receipt_path = 'windows-install-success.json'
        installer_exit_receipt_path = 'installer-exit.json'
        readiness_receipt_path = 'readiness.json'
        readiness_lock_path = 'readiness.lock'
        readiness_commit_request_path = 'readiness-commit-request.json'
        rollback_manifest_path = 'rollback-manifest.json'
        rollback_token_path = 'rollback-token.json'
        recovery_bundle_path = 'recovery-bundle.json'
        linux_deactivation_proof_path = 'linux-deactivation-proof.json'
        linux_deactivation_transcript_path = 'linux-deactivation-transcript.json'
        recovery_force_release_receipt_path = 'recovery-force-release.json'
    }
    foreach ($fixedRequestPath in $fixedRequestLeaves.GetEnumerator()) {
        $actualFixedPath = [IO.Path]::GetFullPath(
            [string]$bootstrapRequest.PSObject.Properties[
                $fixedRequestPath.Key
            ].Value
        )
        $expectedFixedPath = [IO.Path]::GetFullPath(
            (Join-Path $requestRoot $fixedRequestPath.Value)
        )
        if (-not $actualFixedPath.Equals(
            $expectedFixedPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Bootstrap request path is not fixed: $($fixedRequestPath.Key)"
        }
    }
    foreach ($inputBinding in @(
        @{ Path = $bootstrapRequest.launcher_path; Hash = $bootstrapRequest.launcher_sha256; Name = 'launcher' },
        @{ Path = $bootstrapRequest.installer_path; Hash = $bootstrapRequest.installer_sha256; Name = 'installer' },
        @{ Path = $bootstrapRequest.candidate_path; Hash = $bootstrapRequest.candidate_sha256; Name = 'candidate' },
        @{ Path = $bootstrapRequest.wrapper_path; Hash = $bootstrapRequest.wrapper_sha256; Name = 'wrapper' },
        @{ Path = $bootstrapRequest.rollback_script_path; Hash = $bootstrapRequest.rollback_script_sha256; Name = 'rollback script' },
        @{ Path = $bootstrapRequest.marker_handoff_receipt_path; Hash = $bootstrapRequest.marker_handoff_receipt_sha256; Name = 'marker handoff receipt' },
        @{ Path = $bootstrapRequest.linux_frozen_evidence_path; Hash = $bootstrapRequest.linux_frozen_evidence_sha256; Name = 'Linux frozen evidence' }
    )) {
        $inputPath = [IO.Path]::GetFullPath([string]$inputBinding.Path)
        if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
            throw "Bootstrap request input is absent: $($inputBinding.Name)"
        }
        $inputItem = Get-Item -LiteralPath $inputPath -Force
        if (($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne
                [string]$inputBinding.Hash) {
            throw "Bootstrap request input identity or hash is invalid: $($inputBinding.Name)"
        }
        $inputSecurity = Get-Acl -LiteralPath $inputPath
        try {
            $inputOwnerSid = (
                [Security.Principal.NTAccount][string]$inputSecurity.Owner
            ).Translate([Security.Principal.SecurityIdentifier]).Value
        } catch {
            $inputOwnerSid = [string]$inputSecurity.Owner
        }
        $inputRules = @($inputSecurity.GetAccessRules(
            $true, $false, [Security.Principal.SecurityIdentifier]
        ))
        if ($inputOwnerSid -cne $expectedTaskUserSid -or
            -not $inputSecurity.AreAccessRulesProtected -or
            $inputRules.Count -ne 1 -or
            $inputRules[0].IdentityReference.Value -cne $expectedTaskUserSid -or
            $inputRules[0].AccessControlType -ne
                [Security.AccessControl.AccessControlType]::Allow -or
            ($inputRules[0].FileSystemRights -band
                [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl) {
            throw "Bootstrap request input is not owner-only: $($inputBinding.Name)"
        }
    }
    if (-not ([IO.Path]::GetFullPath([string]$bootstrapRequest.installer_path)).Equals(
            [IO.Path]::GetFullPath($PSCommandPath),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([IO.Path]::GetFullPath([string]$bootstrapRequest.wrapper_path)).Equals(
            [IO.Path]::GetFullPath($sourceScript),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        -not ([IO.Path]::GetFullPath(
            [string]$bootstrapRequest.rollback_script_path
        )).Equals(
            [IO.Path]::GetFullPath($sourceRollbackScript),
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Bootstrap request reviewed installer, wrapper, or rollback path is invalid'
    }

    $outputNames = @(
        'prepared_receipt_path', 'mutation_permit_path',
        'raw_force_release_receipt_path', 'force_release_envelope_path',
        'linux_stage_receipt_path', 'install_success_receipt_path',
        'installer_exit_receipt_path', 'readiness_receipt_path',
        'readiness_lock_path', 'readiness_commit_request_path',
        'rollback_manifest_path', 'rollback_token_path',
        'recovery_bundle_path', 'linux_deactivation_proof_path',
        'linux_deactivation_transcript_path',
        'recovery_force_release_receipt_path'
    )
    $requestOutputSeen = @{}
    foreach ($outputName in $outputNames) {
        $outputPath = [IO.Path]::GetFullPath([string]$bootstrapRequest.$outputName)
        if (-not ([IO.Path]::GetDirectoryName($outputPath)).Equals(
            $requestRoot, [StringComparison]::OrdinalIgnoreCase
        ) -or $requestOutputSeen.ContainsKey($outputPath.ToUpperInvariant()) -or
            (Test-Path -LiteralPath $outputPath)) {
            throw "Bootstrap request output path is unsafe: $outputName"
        }
        $requestOutputSeen[$outputPath.ToUpperInvariant()] = $true
    }

    $CandidatePath = [string]$bootstrapRequest.candidate_path
    $ExpectedSha256 = [string]$bootstrapRequest.candidate_sha256
    $ExpectedWrapperSha256 = [string]$bootstrapRequest.wrapper_sha256
    $QuiescedMarkerPath = [string]$bootstrapRequest.linux_frozen_evidence_path
    $ReadinessReceiptPath = [string]$bootstrapRequest.readiness_receipt_path
    $ReadinessLockPath = [string]$bootstrapRequest.readiness_lock_path
    $ReadinessCommitRequestPath =
        [string]$bootstrapRequest.readiness_commit_request_path
    $AllowV13Bootstrap = $true
    $ForceReleaseReceiptPath =
        [string]$bootstrapRequest.raw_force_release_receipt_path
    $InstallSuccessReceiptPath =
        [string]$bootstrapRequest.install_success_receipt_path
    $RollbackManifestPath = [string]$bootstrapRequest.rollback_manifest_path
    $RollbackTokenPath = [string]$bootstrapRequest.rollback_token_path
    $RecoveryBundlePath = [string]$bootstrapRequest.recovery_bundle_path
    $BootstrapRecoveryPreparedReceiptPath =
        [string]$bootstrapRequest.prepared_receipt_path
    $MarkerHandoffReceiptPath =
        [string]$bootstrapRequest.marker_handoff_receipt_path
    $BootstrapMutationPermitPath =
        [string]$bootstrapRequest.mutation_permit_path
    $BootstrapForceReleaseEnvelopePath =
        [string]$bootstrapRequest.force_release_envelope_path
    $LinuxStageReceiptPath = [string]$bootstrapRequest.linux_stage_receipt_path
    $BootstrapInstallerExitReceiptPath =
        [string]$bootstrapRequest.installer_exit_receipt_path
    $LinuxDeactivationProofPath =
        [string]$bootstrapRequest.linux_deactivation_proof_path
    $LinuxDeactivationTranscriptPath =
        [string]$bootstrapRequest.linux_deactivation_transcript_path
    $RecoveryForceReleaseReceiptPath =
        [string]$bootstrapRequest.recovery_force_release_receipt_path
}

$expectedReadinessReceiptPath = [IO.Path]::GetFullPath($ReadinessReceiptPath)
$expectedReadinessLockPath = [IO.Path]::GetFullPath($ReadinessLockPath)
$expectedReadinessCommitRequestPath = [IO.Path]::GetFullPath(
    $ReadinessCommitRequestPath
)
$expectedInstallSuccessReceiptPath = [IO.Path]::GetFullPath(
    $InstallSuccessReceiptPath
)
$expectedOperationId = $null
$stopStableObservationMs = 6000
$startStableObservationMs = 6000
$clientLogFile = Join-Path $env:LOCALAPPDATA 'Viewflow\logs\peer.log'
$bootstrapTaskPath = '\'
# The scheduler may legitimately queue an interactive task while Windows is
# changing desktop/session state. That queueing budget is deliberately
# separate from the short execution budget for the one-shot injector.
$bootstrapTaskDispatchDeadlineSeconds = 120
$bootstrapTaskExecutionDeadlineSeconds = 30
$readinessWaitSeconds = if ($AllowV13Bootstrap) { 120 } else { 180 }
$commitWaitSeconds = if ($AllowV13Bootstrap) { 120 } else { 30 }
$maximumJsonInteger = 9007199254740991L

function Initialize-NativeFileIdentityType {
    if ($null -ne ('ViewflowInstall.NativeFile' -as [type])) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace ViewflowInstall {
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
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(
            string name, uint access, FileShare share, IntPtr security,
            FileMode mode, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetFileInformationByHandle(
            SafeFileHandle handle, out ByHandleFileInformation information);
        public static SafeFileHandle OpenDirectoryLease(string path) {
            const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
            const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
            var handle = CreateFile(path, 0, FileShare.Read | FileShare.Write,
                IntPtr.Zero, FileMode.Open, FILE_FLAG_BACKUP_SEMANTICS |
                FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return handle;
        }
    }
}
'@
}

function Assert-NoReparseAncestors {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $current = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name ancestor must not be a reparse point: $($current.FullName)"
        }
        $parent = [IO.Directory]::GetParent($current.FullName)
        if ($null -eq $parent) { break }
        $current = Get-Item -LiteralPath $parent.FullName -Force
    }
}

function Open-SafeDirectoryLease {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $canonical = [IO.Path]::GetFullPath($Path)
    Assert-NoReparseAncestors -Path $canonical -Name $Name
    Initialize-NativeFileIdentityType
    $handle = [ViewflowInstall.NativeFile]::OpenDirectoryLease($canonical)
    try {
        $information = New-Object ViewflowInstall.ByHandleFileInformation
        if (-not [ViewflowInstall.NativeFile]::GetFileInformationByHandle(
            $handle, [ref]$information
        )) {
            throw "$Name identity could not be read"
        }
        [pscustomobject]@{
            Path = $canonical
            Handle = $handle
            Identity = ('{0:x8}:{1:x8}{2:x8}' -f @(
                [uint32]$information.VolumeSerialNumber,
                [uint32]$information.FileIndexHigh,
                [uint32]$information.FileIndexLow
            ))
        }
        $handle = $null
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Assert-SafeDirectoryLeaseCurrent {
    param(
        [Parameter(Mandatory = $true)]$Lease,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Lease.Handle -or $Lease.Handle.IsClosed -or
        $Lease.Handle.IsInvalid) {
        throw "$Name lease is not held"
    }
    $probe = Open-SafeDirectoryLease -Path $Lease.Path -Name $Name
    try {
        if ([string]$probe.Identity -cne [string]$Lease.Identity) {
            throw "$Name identity changed"
        }
    } finally {
        $probe.Handle.Dispose()
    }
}

function Test-JsonInteger {
    param($Value)
    $Value -is [int] -or $Value -is [long]
}

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($Value -isnot [pscustomobject]) {
        throw "$Context must be a JSON object"
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count -or
        (Compare-Object -CaseSensitive `
            -ReferenceObject $expected -DifferenceObject $actual)) {
        throw "$Context has an unexpected property set"
    }
}

function Assert-LowerSha256 {
    param(
        [Parameter(Mandatory = $true)]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256 string"
    }
}

function Assert-FreshUtcTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
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
        throw "$Name is not an exact UTC millisecond timestamp"
    }
    $age = [DateTimeOffset]::UtcNow - $timestamp
    if ($age.TotalSeconds -lt -30 -or
        $age.TotalSeconds -gt $QuiescedMarkerMaxAgeSeconds) {
        throw "$Name is stale or from the future"
    }
}

function Assert-NewAbsoluteOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [System.IO.Path]::IsPathRooted($Path)) {
        throw "$Name must be an absolute path"
    }
    if (Test-Path -LiteralPath $Path) {
        throw "$Name already exists: $Path"
    }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if ([string]::IsNullOrWhiteSpace($parent) -or
        -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "$Name parent directory does not exist: $parent"
    }
    $lease = Open-SafeDirectoryLease -Path $parent -Name "$Name parent"
    $lease.Handle.Dispose()
}

function Assert-DistinctBootstrapOutputPaths {
    param(
        [Parameter(Mandatory = $true)][string[]]$OutputPaths,
        [Parameter(Mandatory = $true)][string[]]$ProtectedPaths
    )

    $seen = @{}
    foreach ($protectedPath in $ProtectedPaths) {
        $canonical = [IO.Path]::GetFullPath($protectedPath).ToUpperInvariant()
        $seen[$canonical] = 'protected input or installed artifact'
    }
    foreach ($outputPath in $OutputPaths) {
        $canonicalPath = [IO.Path]::GetFullPath($outputPath)
        $key = $canonicalPath.ToUpperInvariant()
        if ($seen.ContainsKey($key)) {
            throw (
                'Bootstrap output paths must be pairwise distinct and must not ' +
                "alias a $($seen[$key]): $canonicalPath"
            )
        }
        $seen[$key] = 'bootstrap output'
    }
}

function New-OwnerOnlyFileSecurity {
    $sid = [System.Security.Principal.SecurityIdentifier]::new(
        $expectedTaskUserSid
    )
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

function Set-OwnerOnlyFileSecurity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Assert-RegularNonReparseFile -Path $Path -Name $Name
    Set-Acl -LiteralPath $Path -AclObject (New-OwnerOnlyFileSecurity)
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
}

function Write-OwnerOnlyCreateOnceBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    Assert-NewAbsoluteOutputPath -Path $Path -Name 'Owner-only output'
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $leaf = [IO.Path]::GetFileName([IO.Path]::GetFullPath($Path))
    $parentLease = Open-SafeDirectoryLease -Path $parent `
        -Name 'Owner-only output parent'
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
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
            -Name 'Owner-only output parent'
        [System.IO.File]::Move($temporary, $Path)
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        $parentLease.Handle.Dispose()
    }
}

function Write-OwnerOnlyCreateOnceJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Value
    )
    $json = ($Value | ConvertTo-Json -Depth 12) + "`n"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    Write-OwnerOnlyCreateOnceBytes -Path $Path -Bytes $bytes
}

function Get-FileSha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RegularNonReparseFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Name does not exist: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must be a regular non-reparse file: $Path"
    }
}

function Get-ProcessStartFileTimeString {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-StringSha256Lower {
    param([Parameter(Mandatory = $true)][string]$Value)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Value)
    $digest = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($digest.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $digest.Dispose()
    }
}

function Get-BytesSha256Lower {
    param([Parameter(Mandatory = $true)][byte[]]$Value)
    $digest = [System.Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($digest.ComputeHash($Value)) -replace '-', '').ToLowerInvariant()
    } finally {
        $digest.Dispose()
    }
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

function Read-OwnerOnlyJsonExclusive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -and
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must not be a reparse point"
    }
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None
    )
    try {
        $reader = [IO.StreamReader]::new(
            $stream,
            [Text.UTF8Encoding]::new($false),
            $true
        )
        try {
            $reader.ReadToEnd() | ConvertFrom-Json
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Read-OwnerOnlyUtf8JsonSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [IO.FileShare]$Share = [IO.FileShare]::None
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name does not exist: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must not be a reparse point"
    }
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        $Share
    )
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } finally {
            $memory.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $json = $utf8.GetString($bytes)
        $value = $json | ConvertFrom-Json
    } catch {
        throw "$Name is not strict UTF-8 JSON"
    }
    if ($value -isnot [pscustomobject]) {
        throw "$Name must be a JSON object"
    }
    [pscustomobject]@{
        Value = $value
        Sha256 = Get-BytesSha256Lower -Value $bytes
    }
}

function Read-Utf8JsonStreamSnapshot {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Stream.CanRead -or -not $Stream.CanSeek) {
        throw "$Name stream must be readable and seekable"
    }
    $Stream.Position = 0
    $memory = [IO.MemoryStream]::new()
    try {
        $Stream.CopyTo($memory)
        $bytes = $memory.ToArray()
    } finally {
        $memory.Dispose()
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $value = ($utf8.GetString($bytes)) | ConvertFrom-Json
    } catch {
        throw "$Name is not strict UTF-8 JSON"
    }
    if ($value -isnot [pscustomobject]) {
        throw "$Name must be a JSON object"
    }
    [pscustomobject]@{
        Value = $value
        Sha256 = Get-BytesSha256Lower -Value $bytes
    }
}

function Open-PinnedReadinessLockSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name does not exist: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must not be a reparse point"
    }
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite
    )
    try {
        $snapshot = Read-Utf8JsonStreamSnapshot -Stream $stream -Name $Name
        [pscustomobject]@{
            Stream = $stream
            Value = $snapshot.Value
            Sha256 = $snapshot.Sha256
        }
        $stream = $null
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Open-PinnedReadinessReceiptSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name does not exist: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must not be a reparse point"
    }
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
    $stream = [IO.File]::Open(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $snapshot = Read-Utf8JsonStreamSnapshot -Stream $stream -Name $Name
        [pscustomobject]@{
            Stream = $stream
            Value = $snapshot.Value
            Sha256 = $snapshot.Sha256
        }
        $stream = $null
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Assert-ReadinessLockIsLive {
    param([Parameter(Mandatory = $true)][string]$Path)
    $probe = $null
    try {
        $probe = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read
        )
    } catch [IO.IOException] {
        $win32Error = $_.Exception.HResult -band 0xffff
        if ($win32Error -eq 32) {
            return
        }
        throw
    } finally {
        if ($null -ne $probe) {
            $probe.Dispose()
        }
    }
    throw 'Readiness lock is not held by the running daemon'
}

function Assert-OwnerOnlyFileSecurity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $security = Get-Acl -LiteralPath $Path
    try {
        $ownerSid = ([Security.Principal.NTAccount][string]$security.Owner).Translate(
            [Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        $ownerSid = [string]$security.Owner
    }
    if ($ownerSid -cne $expectedTaskUserSid) {
        throw "$Name owner SID is invalid"
    }
    if (-not $security.AreAccessRulesProtected) {
        throw "$Name ACL must have inheritance disabled"
    }
    $rules = @($security.GetAccessRules(
        $true,
        $false,
        [Security.Principal.SecurityIdentifier]
    ))
    if ($rules.Count -ne 1) {
        throw "$Name ACL must contain exactly one explicit access rule"
    }
    $rule = $rules[0]
    if ($rule.IdentityReference.Value -cne $expectedTaskUserSid -or
        $rule.AccessControlType -ne
            [Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne
            [Security.AccessControl.FileSystemRights]::FullControl) {
        throw "$Name ACL must grant only the owner SID FullControl"
    }
}

function Assert-FreshUnixMilliseconds {
    param(
        [Parameter(Mandatory = $true)]
        $Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if (-not (Test-JsonInteger -Value $Value) -or [long]$Value -le 0) {
        throw "$Name must be a positive JSON integer"
    }
    try {
        $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Value)
    } catch {
        throw "$Name is invalid"
    }
    $age = [DateTimeOffset]::UtcNow - $timestamp
    if ($age.TotalSeconds -lt -30 -or
        $age.TotalSeconds -gt $QuiescedMarkerMaxAgeSeconds) {
        throw "$Name is stale or from the future"
    }
}

function Assert-MarkerHandoffReceipt {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)][string]$OperationId
    )
    Assert-ExactPropertySet -Value $Receipt -Context 'Marker handoff receipt' `
        -Names @(
            'schema_version', 'state', 'protocol_version', 'operation_id',
            'source_display_id', 'target_device_id',
            'coordinator_instance_id', 'marker_generation', 'marker_cli_path',
            'marker_cli_sha256', 'deployment_marker_path',
            'deployment_marker_sha256', 'deployment_publish_receipt_path',
            'deployment_publish_receipt_sha256', 'deskflow_unit',
            'deskflow_unit_active_state', 'deskflow_unit_main_pid',
            'deskflow_executable_path', 'deskflow_executable_sha256',
            'deskflow_exact_process_count', 'deskflow_core_executable_path',
            'deskflow_core_executable_sha256',
            'deskflow_core_exact_process_count', 'deskflow_tcp_port',
            'deskflow_tcp_listener_count', 'runtime_marker_path',
            'runtime_marker_present', 'observed_at_utc'
        )
    if ($Receipt.schema_version -isnot [int] -or
        $Receipt.schema_version -ne 1 -or
        $Receipt.state -isnot [string] -or
        $Receipt.state -cne 'viewflow-v13-marker-handoff-prepared' -or
        $Receipt.protocol_version -isnot [string] -or
        $Receipt.protocol_version -cne '2.1' -or
        $Receipt.operation_id -isnot [string] -or
        $Receipt.operation_id -cne $OperationId -or
        $Receipt.source_display_id -isnot [string] -or
        $Receipt.source_display_id -cne $expectedSourceDisplayUuid -or
        $Receipt.target_device_id -isnot [string] -or
        $Receipt.target_device_id -cne $expectedTargetDeviceUuid -or
        $Receipt.coordinator_instance_id -isnot [string] -or
        $Receipt.coordinator_instance_id -cnotmatch
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $Receipt.marker_generation -isnot [string] -or
        $Receipt.marker_generation -cne '1' -or
        $Receipt.marker_cli_path -isnot [string] -or
        $Receipt.marker_cli_path -cne
            '/home/wilf/.local/lib/viewflow/viewflow-deployment-marker' -or
        $Receipt.deployment_marker_path -isnot [string] -or
        $Receipt.deployment_marker_path -cne
            '/home/wilf/.local/state/viewflow/deployment-quarantine.v1' -or
        $Receipt.deskflow_unit -isnot [string] -or
        $Receipt.deskflow_unit -cne 'deskflow.service' -or
        $Receipt.deskflow_unit_active_state -isnot [string] -or
        $Receipt.deskflow_unit_active_state -cne 'inactive' -or
        -not (Test-JsonInteger -Value $Receipt.deskflow_unit_main_pid) -or
        [long]$Receipt.deskflow_unit_main_pid -ne 0 -or
        -not (Test-JsonInteger -Value $Receipt.deskflow_exact_process_count) -or
        [long]$Receipt.deskflow_exact_process_count -ne 0 -or
        -not (Test-JsonInteger -Value $Receipt.deskflow_core_exact_process_count) -or
        [long]$Receipt.deskflow_core_exact_process_count -ne 0 -or
        -not (Test-JsonInteger -Value $Receipt.deskflow_tcp_port) -or
        [long]$Receipt.deskflow_tcp_port -ne 24800 -or
        -not (Test-JsonInteger -Value $Receipt.deskflow_tcp_listener_count) -or
        [long]$Receipt.deskflow_tcp_listener_count -ne 0 -or
        $Receipt.runtime_marker_path -isnot [string] -or
        $Receipt.runtime_marker_path -cne
            '/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' -or
        $Receipt.runtime_marker_present -isnot [bool] -or
        [bool]$Receipt.runtime_marker_present) {
        throw 'Marker handoff schema, operation, display, or generation is invalid'
    }
    foreach ($handoffHashName in @(
        'marker_cli_sha256', 'deployment_marker_sha256',
        'deployment_publish_receipt_sha256', 'deskflow_executable_sha256',
        'deskflow_core_executable_sha256'
    )) {
        Assert-LowerSha256 `
            -Value $Receipt.PSObject.Properties[$handoffHashName].Value `
            -Name "Marker handoff $handoffHashName"
    }
    try {
        $null = [DateTimeOffset]::ParseExact(
            [string]$Receipt.observed_at_utc,
            'yyyy-MM-ddTHH:mm:ss.000Z',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
    } catch {
        throw 'Marker handoff observed_at_utc is invalid'
    }
}

function Assert-PinnedBootstrapRequestCurrent {
    if ($null -eq $bootstrapRequestStream -or
        -not $bootstrapRequestStream.CanRead) {
        throw 'Pinned bootstrap request is unavailable'
    }
    $snapshot = Read-Utf8JsonStreamSnapshot -Stream $bootstrapRequestStream `
        -Name 'Pinned bootstrap request revalidation'
    if ([string]$snapshot.Sha256 -cne $bootstrapRequestSha256) {
        throw 'Pinned bootstrap request changed during installation'
    }
}

function Assert-V13BootstrapEvidence {
    param(
        [Parameter(Mandatory = $true)]
        $Marker
    )

    Assert-ExactPropertySet -Value $Marker -Context 'Bootstrap evidence' -Names @(
        'schema_version', 'state', 'operation_id', 'daemon', 'journal',
        'pre_stop', 'post_stop', 'completed_at_unix_ms'
    )
    if ($Marker.schema_version -isnot [int] -or
        $Marker.schema_version -ne 1 -or
        $Marker.state -isnot [string] -or
        $Marker.state -cne 'viewflow-v13-bootstrap-frozen' -or
        $Marker.operation_id -isnot [string] -or
        $Marker.operation_id -cnotmatch '^[A-Za-z0-9_-]{16,128}$') {
        throw 'Bootstrap evidence schema, state, or operation_id is invalid'
    }

    $daemon = $Marker.daemon
    Assert-ExactPropertySet -Value $daemon -Context 'Bootstrap daemon' -Names @(
        'pid', 'start_ticks', 'boot_id', 'daemon_instance_id', 'sha256',
        'executable', 'systemd_invocation_id'
    )
    if (-not (Test-JsonInteger -Value $daemon.pid) -or
        [long]$daemon.pid -le 0 -or
        -not (Test-JsonInteger -Value $daemon.start_ticks) -or
        [long]$daemon.start_ticks -le 0 -or
        $daemon.boot_id -isnot [string] -or
        $daemon.boot_id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
        $daemon.daemon_instance_id -isnot [string] -or
        $daemon.daemon_instance_id -cne ('{0}-{1}-{2}' -f @(
            $daemon.boot_id, [long]$daemon.pid, [long]$daemon.start_ticks
        )) -or
        $daemon.executable -isnot [string] -or
        $daemon.executable -cne '/home/wilf/.local/lib/viewflow/viewflowd' -or
        $daemon.systemd_invocation_id -isnot [string] -or
        $daemon.systemd_invocation_id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Bootstrap daemon identity is invalid'
    }
    Assert-LowerSha256 -Value $daemon.sha256 -Name 'Bootstrap daemon sha256'

    $journal = $Marker.journal
    Assert-ExactPropertySet -Value $journal -Context 'Bootstrap journal' -Names @(
        'query_boot_id', 'query_pid', 'query_systemd_invocation_id',
        'start_cursor', 'start_realtime_timestamp_us', 'protocol_startup_cursor',
        'protocol_startup_realtime_timestamp_us', 'end_cursor',
        'end_realtime_timestamp_us', 'entry_count', 'slice_sha256', 'counts'
    )
    Assert-ExactPropertySet -Value $journal.counts -Context 'Bootstrap journal counts' -Names @(
        'protocol_1_3_startup', 'lease_offered', 'input_event',
        'input_sidecar_activation', 'cleanup_or_release_error'
    )
    $expectedJournalQueryBootId = ([string]$daemon.boot_id).Replace('-', '')
    if ($journal.query_boot_id -isnot [string] -or
        $journal.query_boot_id -cnotmatch '^[0-9a-f]{32}$' -or
        $journal.query_boot_id -cne $expectedJournalQueryBootId -or
        $journal.query_pid -isnot [string] -or
        $journal.query_pid -cne ([long]$daemon.pid).ToString(
            [Globalization.CultureInfo]::InvariantCulture
        ) -or
        $journal.query_systemd_invocation_id -isnot [string] -or
        $journal.query_systemd_invocation_id -cne $daemon.systemd_invocation_id -or
        $journal.start_cursor -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$journal.start_cursor) -or
        $journal.protocol_startup_cursor -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$journal.protocol_startup_cursor) -or
        $journal.end_cursor -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$journal.end_cursor) -or
        -not (Test-JsonInteger -Value $journal.start_realtime_timestamp_us) -or
        [long]$journal.start_realtime_timestamp_us -le 0 -or
        -not (Test-JsonInteger -Value $journal.protocol_startup_realtime_timestamp_us) -or
        [long]$journal.protocol_startup_realtime_timestamp_us -lt
            [long]$journal.start_realtime_timestamp_us -or
        -not (Test-JsonInteger -Value $journal.end_realtime_timestamp_us) -or
        [long]$journal.end_realtime_timestamp_us -lt
            [long]$journal.protocol_startup_realtime_timestamp_us -or
        -not (Test-JsonInteger -Value $journal.entry_count) -or
        [long]$journal.entry_count -le 0) {
        throw 'Bootstrap journal identity, cursors, timestamps, or count is invalid'
    }
    Assert-LowerSha256 -Value $journal.slice_sha256 -Name 'Bootstrap journal slice_sha256'
    foreach ($countName in @(
        'protocol_1_3_startup', 'lease_offered', 'input_event',
        'input_sidecar_activation', 'cleanup_or_release_error'
    )) {
        $count = $journal.counts.PSObject.Properties[$countName].Value
        if (-not (Test-JsonInteger -Value $count) -or [long]$count -lt 0) {
            throw "Bootstrap journal count is invalid: $countName"
        }
    }
    if ([long]$journal.counts.protocol_1_3_startup -ne 1) {
        throw 'Bootstrap journal must contain exactly one protocol-1.3 startup line'
    }

    Assert-ExactPropertySet -Value $Marker.pre_stop -Context 'Bootstrap pre_stop' -Names @(
        'deskflow_unit_active_state', 'deskflow_main_pid',
        'deskflow_exact_process_count', 'deskflow_core_exact_process_count',
        'deskflow_tcp_24800_listener_count'
    )
    if ($Marker.pre_stop.deskflow_unit_active_state -isnot [string] -or
        $Marker.pre_stop.deskflow_unit_active_state -cne 'inactive' -or
        -not (Test-JsonInteger -Value $Marker.pre_stop.deskflow_main_pid) -or
        [long]$Marker.pre_stop.deskflow_main_pid -ne 0 -or
        -not (Test-JsonInteger -Value $Marker.pre_stop.deskflow_exact_process_count) -or
        [long]$Marker.pre_stop.deskflow_exact_process_count -ne 0 -or
        -not (Test-JsonInteger -Value $Marker.pre_stop.deskflow_core_exact_process_count) -or
        [long]$Marker.pre_stop.deskflow_core_exact_process_count -ne 0 -or
        -not (Test-JsonInteger -Value $Marker.pre_stop.deskflow_tcp_24800_listener_count) -or
        [long]$Marker.pre_stop.deskflow_tcp_24800_listener_count -ne 0) {
        throw 'Bootstrap pre-stop Deskflow boundary is invalid'
    }

    $post = $Marker.post_stop
    Assert-ExactPropertySet -Value $post -Context 'Bootstrap post_stop' -Names @(
        'unit_active_state', 'main_pid', 'exact_process_count',
        'udp_44119_listener_count', 'sidecar_socket_present',
        'original_daemon_pid_present', 'command_outputs',
        'command_output_format', 'command_output_sha256'
    )
    Assert-ExactPropertySet -Value $post.command_outputs `
        -Context 'Bootstrap command_outputs' -Names @(
            'systemctl_is_active', 'systemctl_main_pid', 'exact_viewflow_pids',
            'udp_44119_listeners', 'sidecar_socket_present',
            'original_daemon_pid_present'
        )
    if ($post.unit_active_state -isnot [string] -or
        $post.unit_active_state -cne 'inactive' -or
        -not (Test-JsonInteger -Value $post.main_pid) -or [long]$post.main_pid -ne 0 -or
        -not (Test-JsonInteger -Value $post.exact_process_count) -or
        [long]$post.exact_process_count -ne 0 -or
        -not (Test-JsonInteger -Value $post.udp_44119_listener_count) -or
        [long]$post.udp_44119_listener_count -ne 0 -or
        $post.sidecar_socket_present -isnot [bool] -or
        $post.sidecar_socket_present -ne $false -or
        $post.original_daemon_pid_present -isnot [bool] -or
        $post.original_daemon_pid_present -ne $false -or
        $post.command_output_format -isnot [string] -or
        $post.command_output_format -cne
            'key=value newline-delimited UTF-8 in displayed order') {
        throw 'Bootstrap post-stop boundary is invalid'
    }
    $expectedOutputs = [ordered]@{
        systemctl_is_active = 'inactive'
        systemctl_main_pid = '0'
        exact_viewflow_pids = ''
        udp_44119_listeners = ''
        sidecar_socket_present = 'false'
        original_daemon_pid_present = 'false'
    }
    foreach ($name in $expectedOutputs.Keys) {
        $value = $post.command_outputs.PSObject.Properties[$name].Value
        if ($value -isnot [string] -or $value -cne $expectedOutputs[$name]) {
            throw "Bootstrap command output is invalid: $name"
        }
    }
    $transcript = (
        "systemctl_is_active=inactive`n" +
        "systemctl_main_pid=0`n" +
        "exact_viewflow_pids=`n" +
        "udp_44119_listeners=`n" +
        "sidecar_socket_present=false`n" +
        "original_daemon_pid_present=false`n"
    )
    Assert-LowerSha256 -Value $post.command_output_sha256 `
        -Name 'Bootstrap command_output_sha256'
    if ([string]$post.command_output_sha256 -cne
        (Get-StringSha256Lower -Value $transcript)) {
        throw 'Bootstrap command-output SHA-256 does not match its exact transcript'
    }

    Assert-FreshUnixMilliseconds -Value $Marker.completed_at_unix_ms `
        -Name 'Bootstrap completed_at_unix_ms'
    if (([long]$Marker.completed_at_unix_ms * 1000) -lt
        [long]$journal.end_realtime_timestamp_us) {
        throw 'Bootstrap completion predates the terminal journal entry'
    }
    $Marker
}

function Assert-ForceReleaseReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$CandidateSha256,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [long]$ObservedPid = 0,
        [string]$ObservedProcessStartFileTime
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Force-release receipt does not exist: $Path"
    }
    $receiptRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $Path `
        -Name 'Force-release receipt'
    $receipt = $receiptRead.Value
    Assert-ExactPropertySet -Value $receipt -Context 'Force-release receipt' -Names @(
        'schema_version', 'state', 'operation_id', 'tool_executable_sha256',
        'linux_frozen_evidence_sha256',
        'tool_pid', 'tool_process_start_filetime', 'tool_session_id',
        'tool_user_sid', 'input_desktop', 'requested_input_count',
        'inserted_input_count', 'verification_stable_ms', 'completed_at_utc'
    )
    if ($receipt.schema_version -isnot [int] -or
        $receipt.schema_version -ne 3 -or
        $receipt.state -isnot [string] -or
        $receipt.state -cne 'viewflow-force-release-completed' -or
        $receipt.operation_id -isnot [string] -or
        $receipt.operation_id -cne $OperationId) {
        throw 'Force-release receipt schema, state, or operation binding is invalid'
    }
    Assert-LowerSha256 -Value $receipt.tool_executable_sha256 `
        -Name 'Force-release tool_executable_sha256'
    Assert-LowerSha256 -Value $receipt.linux_frozen_evidence_sha256 `
        -Name 'Force-release linux_frozen_evidence_sha256'
    if ([string]$receipt.tool_executable_sha256 -cne $CandidateSha256.ToLowerInvariant() -or
        [string]$receipt.linux_frozen_evidence_sha256 -cne $LinuxEvidenceSha256 -or
        -not (Test-JsonInteger -Value $receipt.tool_pid) -or
        [long]$receipt.tool_pid -le 0 -or
        $receipt.tool_process_start_filetime -isnot [string] -or
        $receipt.tool_process_start_filetime -cnotmatch '^[1-9][0-9]{0,19}$' -or
        -not (Test-JsonInteger -Value $receipt.tool_session_id) -or
        [long]$receipt.tool_session_id -ne 1 -or
        $receipt.tool_user_sid -isnot [string] -or
        $receipt.tool_user_sid -cne $expectedTaskUserSid -or
        $receipt.input_desktop -isnot [string] -or
        $receipt.input_desktop -cne 'Default' -or
        -not (Test-JsonInteger -Value $receipt.requested_input_count) -or
        [long]$receipt.requested_input_count -ne 135 -or
        -not (Test-JsonInteger -Value $receipt.inserted_input_count) -or
        [long]$receipt.inserted_input_count -ne 135 -or
        -not (Test-JsonInteger -Value $receipt.verification_stable_ms) -or
        [long]$receipt.verification_stable_ms -ne 500) {
        throw 'Force-release receipt execution or verification evidence is invalid'
    }
    try {
        $null = [uint64]::Parse(
            [string]$receipt.tool_process_start_filetime,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw 'Force-release tool_process_start_filetime exceeds uint64'
    }
    if ($ObservedPid -gt 0 -and
        ([long]$receipt.tool_pid -ne $ObservedPid -or
            [string]$receipt.tool_process_start_filetime -cne
                $ObservedProcessStartFileTime)) {
        throw 'Force-release receipt does not match the observed tool process identity'
    }
    Assert-FreshUtcTimestamp -Value $receipt.completed_at_utc `
        -Name 'Force-release completed_at_utc'
    [pscustomobject]@{
        Receipt = $receipt
        Sha256 = [string]$receiptRead.Sha256
    }
}

function Get-ExceptionChainText {
    param([AllowNull()]$ErrorRecord)

    if ($null -eq $ErrorRecord) { return '' }
    $parts = @()
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $parts += ('{0}: {1}' -f $exception.GetType().FullName, $exception.Message)
        $exception = $exception.InnerException
    }
    if ($parts.Count -eq 0) { return [string]$ErrorRecord }
    $parts -join "`ncaused by: "
}

function Get-BootstrapForceReleaseAttemptEvidencePath {
    param([Parameter(Mandatory = $true)][string]$ReceiptPath)

    $receiptFullPath = [IO.Path]::GetFullPath($ReceiptPath)
    $operationRoot = [IO.Path]::GetDirectoryName($receiptFullPath)
    if ([string]::IsNullOrWhiteSpace($operationRoot)) {
        throw 'Force-release receipt must have an operation-root parent'
    }
    # This fixed leaf keeps the new evidence contract available to existing
    # request schema-1 launchers without permitting an arbitrary extra output.
    Join-Path $operationRoot 'force-release-attempt.json'
}

function Get-BootstrapForceReleaseCandidateProcesses {
    param([Parameter(Mandatory = $true)][string]$CandidateFullPath)

    @(
        Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'" |
            Where-Object {
                $_.ExecutablePath -and
                [System.IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals(
                    $CandidateFullPath,
                    [StringComparison]::OrdinalIgnoreCase
                )
            }
    )
}

function Get-BootstrapForceReleaseAttemptSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$TaskPath,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$CandidateFullPath,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [AllowNull()][long]$ObservedPid = 0,
        [string]$ObservedProcessStartFileTime
    )

    $snapshotError = $null
    $taskState = $null
    $lastTaskResult = $null
    $lastRunTimeUtc = $null
    $observedPid = $null
    $observedStartFileTime = $null
    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName `
            -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            $taskState = [string]$task.State
            $taskInfo = Get-ScheduledTaskInfo -TaskPath $TaskPath `
                -TaskName $TaskName -ErrorAction Stop
            $lastTaskResult = [long]$taskInfo.LastTaskResult
            $lastRunTime = [DateTime]$taskInfo.LastRunTime
            if ($lastRunTime -gt [DateTime]::MinValue) {
                $lastRunTimeUtc = $lastRunTime.ToUniversalTime().ToString(
                    'yyyy-MM-ddTHH:mm:ss.fffZ',
                    [Globalization.CultureInfo]::InvariantCulture
                )
            }
        }
        if ($ObservedPid -gt 0) {
            if ([string]::IsNullOrWhiteSpace($ObservedProcessStartFileTime) -or
                $ObservedProcessStartFileTime -cnotmatch '^[1-9][0-9]{0,19}$') {
                throw 'recorded bootstrap candidate process identity is invalid'
            }
            # Preserve the identity sampled during the loop even if the
            # successful short-lived process has exited before this census.
            $observedPid = $ObservedPid
            $observedStartFileTime = $ObservedProcessStartFileTime
        } else {
            $processes = @(Get-BootstrapForceReleaseCandidateProcesses `
                -CandidateFullPath $CandidateFullPath)
            if ($processes.Count -eq 1) {
                $observedPid = [long]$processes[0].ProcessId
                $observedStartFileTime = Get-ProcessStartFileTimeString `
                    -ProcessId ([int]$observedPid)
            } elseif ($processes.Count -gt 1) {
                throw 'multiple matching candidate processes exist while capturing attempt evidence'
            }
        }
    } catch {
        $snapshotError = Get-ExceptionChainText -ErrorRecord $_
    }
    [ordered]@{
        task_state = $taskState
        last_task_result = $lastTaskResult
        last_run_time_utc = $lastRunTimeUtc
        observed_pid = $observedPid
        observed_process_start_filetime = $observedStartFileTime
        receipt_exists = [bool](Test-Path -LiteralPath $ReceiptPath -PathType Leaf)
        snapshot_error_chain = $snapshotError
    }
}

function Write-BootstrapForceReleaseAttemptEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$CandidateFullPath,
        [Parameter(Mandatory = $true)][string]$CandidateSha256,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][string]$StartedAtUtc,
        [Parameter(Mandatory = $true)]$Snapshot,
        [AllowNull()]$Failure,
        [string]$CleanupErrorChain
    )

    if (@('succeeded', 'failed') -cnotcontains $Outcome) {
        throw 'Force-release attempt evidence outcome is invalid'
    }
    Assert-LowerSha256 -Value $CandidateSha256 `
        -Name 'Force-release attempt candidate SHA-256'
    $evidence = [ordered]@{
        schema_version = 1
        state = 'viewflow-bootstrap-force-release-attempt-recorded'
        outcome = $Outcome
        phase = $Phase
        operation_id = $OperationId
        task_path = $bootstrapTaskPath
        task_name = $TaskName
        candidate_path = $CandidateFullPath
        candidate_sha256 = $CandidateSha256
        receipt_path = [IO.Path]::GetFullPath($ReceiptPath)
        receipt_exists = [bool]$Snapshot.receipt_exists
        dispatch_deadline_seconds = [long]$bootstrapTaskDispatchDeadlineSeconds
        execution_deadline_seconds = [long]$bootstrapTaskExecutionDeadlineSeconds
        started_at_utc = $StartedAtUtc
        captured_at_utc = [DateTimeOffset]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture
        )
        task_state = $Snapshot.task_state
        last_task_result = $Snapshot.last_task_result
        last_run_time_utc = $Snapshot.last_run_time_utc
        observed_pid = $Snapshot.observed_pid
        observed_process_start_filetime = $Snapshot.observed_process_start_filetime
        snapshot_error_chain = $Snapshot.snapshot_error_chain
        error_chain = Get-ExceptionChainText -ErrorRecord $Failure
        cleanup_error_chain = $CleanupErrorChain
    }
    Write-OwnerOnlyCreateOnceJson -Path $Path -Value $evidence
    Assert-OwnerOnlyFileSecurity -Path $Path `
        -Name 'Bootstrap force-release attempt evidence'
    [pscustomobject]@{
        Path = [IO.Path]::GetFullPath($Path)
        Sha256 = Get-FileSha256Lower -Path $Path
    }
}

function Get-BootstrapForceReleaseDeadlineFailure {
    param(
        [Parameter(Mandatory = $true)][double]$DispatchElapsedSeconds,
        [AllowNull()][double]$ExecutionElapsedSeconds,
        [Parameter(Mandatory = $true)][string]$TaskFullName
    )

    if ($ExecutionElapsedSeconds -lt 0) {
        if ($DispatchElapsedSeconds -ge $bootstrapTaskDispatchDeadlineSeconds) {
            return "$TaskFullName was never dispatched within $bootstrapTaskDispatchDeadlineSeconds seconds"
        }
        return $null
    }
    if ($ExecutionElapsedSeconds -ge $bootstrapTaskExecutionDeadlineSeconds) {
        return "$TaskFullName exceeded its $bootstrapTaskExecutionDeadlineSeconds-second execution deadline"
    }
    $null
}

function Get-BootstrapForceReleaseMonotonicSeconds {
    param([Parameter(Mandatory = $true)][scriptblock]$Clock)

    try {
        $seconds = [double](& $Clock)
    } catch {
        throw [InvalidOperationException]::new(
            'Bootstrap force-release monotonic clock failed', $_.Exception
        )
    }
    if ([double]::IsNaN($seconds) -or [double]::IsInfinity($seconds) -or
        $seconds -lt 0) {
        throw 'Bootstrap force-release monotonic clock returned an invalid value'
    }
    $seconds
}

function Invoke-BootstrapForceRelease {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$CandidateSha256,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [scriptblock]$MonotonicSeconds = {
            [double][Diagnostics.Stopwatch]::GetTimestamp() /
                [double][Diagnostics.Stopwatch]::Frequency
        }
    )

    if ($OperationId -cnotmatch '^[A-Za-z0-9_-]{16,128}$') {
        throw 'Bootstrap force-release operation_id is invalid'
    }
    Assert-NewAbsoluteOutputPath -Path $ReceiptPath -Name 'Force-release receipt path'
    $candidateFullPath = [System.IO.Path]::GetFullPath($Candidate)
    $attemptEvidencePath = Get-BootstrapForceReleaseAttemptEvidencePath `
        -ReceiptPath $ReceiptPath
    Assert-NewAbsoluteOutputPath -Path $attemptEvidencePath `
        -Name 'Bootstrap force-release attempt evidence path'
    if ([IO.Path]::GetFullPath($attemptEvidencePath).Equals(
        [IO.Path]::GetFullPath($ReceiptPath),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Bootstrap force-release attempt evidence must not alias the receipt'
    }
    $bootstrapTaskName = 'Viewflow Bootstrap Force Release {0}' -f $OperationId
    $bootstrapTaskFullName = "${bootstrapTaskPath}${bootstrapTaskName}"
    $attemptStartedAtUtc = [DateTimeOffset]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $arguments = (
        'force-release-input --receipt "{0}" --operation-id {1} ' +
        '--linux-evidence-sha256 {2}'
    ) -f @(
        $ReceiptPath, $OperationId, $LinuxEvidenceSha256
    )
    $action = New-ScheduledTaskAction -Execute $candidateFullPath -Argument $arguments `
        -WorkingDirectory ([IO.Path]::GetDirectoryName($candidateFullPath))
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::FromSeconds(
            $bootstrapTaskExecutionDeadlineSeconds
        )) `
        -RestartCount 0
    $result = $null
    $primaryFailure = $null
    $cleanupFailures = @()
    $attemptSnapshot = $null
    $taskRegistered = $false
    $phase = 'pre-dispatch'
    try {
        $existing = Get-ScheduledTask -TaskPath $bootstrapTaskPath `
            -TaskName $bootstrapTaskName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            throw "$bootstrapTaskFullName already exists"
        }
        Register-ScheduledTask -TaskPath $bootstrapTaskPath -TaskName $bootstrapTaskName `
            -Action $action -Principal $principal -Settings $settings | Out-Null
        $taskRegistered = $true
        $registered = Get-ScheduledTask -TaskPath $bootstrapTaskPath `
            -TaskName $bootstrapTaskName
        if ($registered.State -ne 'Ready') {
            throw "$bootstrapTaskFullName must be Ready before force-release"
        }
        $bootstrapWindowStartUtc = [DateTime]::UtcNow
        $observedPid = $null
        $observedStartFileTime = $null
        Start-ScheduledTask -TaskPath $bootstrapTaskPath -TaskName $bootstrapTaskName
        $dispatchStartedSeconds = Get-BootstrapForceReleaseMonotonicSeconds `
            -Clock $MonotonicSeconds
        $executionStartedSeconds = $null
        $lastClockSeconds = $dispatchStartedSeconds
        do {
            $nowSeconds = Get-BootstrapForceReleaseMonotonicSeconds `
                -Clock $MonotonicSeconds
            if ($nowSeconds -lt $lastClockSeconds) {
                throw 'Bootstrap force-release monotonic clock moved backwards'
            }
            $lastClockSeconds = $nowSeconds
            $task = Get-ScheduledTask -TaskPath $bootstrapTaskPath `
                -TaskName $bootstrapTaskName
            $candidateProcesses = @(Get-BootstrapForceReleaseCandidateProcesses `
                -CandidateFullPath $candidateFullPath)
            if ($candidateProcesses.Count -gt 1) {
                throw 'Bootstrap force-release observed multiple candidate tool processes'
            }
            if ($null -eq $executionStartedSeconds -and
                ($task.State -eq 'Running' -or $candidateProcesses.Count -eq 1)) {
                # Running/PID is the first actual dispatch. Do not charge
                # interactive-session queueing against the execution limit.
                $executionStartedSeconds = $nowSeconds
                $phase = 'execution'
            }
            if ($candidateProcesses.Count -eq 1) {
                $candidateProcess = $candidateProcesses[0]
                $candidatePid = [long]$candidateProcess.ProcessId
                $candidateStartFileTime = Get-ProcessStartFileTimeString `
                    -ProcessId ([int]$candidatePid)
                if ($null -eq $observedPid) {
                    $observedPid = $candidatePid
                    $observedStartFileTime = $candidateStartFileTime
                } elseif ($observedPid -ne $candidatePid -or
                    $observedStartFileTime -cne $candidateStartFileTime) {
                    throw 'Bootstrap force-release candidate process identity changed'
                }
            }
            if ($task.State -eq 'Ready' -and $candidateProcesses.Count -eq 0 -and
                $null -ne $executionStartedSeconds) {
                if ($null -eq $observedPid) {
                    throw 'Bootstrap force-release tool process was never observed'
                }
                $taskInfo = Get-ScheduledTaskInfo -TaskPath $bootstrapTaskPath `
                    -TaskName $bootstrapTaskName
                $lastRunUtc = ([DateTime]$taskInfo.LastRunTime).ToUniversalTime()
                if ([long]$taskInfo.LastTaskResult -ne 0 -or
                    $lastRunUtc -lt $bootstrapWindowStartUtc.AddSeconds(-1) -or
                    $lastRunUtc -gt [DateTime]::UtcNow.AddSeconds(5)) {
                    throw 'Bootstrap force-release task result or LastRunTime is invalid'
                }
                if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
                    throw 'Bootstrap force-release task completed without a receipt'
                }
                $result = Assert-ForceReleaseReceipt -Path $ReceiptPath `
                    -OperationId $OperationId -CandidateSha256 $CandidateSha256 `
                    -LinuxEvidenceSha256 $LinuxEvidenceSha256 `
                    -ObservedPid $observedPid `
                    -ObservedProcessStartFileTime $observedStartFileTime
                $phase = 'succeeded'
                break
            }
            $deadlineFailure = Get-BootstrapForceReleaseDeadlineFailure `
                -DispatchElapsedSeconds ($nowSeconds - $dispatchStartedSeconds) `
                -ExecutionElapsedSeconds $(if ($null -eq $executionStartedSeconds) {
                    -1
                } else {
                    $nowSeconds - $executionStartedSeconds
                }) -TaskFullName $bootstrapTaskFullName
            if (-not [string]::IsNullOrWhiteSpace($deadlineFailure)) {
                throw $deadlineFailure
            }
            Start-Sleep -Milliseconds 100
        } while ($true)
    } catch {
        $primaryFailure = $_
        if ($phase -ceq 'pre-dispatch') { $phase = 'dispatch-failed' }
    } finally {
        # Snapshot before stop/unregister so failure and timeout evidence is
        # useful even when Task Scheduler history is disabled afterwards.
        $attemptObservedPid = 0
        if ($null -ne $observedPid) {
            $attemptObservedPid = [long]$observedPid
        }
        $attemptSnapshot = Get-BootstrapForceReleaseAttemptSnapshot `
            -TaskPath $bootstrapTaskPath -TaskName $bootstrapTaskName `
            -CandidateFullPath $candidateFullPath -ReceiptPath $ReceiptPath `
            -ObservedPid $attemptObservedPid `
            -ObservedProcessStartFileTime $observedStartFileTime
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$attemptSnapshot.snapshot_error_chain
        )) {
            $cleanupFailures += ('attempt snapshot: ' +
                [string]$attemptSnapshot.snapshot_error_chain)
        }
        if ($taskRegistered) {
            try {
                Stop-ScheduledTask -TaskPath $bootstrapTaskPath `
                    -TaskName $bootstrapTaskName -ErrorAction Stop
            } catch {
                $cleanupFailures += ('Stop-ScheduledTask: ' +
                    (Get-ExceptionChainText -ErrorRecord $_))
            }
            try {
                Unregister-ScheduledTask -TaskPath $bootstrapTaskPath `
                    -TaskName $bootstrapTaskName -Confirm:$false -ErrorAction Stop
            } catch {
                $cleanupFailures += ('Unregister-ScheduledTask: ' +
                    (Get-ExceptionChainText -ErrorRecord $_))
            }
            try {
                $remainingBootstrapTask = Get-ScheduledTask `
                    -TaskPath $bootstrapTaskPath -TaskName $bootstrapTaskName `
                    -ErrorAction SilentlyContinue
                if ($null -ne $remainingBootstrapTask) {
                    $cleanupFailures += "$bootstrapTaskFullName could not be removed"
                }
            } catch {
                $cleanupFailures += ('Get-ScheduledTask after cleanup: ' +
                    (Get-ExceptionChainText -ErrorRecord $_))
            }
            $cleanupWait = [Diagnostics.Stopwatch]::StartNew()
            $cleanupStableSinceMs = $null
            do {
                try {
                    $candidateProcesses = @(Get-BootstrapForceReleaseCandidateProcesses `
                        -CandidateFullPath $candidateFullPath)
                } catch {
                    $cleanupFailures += ('candidate process cleanup census: ' +
                        (Get-ExceptionChainText -ErrorRecord $_))
                    break
                }
                if ($candidateProcesses.Count -eq 0) {
                    if ($null -eq $cleanupStableSinceMs) {
                        $cleanupStableSinceMs = $cleanupWait.ElapsedMilliseconds
                    }
                    if (($cleanupWait.ElapsedMilliseconds - $cleanupStableSinceMs) -ge
                        $stopStableObservationMs) {
                        break
                    }
                } else {
                    $cleanupStableSinceMs = $null
                }
                Start-Sleep -Milliseconds 100
            } while ($cleanupWait.ElapsedMilliseconds -lt 20000)
            if ($null -eq $cleanupStableSinceMs -or
                ($cleanupWait.ElapsedMilliseconds - $cleanupStableSinceMs) -lt
                    $stopStableObservationMs) {
                $cleanupFailures += (
                    'Bootstrap candidate process did not remain absent for ' +
                    "$stopStableObservationMs ms after temporary-task removal"
                )
            }
        }
        try {
            $outcome = if ($null -eq $primaryFailure -and
                $cleanupFailures.Count -eq 0) { 'succeeded' } else { 'failed' }
            $null = Write-BootstrapForceReleaseAttemptEvidence `
                -Path $attemptEvidencePath -OperationId $OperationId `
                -TaskName $bootstrapTaskName -CandidateFullPath $candidateFullPath `
                -CandidateSha256 $CandidateSha256 -ReceiptPath $ReceiptPath `
                -Outcome $outcome -Phase $phase -StartedAtUtc $attemptStartedAtUtc `
                -Snapshot $attemptSnapshot -Failure $primaryFailure `
                -CleanupErrorChain ($cleanupFailures -join "`n")
        } catch {
            $cleanupFailures += ('attempt evidence publication: ' +
                (Get-ExceptionChainText -ErrorRecord $_))
        }
    }
    if ($null -ne $primaryFailure) {
        $message = "Bootstrap force-release failed during $phase.`n" +
            (Get-ExceptionChainText -ErrorRecord $primaryFailure)
        if ($cleanupFailures.Count -gt 0) {
            $message += "`ncleanup/evidence failure(s):`n" +
                ($cleanupFailures -join "`n")
        }
        throw [InvalidOperationException]::new($message, $primaryFailure.Exception)
    }
    if ($cleanupFailures.Count -gt 0) {
        throw ('Bootstrap force-release cleanup/evidence failed: ' +
            ($cleanupFailures -join "`n"))
    }
    if ($null -eq $result) {
        throw 'Bootstrap force-release completed without a result'
    }
    $result
}

function Get-ExactInstalledViewflowProcesses {
    @(
        Get-CimInstance Win32_Process -Filter "Name='viewflowd.exe'" |
            Where-Object { $_.ExecutablePath -eq $expectedExecutable }
    )
}

function Assert-ExpectedViewflowProcess {
    param(
        [Parameter(Mandatory = $true)]
        $Process
    )

    if ($Process.SessionId -ne 1) {
        throw "Viewflow must run in interactive Session 1, got $($Process.SessionId)"
    }

    $commandLine = [string]$Process.CommandLine
    $requiredArguments = @(
        ' connect',
        "--peer $expectedPeer",
        "--server-name $expectedServerName",
        '--input-backend native',
        "--device-id $expectedDeviceId"
    )
    foreach ($argument in $requiredArguments) {
        if ($commandLine.IndexOf($argument, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Viewflow process command line is missing expected argument: $argument"
        }
    }

    $pathArguments = @{
        '--cert' = $expectedCert
        '--key' = $expectedKey
        '--ca' = $expectedCa
    }
    foreach ($name in $pathArguments.Keys) {
        $escapedPath = [regex]::Escape($pathArguments[$name])
        $pathPattern = '(?i)(?:^|\s){0}\s+(?:"{1}"|''{1}''|{1})(?:\s|$)' -f @(
            [regex]::Escape($name),
            $escapedPath
        )
        if ($commandLine -notmatch $pathPattern) {
            throw "Viewflow process command line has an invalid $name path"
        }
    }
}

function Assert-ExpectedIdentityMaterial {
    $identityFiles = @(
        @{ Path = $expectedCert; Pattern = '(?s)-----BEGIN CERTIFICATE-----\s*(?<payload>[A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----'; Name = 'peer certificate'; Certificate = $true },
        @{ Path = $expectedKey; Pattern = '(?s)-----BEGIN (?<label>(?:RSA |EC )?PRIVATE KEY)-----\s*(?<payload>[A-Za-z0-9+/=\s]+?)\s*-----END \k<label>-----'; Name = 'peer private key'; Certificate = $false },
        @{ Path = $expectedCa; Pattern = '(?s)-----BEGIN CERTIFICATE-----\s*(?<payload>[A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----'; Name = 'CA certificate'; Certificate = $true }
    )

    foreach ($identity in $identityFiles) {
        if (-not (Test-Path -LiteralPath $identity.Path -PathType Leaf)) {
            throw "Expected $($identity.Name) does not exist: $($identity.Path)"
        }
        $file = Get-Item -LiteralPath $identity.Path
        if ($file.Length -eq 0) {
            throw "Expected $($identity.Name) is empty: $($identity.Path)"
        }
        $content = Get-Content -LiteralPath $identity.Path -Raw
        $pemBlocks = [regex]::Matches($content, $identity.Pattern)
        if ($pemBlocks.Count -eq 0) {
            throw "Expected $($identity.Name) is not PEM-encoded: $($identity.Path)"
        }
        foreach ($pemBlock in $pemBlocks) {
            try {
                $payload = $pemBlock.Groups['payload'].Value -replace '\s', ''
                $derBytes = [Convert]::FromBase64String($payload)
                if ($derBytes.Length -eq 0) {
                    throw 'decoded PEM payload is empty'
                }
                if ($identity.Certificate) {
                    $certificate = New-Object -TypeName `
                        System.Security.Cryptography.X509Certificates.X509Certificate2 `
                        -ArgumentList @(, $derBytes)
                    $certificate.Reset()
                }
            } catch {
                throw "Expected $($identity.Name) contains an invalid PEM payload: $($identity.Path)"
            }
        }
    }
}

function Stop-ViewflowTaskAndWait {
    param(
        [switch]$IgnoreStopError,
        [switch]$AllowDisabled
    )

    if ($IgnoreStopError) {
        Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
            -ErrorAction SilentlyContinue
    } else {
        Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    }

    $wait = [Diagnostics.Stopwatch]::StartNew()
    $stableSinceMs = $null
    do {
        $running = @(Get-ExactInstalledViewflowProcesses)
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        $inactiveTaskState = $task.State -eq 'Ready' -or
            ($AllowDisabled -and $task.State -eq 'Disabled')
        if ($running.Count -eq 0 -and $inactiveTaskState) {
            if ($null -eq $stableSinceMs) {
                $stableSinceMs = $wait.ElapsedMilliseconds
            }
            if (($wait.ElapsedMilliseconds - $stableSinceMs) -ge $stopStableObservationMs) {
                return
            }
        } else {
            $stableSinceMs = $null
        }
        Start-Sleep -Milliseconds 100
    } while ($wait.ElapsedMilliseconds -lt 20000)

    throw (
        'The Viewflow task and exact installed process did not remain stopped ' +
        "for $stopStableObservationMs ms within 20 seconds"
    )
}

function Assert-AuthenticatedReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$DaemonSha256,
        [Parameter(Mandatory = $true)]$ProcessIdentity
    )
    $receiptRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $ReceiptPath `
        -Name 'Authenticated readiness receipt'
    $receipt = $receiptRead.Value
    Assert-ExactPropertySet -Value $receipt `
        -Context 'Authenticated readiness receipt' -Names @(
            'schema_version', 'state', 'validity', 'operation_id',
            'daemon_executable_sha256', 'daemon_pid',
            'daemon_process_start_filetime', 'daemon_session_id',
            'daemon_user_sid', 'connection_generation', 'input_backend',
            'local_device_id', 'peer_address', 'server_name',
            'protocol_major', 'protocol_minor', 'probe_round_trip_ns',
            'probe_max_round_trip_ns', 'probe_uncertainty_ns',
            'probe_max_uncertainty_ns', 'readiness_lock_path',
            'readiness_lock_sha256', 'established_at_utc'
        )
    if ($receipt.schema_version -isnot [int] -or
        $receipt.schema_version -ne 1 -or
        $receipt.state -isnot [string] -or
        $receipt.state -cne 'viewflow-post-mtls-readiness-established' -or
        $receipt.validity -isnot [string] -or
        $receipt.validity -cne 'while-readiness-lock-is-held' -or
        $receipt.operation_id -isnot [string] -or
        $receipt.operation_id -cne $OperationId -or
        $receipt.input_backend -isnot [string] -or
        $receipt.input_backend -cne 'native' -or
        $receipt.local_device_id -isnot [string] -or
        $receipt.local_device_id -cne $expectedDeviceId -or
        $receipt.peer_address -isnot [string] -or
        $receipt.peer_address -cne $expectedPeer -or
        $receipt.server_name -isnot [string] -or
        $receipt.server_name -cne $expectedServerName) {
        throw 'Authenticated readiness state or endpoint binding is invalid'
    }
    Assert-LowerSha256 -Value $receipt.daemon_executable_sha256 `
        -Name 'Readiness daemon_executable_sha256'
    Assert-LowerSha256 -Value $receipt.readiness_lock_sha256 `
        -Name 'Readiness readiness_lock_sha256'
    $processStart = [string]$ProcessIdentity.ProcessStartFileTime
    $processSid = [string]$ProcessIdentity.OwnerSid
    if ([string]$receipt.daemon_executable_sha256 -cne $DaemonSha256 -or
        -not (Test-JsonInteger -Value $receipt.daemon_pid) -or
        [long]$receipt.daemon_pid -ne [long]$ProcessIdentity.ProcessId -or
        $receipt.daemon_process_start_filetime -isnot [string] -or
        $receipt.daemon_process_start_filetime -cne $processStart -or
        -not (Test-JsonInteger -Value $receipt.daemon_session_id) -or
        [long]$receipt.daemon_session_id -ne 1 -or
        $receipt.daemon_user_sid -isnot [string] -or
        $receipt.daemon_user_sid -cne $processSid -or
        $processSid -cne $expectedTaskUserSid -or
        -not (Test-JsonInteger -Value $receipt.connection_generation) -or
        [long]$receipt.connection_generation -le 0 -or
        -not (Test-JsonInteger -Value $receipt.protocol_major) -or
        [long]$receipt.protocol_major -ne 2 -or
        -not (Test-JsonInteger -Value $receipt.protocol_minor) -or
        [long]$receipt.protocol_minor -ne 1 -or
        -not (Test-JsonInteger -Value $receipt.probe_round_trip_ns) -or
        [long]$receipt.probe_round_trip_ns -lt 0 -or
        -not (Test-JsonInteger -Value $receipt.probe_max_round_trip_ns) -or
        [long]$receipt.probe_max_round_trip_ns -ne 33333334 -or
        [long]$receipt.probe_round_trip_ns -gt
            [long]$receipt.probe_max_round_trip_ns -or
        -not (Test-JsonInteger -Value $receipt.probe_uncertainty_ns) -or
        [long]$receipt.probe_uncertainty_ns -lt 0 -or
        -not (Test-JsonInteger -Value $receipt.probe_max_uncertainty_ns) -or
        [long]$receipt.probe_max_uncertainty_ns -ne 4000000 -or
        [long]$receipt.probe_uncertainty_ns -gt
            [long]$receipt.probe_max_uncertainty_ns) {
        throw 'Authenticated readiness process, protocol, or clock evidence is invalid'
    }
    try {
        $null = [uint64]::Parse(
            [string]$receipt.daemon_process_start_filetime,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture
        )
    } catch {
        throw 'Readiness daemon_process_start_filetime exceeds uint64'
    }
    $receiptLockPath = [IO.Path]::GetFullPath(
        [string]$receipt.readiness_lock_path
    )
    if (-not $receiptLockPath.Equals(
        [IO.Path]::GetFullPath($LockPath),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Authenticated readiness lock path is invalid'
    }
    $pinnedReceipt = Open-PinnedReadinessReceiptSnapshot -Path $ReceiptPath `
        -Name 'Authenticated readiness receipt pinned snapshot'
    if ([string]$pinnedReceipt.Sha256 -cne [string]$receiptRead.Sha256) {
        $pinnedReceipt.Stream.Dispose()
        throw 'Authenticated readiness receipt changed before it was pinned'
    }
    try {
        $pinnedLock = Open-PinnedReadinessLockSnapshot -Path $LockPath `
            -Name 'Authenticated readiness lock'
    } catch {
        $pinnedReceipt.Stream.Dispose()
        throw
    }
    $returnPinnedHandles = $false
    try {
        $lockRead = $pinnedLock
        if ([string]$lockRead.Sha256 -cne
            [string]$receipt.readiness_lock_sha256) {
            throw 'Authenticated readiness lock SHA-256 is invalid'
        }
        $lock = $lockRead.Value
        Assert-ExactPropertySet -Value $lock -Context 'Authenticated readiness lock' `
            -Names @(
                'schema_version', 'state', 'operation_id', 'daemon_pid',
                'daemon_process_start_filetime', 'connection_generation'
            )
        if ($lock.schema_version -isnot [int] -or
            $lock.schema_version -ne 1 -or
            $lock.state -isnot [string] -or
            $lock.state -cne 'viewflow-post-mtls-readiness-lock' -or
            $lock.operation_id -isnot [string] -or
            $lock.operation_id -cne $OperationId -or
            -not (Test-JsonInteger -Value $lock.daemon_pid) -or
            [long]$lock.daemon_pid -ne [long]$ProcessIdentity.ProcessId -or
            $lock.daemon_process_start_filetime -isnot [string] -or
            $lock.daemon_process_start_filetime -cne $processStart -or
            -not (Test-JsonInteger -Value $lock.connection_generation) -or
            [long]$lock.connection_generation -ne
                [long]$receipt.connection_generation) {
            throw 'Authenticated readiness lock identity is invalid'
        }
        Assert-ReadinessLockIsLive -Path $LockPath
        Assert-FreshUtcTimestamp -Value $receipt.established_at_utc `
            -Name 'Readiness established_at_utc'

        $receiptReadAgain = Read-Utf8JsonStreamSnapshot `
            -Stream $pinnedReceipt.Stream `
            -Name 'Authenticated readiness receipt revalidation'
        $lockReadAgain = Read-Utf8JsonStreamSnapshot `
            -Stream $pinnedLock.Stream `
            -Name 'Authenticated readiness lock revalidation'
        if ([string]$receiptReadAgain.Sha256 -cne [string]$receiptRead.Sha256 -or
            [string]$lockReadAgain.Sha256 -cne [string]$lockRead.Sha256) {
            throw 'Authenticated readiness artifacts changed during validation'
        }
        $null = Assert-ViewflowProcessIdentityCurrent -Identity $ProcessIdentity
        Assert-ReadinessLockIsLive -Path $LockPath

        $result = [pscustomobject]@{
            Receipt = $receipt
            ReceiptSha256 = [string]$receiptRead.Sha256
            LockSha256 = [string]$lockRead.Sha256
            ConnectionGeneration = [long]$receipt.connection_generation
            EstablishedAtUtc = [string]$receipt.established_at_utc
            ReceiptStream = $pinnedReceipt.Stream
            LockStream = $pinnedLock.Stream
        }
        $returnPinnedHandles = $true
        $result
    } finally {
        if (-not $returnPinnedHandles) {
            Close-AuthenticatedReadinessLease -Readiness ([pscustomobject]@{
                ReceiptStream = $pinnedReceipt.Stream
                LockStream = $pinnedLock.Stream
            })
        }
    }
}

function Assert-AuthenticatedReadinessCommitBoundary {
    param(
        [Parameter(Mandatory = $true)]$Readiness,
        [Parameter(Mandatory = $true)][string]$ReceiptPath,
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)]$ProcessIdentity,
        [Parameter(Mandatory = $true)][string]$ExpectedTaskXmlSha256
    )

    if ($null -eq $Readiness.ReceiptStream -or
        -not $Readiness.ReceiptStream.CanRead -or
        $null -eq $Readiness.LockStream -or
        -not $Readiness.LockStream.CanRead) {
        throw 'Authenticated readiness pinned handles are not available at commit'
    }
    $receiptRead = Read-Utf8JsonStreamSnapshot `
        -Stream $Readiness.ReceiptStream `
        -Name 'Authenticated readiness receipt commit revalidation'
    $lockRead = Read-Utf8JsonStreamSnapshot -Stream $Readiness.LockStream `
        -Name 'Authenticated readiness lock commit revalidation'
    if ([string]$receiptRead.Sha256 -cne [string]$Readiness.ReceiptSha256 -or
        [string]$lockRead.Sha256 -cne [string]$Readiness.LockSha256) {
        throw 'Authenticated readiness artifacts changed before commit'
    }
    $null = Assert-ViewflowProcessIdentityCurrent -Identity $ProcessIdentity
    $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Assert-ExpectedScheduledTask -Task $task -RequireRunning
    $taskXml = Export-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Assert-TaskXmlContract -Xml $taskXml -RequireCurrentReadinessBinding
    $taskXmlSha256 = Get-BytesSha256Lower -Value (
        Get-Utf16TaskXmlBytes -Xml $taskXml
    )
    if ($taskXmlSha256 -cne $ExpectedTaskXmlSha256) {
        throw 'Scheduled-task XML changed before commit'
    }
    Assert-ReadinessLockIsLive -Path $LockPath
}

function Close-AuthenticatedReadinessLease {
    param($Readiness)

    if ($null -eq $Readiness) {
        return
    }
    $closeFailures = New-Object 'System.Collections.Generic.List[System.Exception]'
    foreach ($streamName in @('ReceiptStream', 'LockStream')) {
        $property = $Readiness.PSObject.Properties[$streamName]
        if ($null -ne $property -and $null -ne $property.Value) {
            $stream = $property.Value
            $property.Value = $null
            try {
                $stream.Dispose()
            } catch {
                $closeFailures.Add([InvalidOperationException]::new(
                    "Failed to close authenticated readiness $streamName",
                    $_.Exception
                ))
            }
        }
    }
    if ($closeFailures.Count -gt 0) {
        throw [AggregateException]::new(
            'One or more authenticated readiness handles could not be closed',
            $closeFailures.ToArray()
        )
    }
}

function Wait-BootstrapLinuxStageReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$BootstrapRequestSha256,
        [Parameter(Mandatory = $true)]$MarkerHandoff,
        [Parameter(Mandatory = $true)][string]$MarkerHandoffSha256,
        [Parameter(Mandatory = $true)][string]$PreparedReceiptSha256,
        [Parameter(Mandatory = $true)]$MutationPermit,
        [Parameter(Mandatory = $true)][string]$MutationPermitPath,
        [Parameter(Mandatory = $true)][string]$MutationPermitSha256,
        [Parameter(Mandatory = $true)][string]$ForceEnvelopeSha256,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$WindowsCandidateSha256
    )
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-PinnedBootstrapRequestCurrent
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $permitAgain = Read-OwnerOnlyUtf8JsonSnapshot `
                -Path $MutationPermitPath -Name 'Mutation permit revalidation'
            if ([string]$permitAgain.Sha256 -cne $MutationPermitSha256) {
                throw 'Mutation permit changed before Linux stage publication'
            }
            $stageRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $Path `
                -Name 'Linux bootstrap stage receipt'
            $stage = $stageRead.Value
            Assert-ExactPropertySet -Value $stage `
                -Context 'Linux bootstrap stage receipt' -Names @(
                    'artifact_hashes', 'backup_directory',
                    'backup_manifest_sha256', 'completed_at_unix_ms',
                    'evidence_hashes', 'freeze_state', 'marker',
                    'operation_id', 'protocol_version', 'runtime',
                    'schema_version', 'source_display_id', 'state',
                    'target_device_id', 'windows_viewflow_sha256'
                )
            if ($stage.schema_version -isnot [int] -or
                $stage.schema_version -ne 1 -or
                $stage.state -isnot [string] -or
                $stage.state -cne 'viewflow-linux-bootstrap-staged' -or
                $stage.operation_id -isnot [string] -or
                $stage.operation_id -cne $OperationId -or
                $stage.protocol_version -isnot [string] -or
                $stage.protocol_version -cne '2.1' -or
                $stage.source_display_id -isnot [string] -or
                $stage.source_display_id -cne $expectedSourceDisplayUuid -or
                $stage.target_device_id -isnot [string] -or
                $stage.target_device_id -cne $expectedTargetDeviceUuid -or
                $stage.windows_viewflow_sha256 -isnot [string] -or
                $stage.windows_viewflow_sha256 -cne $WindowsCandidateSha256 -or
                $stage.backup_directory -isnot [string] -or
                $stage.backup_directory -cnotmatch '^/home/wilf/.+' -or
                -not (Test-JsonInteger -Value $stage.completed_at_unix_ms) -or
                [long]$stage.completed_at_unix_ms -le 0) {
                throw 'Linux bootstrap stage schema or fixed identity is invalid'
            }
            Assert-LowerSha256 -Value $stage.backup_manifest_sha256 `
                -Name 'Linux stage backup_manifest_sha256'

            Assert-ExactPropertySet -Value $stage.evidence_hashes `
                -Context 'Linux stage evidence_hashes' -Names @(
                    'bootstrap_request', 'linux_frozen_evidence',
                    'marker_handoff_receipt', 'mutation_permit',
                    'windows_force_release_envelope',
                    'windows_prepared_receipt',
                    'deployment_publish_receipt'
                )
            $evidenceBindings = @(
                @{ Name = 'bootstrap_request'; Expected = $BootstrapRequestSha256 },
                @{ Name = 'linux_frozen_evidence'; Expected = $LinuxEvidenceSha256 },
                @{ Name = 'marker_handoff_receipt'; Expected = $MarkerHandoffSha256 },
                @{ Name = 'mutation_permit'; Expected = $MutationPermitSha256 },
                @{ Name = 'windows_force_release_envelope'; Expected = $ForceEnvelopeSha256 },
                @{ Name = 'windows_prepared_receipt'; Expected = $PreparedReceiptSha256 },
                @{ Name = 'deployment_publish_receipt'; Expected = [string]$MarkerHandoff.deployment_publish_receipt_sha256 }
            )
            foreach ($binding in $evidenceBindings) {
                $value = $stage.evidence_hashes.PSObject.Properties[
                    $binding.Name
                ].Value
                Assert-LowerSha256 -Value $value `
                    -Name "Linux stage evidence $($binding.Name)"
                if ([string]$value -cne [string]$binding.Expected) {
                    throw "Linux stage evidence hash is invalid: $($binding.Name)"
                }
            }

            Assert-ExactPropertySet -Value $stage.marker `
                -Context 'Linux stage marker' -Names @(
                    'path', 'identity', 'sha256', 'coordinator_instance_id',
                    'marker_generation'
                )
            if ($stage.marker.path -isnot [string] -or
                $stage.marker.path -cne [string]$MarkerHandoff.deployment_marker_path -or
                $stage.marker.identity -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$stage.marker.identity) -or
                $stage.marker.sha256 -isnot [string] -or
                $stage.marker.sha256 -cne
                    [string]$MarkerHandoff.deployment_marker_sha256 -or
                $stage.marker.coordinator_instance_id -isnot [string] -or
                $stage.marker.coordinator_instance_id -cne
                    [string]$MarkerHandoff.coordinator_instance_id -or
                $stage.marker.marker_generation -isnot [string] -or
                $stage.marker.marker_generation -cne
                    [string]$MarkerHandoff.marker_generation) {
                throw 'Linux stage VFDQT001 marker binding is invalid'
            }

            Assert-ExactPropertySet -Value $stage.artifact_hashes `
                -Context 'Linux stage artifact_hashes' -Names @(
                    'old_viewflowd', 'old_deployment_marker_tool',
                    'old_viewflow_unit', 'staged_viewflowd',
                    'staged_deployment_marker_tool', 'staged_viewflow_unit',
                    'preserved_deskflow', 'preserved_deskflow_core',
                    'preserved_deskflow_dropin'
                )
            foreach ($artifactName in @(
                'old_viewflowd', 'old_deployment_marker_tool',
                'old_viewflow_unit', 'staged_viewflowd',
                'staged_deployment_marker_tool', 'staged_viewflow_unit',
                'preserved_deskflow', 'preserved_deskflow_core',
                'preserved_deskflow_dropin'
            )) {
                Assert-LowerSha256 `
                    -Value $stage.artifact_hashes.PSObject.Properties[
                        $artifactName
                    ].Value -Name "Linux stage artifact $artifactName"
            }
            if ([string]$stage.artifact_hashes.staged_viewflowd -cne
                    [string]$MutationPermit.linux_viewflowd_sha256 -or
                [string]$stage.artifact_hashes.staged_deployment_marker_tool -cne
                    [string]$MutationPermit.linux_deployment_marker_sha256 -or
                [string]$stage.artifact_hashes.staged_viewflow_unit -cne
                    [string]$MutationPermit.linux_viewflow_unit_sha256 -or
                [string]$stage.artifact_hashes.old_deployment_marker_tool -cne
                    [string]$MarkerHandoff.marker_cli_sha256 -or
                [string]$stage.artifact_hashes.preserved_deskflow -cne
                    [string]$MarkerHandoff.deskflow_executable_sha256 -or
                [string]$stage.artifact_hashes.preserved_deskflow_core -cne
                    [string]$MarkerHandoff.deskflow_core_executable_sha256) {
                throw 'Linux stage installed or preserved artifact binding is invalid'
            }

            Assert-ExactPropertySet -Value $stage.freeze_state `
                -Context 'Linux stage freeze_state' -Names @(
                    'deskflow_unit_active_state', 'deskflow_unit_main_pid',
                    'deskflow_exact_process_count',
                    'deskflow_core_exact_process_count',
                    'deskflow_tcp_listener_count', 'runtime_marker_path',
                    'runtime_marker_present'
                )
            if ($stage.freeze_state.deskflow_unit_active_state -isnot [string] -or
                $stage.freeze_state.deskflow_unit_active_state -cne 'inactive' -or
                -not (Test-JsonInteger -Value $stage.freeze_state.deskflow_unit_main_pid) -or
                [long]$stage.freeze_state.deskflow_unit_main_pid -ne 0 -or
                -not (Test-JsonInteger -Value $stage.freeze_state.deskflow_exact_process_count) -or
                [long]$stage.freeze_state.deskflow_exact_process_count -ne 0 -or
                -not (Test-JsonInteger -Value $stage.freeze_state.deskflow_core_exact_process_count) -or
                [long]$stage.freeze_state.deskflow_core_exact_process_count -ne 0 -or
                -not (Test-JsonInteger -Value $stage.freeze_state.deskflow_tcp_listener_count) -or
                [long]$stage.freeze_state.deskflow_tcp_listener_count -ne 0 -or
                $stage.freeze_state.runtime_marker_path -isnot [string] -or
                $stage.freeze_state.runtime_marker_path -cne
                    '/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' -or
                $stage.freeze_state.runtime_marker_present -isnot [bool] -or
                [bool]$stage.freeze_state.runtime_marker_present) {
                throw 'Linux stage did not retain the exact frozen Deskflow boundary'
            }

            Assert-ExactPropertySet -Value $stage.runtime `
                -Context 'Linux stage runtime' -Names @(
                    'pid', 'start_ticks', 'boot_id', 'invocation_id',
                    'authenticated_peer_ip',
                    'authenticated_peer_record_sha256',
                    'authenticated_at_unix_ms'
                )
            if (-not (Test-JsonInteger -Value $stage.runtime.pid) -or
                [long]$stage.runtime.pid -le 0 -or
                -not (Test-JsonInteger -Value $stage.runtime.start_ticks) -or
                [long]$stage.runtime.start_ticks -le 0 -or
                $stage.runtime.boot_id -isnot [string] -or
                $stage.runtime.boot_id -cnotmatch
                    '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -or
                $stage.runtime.invocation_id -isnot [string] -or
                $stage.runtime.invocation_id -cnotmatch '^[0-9a-f]{32}$' -or
                $stage.runtime.authenticated_peer_ip -isnot [string] -or
                $stage.runtime.authenticated_peer_ip -cne '172.16.105.70' -or
                -not (Test-JsonInteger -Value $stage.runtime.authenticated_at_unix_ms) -or
                [long]$stage.runtime.authenticated_at_unix_ms -le 0) {
                throw 'Linux stage runtime or authenticated Windows peer is invalid'
            }
            Assert-LowerSha256 `
                -Value $stage.runtime.authenticated_peer_record_sha256 `
                -Name 'Linux stage authenticated peer record SHA-256'
            return [pscustomobject]@{
                Receipt = $stage
                Sha256 = [string]$stageRead.Sha256
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($wait.Elapsed.TotalSeconds -lt 600)
    throw 'Linux bootstrap stage receipt was not published within 600 seconds'
}

function Start-ViewflowTaskAndWait {
    param(
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$ReadinessReceiptPath,
        [Parameter(Mandatory = $true)][string]$ReadinessLockPath,
        [Parameter(Mandatory = $true)][string]$ExpectedDaemonSha256,
        [AllowNull()]$BootstrapStageContext
    )
    Start-ScheduledTask -TaskPath $taskPath -TaskName $taskName

    $stageReceipt = $null
    if ($null -ne $BootstrapStageContext) {
        $stageReceipt = Wait-BootstrapLinuxStageReceipt @BootstrapStageContext
    }

    $wait = [Diagnostics.Stopwatch]::StartNew()
    $stableProcessIdentityKey = $null
    $stableProcessIdentity = $null
    $stableSinceMs = $null
    do {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        $running = @(
            Get-ExactInstalledViewflowProcesses |
                Where-Object { $_.SessionId -eq 1 }
        )
        if ($task.State -eq 'Running' -and $running.Count -eq 1) {
            $identity = Get-ViewflowProcessIdentity -Process $running[0]
            $identityKey = '{0}:{1}' -f @(
                [long]$identity.ProcessId,
                [string]$identity.ProcessStartFileTime
            )
            if ($stableProcessIdentityKey -cne $identityKey) {
                $stableProcessIdentityKey = $identityKey
                $stableProcessIdentity = $identity
                $stableSinceMs = $wait.ElapsedMilliseconds
            }

            if (($wait.ElapsedMilliseconds - $stableSinceMs) -ge
                    $startStableObservationMs -and
                (Test-Path -LiteralPath $ReadinessReceiptPath -PathType Leaf) -and
                (Test-Path -LiteralPath $ReadinessLockPath -PathType Leaf)) {
                $readiness = Assert-AuthenticatedReadiness `
                    -ReceiptPath $ReadinessReceiptPath `
                    -LockPath $ReadinessLockPath `
                    -OperationId $OperationId `
                    -DaemonSha256 $ExpectedDaemonSha256 `
                    -ProcessIdentity $stableProcessIdentity
                try {
                    $finalTask = Get-ScheduledTask -TaskPath $taskPath `
                        -TaskName $taskName
                    if ($finalTask.State -ne 'Running') {
                        throw 'Viewflow task left Running state during readiness validation'
                    }
                    $finalProcess = Assert-ViewflowProcessIdentityCurrent `
                        -Identity $stableProcessIdentity
                    return [pscustomobject]@{
                        Process = $finalProcess
                        Identity = $stableProcessIdentity
                        Readiness = $readiness
                        LinuxStageReceipt = $stageReceipt
                    }
                } catch {
                    Close-AuthenticatedReadinessLease -Readiness $readiness
                    throw
                }
            }
        } else {
            $stableProcessIdentityKey = $null
            $stableProcessIdentity = $null
            $stableSinceMs = $null
        }
        Start-Sleep -Milliseconds 100
    } while ($wait.Elapsed.TotalSeconds -lt $readinessWaitSeconds)

    throw (
        'The Viewflow task did not establish stable post-mTLS readiness within ' +
        "$readinessWaitSeconds seconds"
    )
}

function Assert-ExpectedWrapperConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $content = Get-Content -LiteralPath $Path -Raw
    $requiredFragments = @(
        "--peer $expectedPeer",
        "--server-name $expectedServerName",
        '--cert (Join-Path $identityRoot ''peer.pem'')',
        '--key (Join-Path $identityRoot ''peer.key'')',
        '--ca (Join-Path $identityRoot ''ca.pem'')',
        '--input-backend native',
        "--device-id $expectedDeviceId"
    )
    foreach ($fragment in $requiredFragments) {
        if ($content.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Reviewed client script is missing expected argument: $fragment"
        }
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

function Assert-TaskActionArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$RequireCurrentReadinessBinding
    )

    $actual = @(Split-WindowsCommandLine -CommandLine $Arguments)
    $base = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden', '-File', $installedScript
    )
    $current = $base + @(
        '-ReadinessReceiptPath', $expectedReadinessReceiptPath,
        '-ReadinessLockPath', $expectedReadinessLockPath,
        '-ReadinessCommitRequestPath', $expectedReadinessCommitRequestPath,
        '-InstallSuccessReceiptPath', $expectedInstallSuccessReceiptPath,
        '-OperationId', $expectedOperationId
    )
    if ($RequireCurrentReadinessBinding) {
        Assert-ExactArguments -Actual $actual -Expected $current -Context $Context `
            -PathIndexes @('7', '9', '11', '13', '15')
        return
    }
    if ($actual.Count -eq $base.Count) {
        Assert-ExactArguments -Actual $actual -Expected $base -Context $Context `
            -PathIndexes @('7')
        return
    }
    if ($actual.Count -ne ($base.Count + 6) -and
        $actual.Count -ne ($base.Count + 10)) {
        throw "$Context has an unexpected argument count"
    }
    Assert-ExactArguments -Actual $actual[0..7] -Expected $base -Context $Context `
        -PathIndexes @('7')
    if ([string]$actual[8] -cne '-ReadinessReceiptPath' -or
        [string]$actual[10] -cne '-ReadinessLockPath' -or
        -not [IO.Path]::IsPathRooted([string]$actual[9]) -or
        -not [IO.Path]::IsPathRooted([string]$actual[11])) {
        throw "$Context has invalid prior readiness bindings"
    }
    if ($actual.Count -eq ($base.Count + 6)) {
        if ([string]$actual[12] -cne '-OperationId' -or
            [string]$actual[13] -cnotmatch '^[A-Za-z0-9_-]{16,128}$') {
            throw "$Context has invalid prior readiness bindings"
        }
        $priorPaths = @($actual[9], $actual[11])
    } else {
        if ([string]$actual[12] -cne '-ReadinessCommitRequestPath' -or
            [string]$actual[14] -cne '-InstallSuccessReceiptPath' -or
            [string]$actual[16] -cne '-OperationId' -or
            -not [IO.Path]::IsPathRooted([string]$actual[13]) -or
            -not [IO.Path]::IsPathRooted([string]$actual[15]) -or
            [string]$actual[17] -cnotmatch '^[A-Za-z0-9_-]{16,128}$') {
            throw "$Context has invalid prior commit bindings"
        }
        $priorPaths = @($actual[9], $actual[11], $actual[13], $actual[15])
    }
    $normalizedPriorPaths = @(
        $priorPaths | ForEach-Object { [IO.Path]::GetFullPath([string]$_) }
    )
    for ($left = 0; $left -lt $normalizedPriorPaths.Count; $left++) {
        for ($right = $left + 1; $right -lt $normalizedPriorPaths.Count; $right++) {
            if ($normalizedPriorPaths[$left].Equals(
                $normalizedPriorPaths[$right],
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "$Context prior readiness and commit paths must be distinct"
            }
        }
    }
}

function Resolve-LegacyLogonTriggerSid {
    param(
        [Parameter(Mandatory = $true)][string]$Account,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if ([string]::IsNullOrWhiteSpace($Account)) {
        throw "$Context UserId is empty"
    }
    try {
        if ($Account -match '^S-\d-') {
            return ([Security.Principal.SecurityIdentifier]::new($Account)).Value
        }
        return (New-Object Security.Principal.NTAccount `
            -ArgumentList $Account).Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
    } catch {
        throw "$Context UserId cannot be resolved: $Account"
    }
}

function Assert-LegacyOrNoTaskTriggers {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$AllowLegacyLogonTrigger
    )

    # PowerShell 5.1 can report an inline filtered expression incorrectly when
    # ScheduledTasks exposes Triggers as $null. Materialize it before counting.
    $taskTriggers = @($Task.Triggers | Where-Object { $null -ne $_ })
    if ($taskTriggers.Count -eq 0) {
        return
    }
    if (-not $AllowLegacyLogonTrigger -or $taskTriggers.Count -ne 1) {
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
        (Resolve-LegacyLogonTriggerSid -Account ([string]$userProperty.Value) `
            -Context "$Context legacy LogonTrigger") -cne
                $expectedTaskUserSid) {
        throw "$Context legacy LogonTrigger user does not match the installer user"
    }
}

function Assert-UpdatableScheduledTask {
    param(
        [Parameter(Mandatory = $true)]
        $Task,

        [switch]$RequireRunning,

        [switch]$AllowLegacyLogonTrigger
    )

    if ($RequireRunning -and $Task.State -ne 'Running') {
        throw "${expectedTaskName} must be running before an in-place update"
    }

    $actions = @($Task.Actions)
    if ($actions.Count -ne 1) {
        throw "${expectedTaskName} must have exactly one action"
    }
    $actionExecutable = (
        [Environment]::ExpandEnvironmentVariables([string]$actions[0].Execute)
    ).Trim('"')
    if ([System.IO.Path]::GetFileName($actionExecutable) -ine 'powershell.exe') {
        throw "${expectedTaskName} must use Windows PowerShell 5.1"
    }

    Assert-TaskActionArguments -Arguments ([string]$actions[0].Arguments) `
        -Context "${expectedTaskName} action"
    $workingDirectory = [IO.Path]::GetFullPath([string]$actions[0].WorkingDirectory)
    if (-not $workingDirectory.Equals(
        $installRoot,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "${expectedTaskName} working directory is invalid"
    }

    if ([string]$Task.Principal.LogonType -ne 'Interactive') {
        throw "${expectedTaskName} must use the Interactive logon type"
    }
    $taskUserId = [string]$Task.Principal.UserId
    if ([string]::IsNullOrWhiteSpace($taskUserId)) {
        throw "${expectedTaskName} principal UserId is empty"
    }
    try {
        $taskAccount = New-Object -TypeName System.Security.Principal.NTAccount `
            -ArgumentList $taskUserId
        $taskUserSid = $taskAccount.Translate(
            [System.Security.Principal.SecurityIdentifier]
        ).Value
    } catch {
        throw "${expectedTaskName} principal UserId cannot be resolved: $taskUserId"
    }
    if ($taskUserSid -ne $expectedTaskUserSid) {
        throw "${expectedTaskName} principal UserId does not match the installer user"
    }
    if ([string]$Task.Principal.RunLevel -ne 'Limited') {
        throw "${expectedTaskName} must use Limited run level"
    }
    Assert-LegacyOrNoTaskTriggers -Task $Task -Context $expectedTaskName `
        -AllowLegacyLogonTrigger:$AllowLegacyLogonTrigger
}

function Assert-ExpectedScheduledTask {
    param(
        [Parameter(Mandatory = $true)]
        $Task,

        [switch]$RequireRunning,

        [switch]$RequireReady,

        [switch]$RequireDisabled
    )

    if (@($RequireRunning, $RequireReady, $RequireDisabled).Where({ $_ }).Count -gt 1) {
        throw 'Scheduled-task validation cannot require multiple states together'
    }

    Assert-UpdatableScheduledTask -Task $Task -RequireRunning:$RequireRunning

    if ($RequireRunning -and $Task.State -ne 'Running') {
        throw "${expectedTaskName} must be running"
    }
    if ($RequireReady -and $Task.State -ne 'Ready') {
        throw "${expectedTaskName} must be ready after registration"
    }
    if ($RequireDisabled -and $Task.State -ne 'Disabled') {
        throw "${expectedTaskName} must be disabled during artifact replacement"
    }

    $actions = @($Task.Actions)
    $actionExecutable = (
        [Environment]::ExpandEnvironmentVariables([string]$actions[0].Execute)
    ).Trim('"')
    try {
        $actionExecutable = [System.IO.Path]::GetFullPath($actionExecutable)
    } catch {
        throw "${expectedTaskName} action executable is not an absolute path"
    }
    if (-not [System.IO.Path]::IsPathRooted([string]$actions[0].Execute) -or
        -not $actionExecutable.Equals(
            $expectedPowerShell,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "${expectedTaskName} must use exact Windows PowerShell path $expectedPowerShell"
    }
    if (-not [string]::IsNullOrWhiteSpace($expectedOperationId)) {
        Assert-TaskActionArguments -Arguments ([string]$actions[0].Arguments) `
            -Context "${expectedTaskName} current action" `
            -RequireCurrentReadinessBinding
    }

    if ([string]$Task.Settings.MultipleInstances -ne 'IgnoreNew') {
        throw "${expectedTaskName} must use MultipleInstances=IgnoreNew"
    }
    if ($Task.Settings.Enabled -isnot [bool]) {
        throw "${expectedTaskName} Enabled must be a Boolean"
    }
    if ($RequireDisabled) {
        if ([bool]$Task.Settings.Enabled) {
            throw "${expectedTaskName} must be disabled during artifact replacement"
        }
    } elseif (-not [bool]$Task.Settings.Enabled) {
        throw "${expectedTaskName} must be enabled"
    }
    if ($null -eq $Task.Settings.DisallowStartIfOnBatteries -or
        [Convert]::ToBoolean($Task.Settings.DisallowStartIfOnBatteries)) {
        throw "${expectedTaskName} must allow start on battery power"
    }
    if ($null -eq $Task.Settings.StopIfGoingOnBatteries -or
        [Convert]::ToBoolean($Task.Settings.StopIfGoingOnBatteries)) {
        throw "${expectedTaskName} must not stop when switching to battery power"
    }
    $executionTimeLimit = [string]$Task.Settings.ExecutionTimeLimit
    if ($executionTimeLimit -ne 'PT0S' -and
        $executionTimeLimit -ne [TimeSpan]::Zero.ToString()) {
        throw "${expectedTaskName} must have an unlimited execution time"
    }
    if ($null -eq $Task.Settings.RestartCount -or
        [int]$Task.Settings.RestartCount -ne 0) {
        throw "${expectedTaskName} Task Scheduler restart policy must be disabled"
    }
    if ($null -eq $Task.Settings.AllowHardTerminate -or
        -not [Convert]::ToBoolean($Task.Settings.AllowHardTerminate)) {
        throw "${expectedTaskName} must allow Task Scheduler to terminate it"
    }
}

function Assert-LegacyOrNoTaskXmlTriggers {
    param(
        [Parameter(Mandatory = $true)]$Document,
        [Parameter(Mandatory = $true)]$Namespace,
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$AllowLegacyLogonTrigger
    )

    $containers = @($Document.SelectNodes('/t:Task/t:Triggers', $Namespace))
    if ($containers.Count -ne 1) {
        throw "$Context must contain exactly one Triggers container"
    }
    $triggers = @($containers[0].SelectNodes('*'))
    if ($triggers.Count -eq 0) {
        return
    }
    if (-not $AllowLegacyLogonTrigger -or $triggers.Count -ne 1) {
        throw "$Context has an invalid automatic-trigger count"
    }
    $trigger = $triggers[0]
    if ($trigger.LocalName -cne 'LogonTrigger' -or
        $trigger.NamespaceURI -cne
            'http://schemas.microsoft.com/windows/2004/02/mit/task' -or
        $trigger.Attributes.Count -ne 0) {
        throw "$Context legacy trigger is not an exact LogonTrigger"
    }
    $children = @($trigger.SelectNodes('*'))
    $userNodes = @($trigger.SelectNodes('t:UserId', $Namespace))
    $enabledNodes = @($trigger.SelectNodes('t:Enabled', $Namespace))
    if ($userNodes.Count -ne 1 -or $enabledNodes.Count -gt 1 -or
        $children.Count -ne (1 + $enabledNodes.Count)) {
        throw "$Context legacy LogonTrigger has an unexpected child set"
    }
    foreach ($child in $children) {
        if ($child.Attributes.Count -ne 0 -or
            @($child.SelectNodes('*')).Count -ne 0) {
            throw "$Context legacy LogonTrigger child is malformed"
        }
    }
    if ($enabledNodes.Count -eq 1 -and
        [string]$enabledNodes[0].InnerText -cne 'true') {
        throw "$Context legacy LogonTrigger must be enabled"
    }
    if ((Resolve-LegacyLogonTriggerSid `
        -Account ([string]$userNodes[0].InnerText) `
        -Context "$Context legacy LogonTrigger") -cne $expectedTaskUserSid) {
        throw "$Context legacy LogonTrigger user does not match the installer user"
    }
}

function Assert-TaskXmlContract {
    param(
        [Parameter(Mandatory = $true)][string]$Xml,
        [switch]$RequireCurrentReadinessBinding,
        [switch]$AllowLegacyLogonTrigger
    )

    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = $null
    $stringReader = $null
    try {
        $stringReader = New-Object IO.StringReader($Xml)
        $reader = [Xml.XmlReader]::Create($stringReader, $settings)
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
    }
    $taskNamespace = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
    if ($document.DocumentElement.LocalName -cne 'Task' -or
        $document.DocumentElement.NamespaceURI -cne $taskNamespace) {
        throw 'Scheduled-task XML has an invalid root element'
    }
    $namespace = [Xml.XmlNamespaceManager]::new($document.NameTable)
    $namespace.AddNamespace('t', $taskNamespace)
    $uriNodes = @($document.SelectNodes(
        '/t:Task/t:RegistrationInfo/t:URI', $namespace
    ))
    if ($uriNodes.Count -ne 1 -or
        [string]$uriNodes[0].InnerText -cne $expectedTaskName) {
        throw 'Scheduled-task XML URI is invalid'
    }
    Assert-LegacyOrNoTaskXmlTriggers -Document $document `
        -Namespace $namespace -Context 'Scheduled-task XML' `
        -AllowLegacyLogonTrigger:$AllowLegacyLogonTrigger
    $actionsContainers = @($document.SelectNodes('/t:Task/t:Actions', $namespace))
    if ($actionsContainers.Count -ne 1) {
        throw 'Scheduled-task XML must contain exactly one Actions container'
    }
    $actionNodes = @($actionsContainers[0].SelectNodes('*'))
    if ($actionNodes.Count -ne 1 -or $actionNodes[0].LocalName -cne 'Exec') {
        throw 'Scheduled-task XML must contain exactly one Exec action'
    }
    $command = $actionNodes[0].SelectSingleNode('t:Command', $namespace)
    $arguments = $actionNodes[0].SelectSingleNode('t:Arguments', $namespace)
    $workingDirectory = $actionNodes[0].SelectSingleNode(
        't:WorkingDirectory', $namespace
    )
    if ($null -eq $command -or $null -eq $arguments -or
        $null -eq $workingDirectory) {
        throw 'Scheduled-task XML action is incomplete'
    }
    $commandPath = [IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables(
            ([string]$command.InnerText).Trim('"')
        )
    )
    if (-not $commandPath.Equals(
        $expectedPowerShell, [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Scheduled-task XML command path is invalid'
    }
    Assert-TaskActionArguments -Arguments ([string]$arguments.InnerText) `
        -Context 'Scheduled-task XML action' `
        -RequireCurrentReadinessBinding:$RequireCurrentReadinessBinding
    $workingPath = [IO.Path]::GetFullPath([string]$workingDirectory.InnerText)
    if (-not $workingPath.Equals(
        $installRoot, [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Scheduled-task XML working directory is invalid'
    }

    $principalNodes = @($document.SelectNodes(
        '/t:Task/t:Principals/t:Principal', $namespace
    ))
    if ($principalNodes.Count -ne 1) {
        throw 'Scheduled-task XML must contain exactly one principal'
    }
    $principalId = [string]$principalNodes[0].GetAttribute('id')
    if ([string]::IsNullOrWhiteSpace($principalId) -or
        [string]$actionsContainers[0].GetAttribute('Context') -cne $principalId) {
        throw 'Scheduled-task XML action context is invalid'
    }
    $userId = $principalNodes[0].SelectSingleNode('t:UserId', $namespace)
    $logonType = $principalNodes[0].SelectSingleNode('t:LogonType', $namespace)
    $runLevel = @($principalNodes[0].SelectNodes('t:RunLevel', $namespace))
    if ($null -eq $userId -or $null -eq $logonType -or $runLevel.Count -gt 1) {
        throw 'Scheduled-task XML principal is incomplete'
    }
    try {
        $principalSid = (New-Object Security.Principal.NTAccount `
            -ArgumentList ([string]$userId.InnerText)).Translate(
                [Security.Principal.SecurityIdentifier]
            ).Value
    } catch {
        $principalSid = [string]$userId.InnerText
    }
    if ($principalSid -cne $expectedTaskUserSid -or
        [string]$logonType.InnerText -cne 'InteractiveToken' -or
        ($runLevel.Count -eq 1 -and [string]$runLevel[0].InnerText -cne 'LeastPrivilege')) {
        throw 'Scheduled-task XML principal is invalid'
    }

    $settingsNode = $document.SelectSingleNode('/t:Task/t:Settings', $namespace)
    if ($null -eq $settingsNode) {
        throw 'Scheduled-task XML settings are missing'
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
            throw "Scheduled-task XML setting is invalid: $settingName"
        }
    }
    foreach ($optionalTrueSetting in @('AllowHardTerminate', 'Enabled')) {
        $optionalNodes = @($settingsNode.SelectNodes(
            "t:$optionalTrueSetting", $namespace
        ))
        if ($optionalNodes.Count -gt 1 -or
            ($optionalNodes.Count -eq 1 -and
                [string]$optionalNodes[0].InnerText -cne 'true')) {
            throw "Scheduled-task XML setting is invalid: $optionalTrueSetting"
        }
    }
    if ($null -ne $settingsNode.SelectSingleNode('t:RestartOnFailure', $namespace)) {
        throw 'Scheduled-task XML must not contain RestartOnFailure'
    }
}

function Register-ExpectedScheduledTask {
    param(
        [Parameter(Mandatory = $true)]
        $PreviousTask,

        [Parameter(Mandatory = $true)][string]$OperationId,

        [Parameter(Mandatory = $true)][string]$ReadinessReceiptPath,

        [Parameter(Mandatory = $true)][string]$ReadinessLockPath,

        [Parameter(Mandatory = $true)][string]$ReadinessCommitRequestPath,

        [Parameter(Mandatory = $true)][string]$InstallSuccessReceiptPath
    )

    $actionArguments = (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
        '-WindowStyle Hidden -File "{0}" ' +
        '-ReadinessReceiptPath "{1}" -ReadinessLockPath "{2}" ' +
        '-ReadinessCommitRequestPath "{3}" ' +
        '-InstallSuccessReceiptPath "{4}" -OperationId "{5}"'
    ) -f @(
        $installedScript,
        [IO.Path]::GetFullPath($ReadinessReceiptPath),
        [IO.Path]::GetFullPath($ReadinessLockPath),
        [IO.Path]::GetFullPath($ReadinessCommitRequestPath),
        [IO.Path]::GetFullPath($InstallSuccessReceiptPath),
        $OperationId
    )
    $action = New-ScheduledTaskAction `
        -Execute $expectedPowerShell `
        -Argument $actionArguments `
        -WorkingDirectory $installRoot
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([string]$PreviousTask.Principal.UserId) `
        -LogonType Interactive `
        -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -Disable `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 0

    $registration = @{
        TaskPath = $taskPath
        TaskName = $taskName
        Action = $action
        Principal = $principal
        Settings = $settings
        Force = $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$PreviousTask.Description)) {
        $registration.Description = [string]$PreviousTask.Description
    }

    Register-ScheduledTask @registration | Out-Null
    $registered = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Assert-ExpectedScheduledTask -Task $registered -RequireDisabled
}

function Move-ConsumedEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    $stem = [IO.Path]::GetFileNameWithoutExtension($fullPath)
    $extension = [IO.Path]::GetExtension($fullPath)
    $consumed = Join-Path $parent (
        '{0}.consumed.{1}{2}' -f $stem, $OperationId, $extension
    )
    $parentLease = Open-SafeDirectoryLease -Path $parent `
        -Name 'Consumed evidence parent'
    try {
    if (Test-Path -LiteralPath $consumed) {
        throw "Operation-scoped consumed evidence already exists: $consumed"
    }
    Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
        -Name 'Consumed evidence parent'
    [IO.File]::Move($fullPath, $consumed)
    $consumed
    } finally {
        $parentLease.Handle.Dispose()
    }
}

function Replace-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $destinationFullPath = [IO.Path]::GetFullPath($Destination)
    $parent = [IO.Path]::GetDirectoryName($destinationFullPath)
    $leaf = [IO.Path]::GetFileName($destinationFullPath)
    $temporary = Join-Path $parent (
        '.{0}.{1}.install.tmp' -f $leaf, [Guid]::NewGuid().ToString('N')
    )
    $backup = Join-Path $parent (
        '.{0}.{1}.install.bak' -f $leaf, [Guid]::NewGuid().ToString('N')
    )
    $parentLease = Open-SafeDirectoryLease -Path $parent `
        -Name "$Name destination parent"
    try {
        Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
            -Name "$Name destination parent"
        if (Test-Path -LiteralPath $destinationFullPath) {
            Assert-RegularNonReparseFile -Path $destinationFullPath `
                -Name "$Name destination"
            if ((Get-FileSha256Lower -Path $destinationFullPath) -ceq
                $ExpectedSha256) {
                Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
                    -Name "$Name destination parent"
                return
            }
        }
        Copy-Item -LiteralPath $Source -Destination $temporary
        Assert-RegularNonReparseFile -Path $temporary -Name "$Name staged file"
        if ((Get-FileSha256Lower -Path $temporary) -cne $ExpectedSha256) {
            throw "$Name staged SHA256 mismatch"
        }
        Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
            -Name "$Name destination parent"
        if (Test-Path -LiteralPath $destinationFullPath) {
            Assert-RegularNonReparseFile -Path $destinationFullPath `
                -Name "$Name destination"
            if ((Get-FileSha256Lower -Path $destinationFullPath) -ceq
                $ExpectedSha256) {
                Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
                    -Name "$Name destination parent"
                return
            }
            if (Test-Path -LiteralPath $backup) {
                throw "$Name atomic replacement backup already exists: $backup"
            }
            Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
                -Name "$Name destination parent"
            # Windows PowerShell 5.1/.NET Framework rejects a null backup path
            # for File.Replace.  A fresh same-directory backup keeps NTFS Replace
            # atomic while leaving the previous bytes recoverable on failure.
            [IO.File]::Replace($temporary, $destinationFullPath, $backup, $true)
            Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
                -Name "$Name destination parent"
            Assert-RegularNonReparseFile -Path $backup `
                -Name "$Name atomic replacement backup"
            [IO.File]::Delete($backup)
            if (Test-Path -LiteralPath $backup) {
                throw "$Name atomic replacement backup cleanup failed: $backup"
            }
        } else {
            [IO.File]::Move($temporary, $destinationFullPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        $parentLease.Handle.Dispose()
    }
    if ((Get-FileSha256Lower -Path $destinationFullPath) -cne $ExpectedSha256) {
        throw "$Name installed SHA256 mismatch"
    }
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

function Get-ViewflowProcessIdentity {
    param([Parameter(Mandatory = $true)]$Process)

    Assert-ExpectedViewflowProcess -Process $Process
    $processId = [int]$Process.ProcessId
    $startFileTime = Get-ProcessStartFileTimeString -ProcessId $processId
    $ownerSid = Get-ProcessOwnerSid -Process $Process
    if ($ownerSid -cne $expectedTaskUserSid) {
        throw 'Viewflow process owner SID is invalid'
    }
    $fresh = @(Get-CimInstance Win32_Process -Filter "ProcessId = $processId")
    if ($fresh.Count -ne 1) {
        throw 'Viewflow process identity disappeared while it was captured'
    }
    Assert-ExpectedViewflowProcess -Process $fresh[0]
    $freshStartFileTime = Get-ProcessStartFileTimeString -ProcessId $processId
    $freshOwnerSid = Get-ProcessOwnerSid -Process $fresh[0]
    if ($freshStartFileTime -cne $startFileTime -or
        $freshOwnerSid -cne $ownerSid -or
        [long]$fresh[0].SessionId -ne [long]$Process.SessionId -or
        -not ([IO.Path]::GetFullPath([string]$fresh[0].ExecutablePath)).Equals(
            [IO.Path]::GetFullPath([string]$Process.ExecutablePath),
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$fresh[0].CommandLine -cne [string]$Process.CommandLine) {
        throw 'Viewflow process identity changed while it was captured'
    }
    [pscustomobject]@{
        Process = $fresh[0]
        ProcessId = [long]$processId
        ProcessStartFileTime = $startFileTime
        SessionId = [long]$fresh[0].SessionId
        OwnerSid = $ownerSid
        ExecutablePath = [IO.Path]::GetFullPath([string]$fresh[0].ExecutablePath)
        CommandLine = [string]$fresh[0].CommandLine
    }
}

function Assert-ViewflowProcessIdentityCurrent {
    param([Parameter(Mandatory = $true)]$Identity)

    $processId = [int]$Identity.ProcessId
    $current = @(Get-CimInstance Win32_Process -Filter "ProcessId = $processId")
    if ($current.Count -ne 1) {
        throw 'The stable Viewflow process no longer exists'
    }
    Assert-ExpectedViewflowProcess -Process $current[0]
    $currentStartFileTime = Get-ProcessStartFileTimeString -ProcessId $processId
    $currentOwnerSid = Get-ProcessOwnerSid -Process $current[0]
    if ($currentStartFileTime -cne [string]$Identity.ProcessStartFileTime -or
        $currentOwnerSid -cne [string]$Identity.OwnerSid -or
        [long]$current[0].SessionId -ne [long]$Identity.SessionId -or
        -not ([IO.Path]::GetFullPath([string]$current[0].ExecutablePath)).Equals(
            [string]$Identity.ExecutablePath,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        [string]$current[0].CommandLine -cne [string]$Identity.CommandLine) {
        throw 'The stable Viewflow process identity changed'
    }
    $current[0]
}

function New-RandomLowerHex {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 1024)]
        [int]$ByteCount
    )

    $random = New-Object byte[] $ByteCount
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($random)
    } finally {
        $generator.Dispose()
    }
    ([BitConverter]::ToString($random) -replace '-', '').ToLowerInvariant()
}

function New-RollbackAuthorization {
    param(
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$RollbackMode,
        [Parameter(Mandatory = $true)][string]$TokenPath
    )
    if (@('bootstrap-v1.3', 'normal-v2') -cnotcontains $RollbackMode) {
        throw 'Rollback authorization mode is invalid'
    }
    $nonce = New-RandomLowerHex -ByteCount 32
    $createdAt = [DateTimeOffset]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $token = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-rollback-authorized'
        rollback_mode = $RollbackMode
        operation_id = $OperationId
        user_sid = $expectedTaskUserSid
        nonce = $nonce
        created_at_utc = $createdAt
    }
    Write-OwnerOnlyCreateOnceJson -Path $TokenPath -Value $token
    [pscustomobject]@{
        Sha256 = Get-FileSha256Lower -Path $TokenPath
        CreatedAtUtc = $createdAt
        Nonce = $nonce
    }
}

function Write-RollbackManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RollbackMode,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$CandidateSha256,
        [Parameter(Mandatory = $true)][string]$NewWrapperSha256,
        [Parameter(Mandatory = $true)][string]$BackupBinaryPath,
        [Parameter(Mandatory = $true)][string]$BackupBinarySha256,
        [Parameter(Mandatory = $true)][string]$BackupWrapperPath,
        [Parameter(Mandatory = $true)][string]$BackupWrapperSha256,
        [Parameter(Mandatory = $true)][string]$BackupTaskXmlPath,
        [Parameter(Mandatory = $true)][string]$BackupTaskXmlSha256,
        [Parameter(Mandatory = $true)][string]$TokenPath,
        [Parameter(Mandatory = $true)][string]$TokenSha256,
        [Parameter(Mandatory = $true)][string]$RollbackNonce,
        [Parameter(Mandatory = $true)][string]$ForceReleaseToolPath,
        [Parameter(Mandatory = $true)][string]$ForceReleaseToolSha256,
        [Parameter(Mandatory = $true)][string]$RecoveryBundlePath,
        [string]$LinuxDeactivationProofPath,
        [string]$LinuxDeactivationTranscriptPath,
        [string]$RuntimeReceiptPath,
        [string]$DaemonExitEvidencePath,
        [string]$DaemonExitObservationPath,
        [Parameter(Mandatory = $true)][string]$RecoveryForceReleaseReceiptPath
    )
    if (@('bootstrap-v1.3', 'normal-v2') -cnotcontains $RollbackMode) {
        throw 'Rollback manifest mode is invalid'
    }
    $manifest = [ordered]@{
        schema_version = 2
        state = 'viewflow-windows-rollback-armed'
        rollback_mode = $RollbackMode
        operation_id = $OperationId
        rollback_nonce = $RollbackNonce
        user_sid = $expectedTaskUserSid
        task_name = $expectedTaskName
        installed = [ordered]@{
            binary_path = $expectedExecutable
            binary_sha256 = $CandidateSha256
            wrapper_path = [IO.Path]::GetFullPath($installedScript)
            wrapper_sha256 = $NewWrapperSha256
        }
        backup = [ordered]@{
            binary_path = [IO.Path]::GetFullPath($BackupBinaryPath)
            binary_sha256 = $BackupBinarySha256
            wrapper_path = [IO.Path]::GetFullPath($BackupWrapperPath)
            wrapper_sha256 = $BackupWrapperSha256
            task_xml_path = [IO.Path]::GetFullPath($BackupTaskXmlPath)
            task_xml_sha256 = $BackupTaskXmlSha256
        }
        candidate_sha256 = $CandidateSha256
        token_path = [IO.Path]::GetFullPath($TokenPath)
        token_sha256 = $TokenSha256
        force_release_tool = [ordered]@{
            path = [IO.Path]::GetFullPath($ForceReleaseToolPath)
            sha256 = $ForceReleaseToolSha256
        }
        recovery_bundle_path = [IO.Path]::GetFullPath($RecoveryBundlePath)
    }
    if ($RollbackMode -ceq 'bootstrap-v1.3') {
        if ([string]::IsNullOrWhiteSpace($LinuxDeactivationProofPath) -or
            [string]::IsNullOrWhiteSpace($LinuxDeactivationTranscriptPath) -or
            -not [string]::IsNullOrWhiteSpace($RuntimeReceiptPath) -or
            -not [string]::IsNullOrWhiteSpace($DaemonExitEvidencePath) -or
            -not [string]::IsNullOrWhiteSpace($DaemonExitObservationPath)) {
            throw 'Bootstrap rollback manifest requires only proof and transcript evidence paths'
        }
        $manifest['expected_deactivation_evidence_type'] =
            'schema_version=3;state=viewflow-linux-deactivated'
        $manifest['linux_deactivation_proof_path'] =
            [IO.Path]::GetFullPath($LinuxDeactivationProofPath)
        $manifest['linux_deactivation_transcript_path'] =
            [IO.Path]::GetFullPath($LinuxDeactivationTranscriptPath)
    } else {
        if ([string]::IsNullOrWhiteSpace($RuntimeReceiptPath) -or
            [string]::IsNullOrWhiteSpace($DaemonExitEvidencePath) -or
            [string]::IsNullOrWhiteSpace($DaemonExitObservationPath) -or
            -not [string]::IsNullOrWhiteSpace($LinuxDeactivationProofPath) -or
            -not [string]::IsNullOrWhiteSpace($LinuxDeactivationTranscriptPath)) {
            throw ('Normal rollback manifest requires only runtime receipt, ' +
                'compact daemon-exit evidence, and raw observation paths')
        }
        $manifest['expected_deactivation_evidence_type'] =
            'schema_version=4;state=viewflow-input-quiesced;' +
                'schema_version=1;state=viewflow-daemon-exited;' +
                'schema_version=1;state=viewflow-daemon-exit-observation'
        $manifest['runtime_receipt_path'] =
            [IO.Path]::GetFullPath($RuntimeReceiptPath)
        $manifest['daemon_exit_evidence_path'] =
            [IO.Path]::GetFullPath($DaemonExitEvidencePath)
        $manifest['daemon_exit_observation_path'] =
            [IO.Path]::GetFullPath($DaemonExitObservationPath)
    }
    $manifest['recovery_force_release_receipt_path'] =
        [IO.Path]::GetFullPath($RecoveryForceReleaseReceiptPath)
    $manifest['created_at_utc'] = [DateTimeOffset]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    Write-OwnerOnlyCreateOnceJson -Path $Path -Value $manifest
}

function Write-BootstrapRecoveryPreparedReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$BootstrapRequestSha256,
        [Parameter(Mandatory = $true)][string]$MarkerHandoffReceiptPath,
        [Parameter(Mandatory = $true)][string]$MarkerHandoffReceiptSha256,
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$CandidateSha256,
        [Parameter(Mandatory = $true)][string]$WrapperSourcePath,
        [Parameter(Mandatory = $true)][string]$WrapperSha256,
        [Parameter(Mandatory = $true)][string]$RollbackScriptPath,
        [Parameter(Mandatory = $true)][string]$RollbackScriptSha256,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ManifestSha256,
        [Parameter(Mandatory = $true)][string]$TokenPath,
        [Parameter(Mandatory = $true)][string]$TokenSha256,
        [Parameter(Mandatory = $true)][string]$OldTaskXmlBackupPath,
        [Parameter(Mandatory = $true)][string]$OldTaskXmlSha256,
        [Parameter(Mandatory = $true)][string]$OldBinarySha256,
        [Parameter(Mandatory = $true)]$OldProcessIdentity,
        [Parameter(Mandatory = $true)][string]$ForceReleaseReceiptPath,
        [Parameter(Mandatory = $true)][string]$ReadinessReceiptPath,
        [Parameter(Mandatory = $true)][string]$ReadinessLockPath,
        [Parameter(Mandatory = $true)][string]$ReadinessCommitRequestPath,
        [Parameter(Mandatory = $true)][string]$InstallSuccessReceiptPath,
        [Parameter(Mandatory = $true)][string]$RecoveryBundlePath,
        [Parameter(Mandatory = $true)][string]$LinuxDeactivationProofPath,
        [Parameter(Mandatory = $true)][string]$LinuxDeactivationTranscriptPath,
        [Parameter(Mandatory = $true)][string]$RecoveryForceReleaseReceiptPath,
        [Parameter(Mandatory = $true)][string]$MutationPermitPath,
        [Parameter(Mandatory = $true)][string]$ForceReleaseEnvelopePath,
        [Parameter(Mandatory = $true)][string]$LinuxStageReceiptPath,
        [Parameter(Mandatory = $true)][string]$InstallerExitReceiptPath
    )

    if ($OperationId -cnotmatch '^[A-Za-z0-9_-]{16,128}$') {
        throw 'Bootstrap recovery operation_id is invalid'
    }
    foreach ($hashBinding in @(
        @{ Value = $LinuxEvidenceSha256; Name = 'Linux evidence SHA-256' },
        @{ Value = $BootstrapRequestSha256; Name = 'Bootstrap request SHA-256' },
        @{ Value = $MarkerHandoffReceiptSha256; Name = 'Marker handoff SHA-256' },
        @{ Value = $CandidateSha256; Name = 'Candidate SHA-256' },
        @{ Value = $WrapperSha256; Name = 'Wrapper SHA-256' },
        @{ Value = $RollbackScriptSha256; Name = 'Rollback script SHA-256' },
        @{ Value = $ManifestSha256; Name = 'Rollback manifest SHA-256' },
        @{ Value = $TokenSha256; Name = 'Rollback token SHA-256' },
        @{ Value = $OldTaskXmlSha256; Name = 'Old task XML SHA-256' },
        @{ Value = $OldBinarySha256; Name = 'Old executable SHA-256' }
    )) {
        Assert-LowerSha256 -Value $hashBinding.Value -Name $hashBinding.Name
    }
    if (-not (Test-JsonInteger -Value $OldProcessIdentity.ProcessId) -or
        [long]$OldProcessIdentity.ProcessId -le 0 -or
        $OldProcessIdentity.ProcessStartFileTime -isnot [string] -or
        $OldProcessIdentity.ProcessStartFileTime -cnotmatch '^[1-9][0-9]{0,19}$' -or
        -not (Test-JsonInteger -Value $OldProcessIdentity.SessionId) -or
        [long]$OldProcessIdentity.SessionId -ne 1 -or
        $OldProcessIdentity.OwnerSid -isnot [string] -or
        [string]$OldProcessIdentity.OwnerSid -cne $expectedTaskUserSid) {
        throw 'Bootstrap recovery old process identity is invalid'
    }

    $outputs = [ordered]@{
        mutation_permit_path = [IO.Path]::GetFullPath($MutationPermitPath)
        force_release_receipt_path = [IO.Path]::GetFullPath(
            $ForceReleaseReceiptPath
        )
        force_release_envelope_path = [IO.Path]::GetFullPath(
            $ForceReleaseEnvelopePath
        )
        linux_stage_receipt_path = [IO.Path]::GetFullPath($LinuxStageReceiptPath)
        readiness_receipt_path = [IO.Path]::GetFullPath($ReadinessReceiptPath)
        readiness_lock_path = [IO.Path]::GetFullPath($ReadinessLockPath)
        readiness_commit_request_path = [IO.Path]::GetFullPath(
            $ReadinessCommitRequestPath
        )
        install_success_receipt_path = [IO.Path]::GetFullPath(
            $InstallSuccessReceiptPath
        )
        recovery_bundle_path = [IO.Path]::GetFullPath($RecoveryBundlePath)
        linux_deactivation_proof_path = [IO.Path]::GetFullPath(
            $LinuxDeactivationProofPath
        )
        linux_deactivation_transcript_path = [IO.Path]::GetFullPath(
            $LinuxDeactivationTranscriptPath
        )
        recovery_force_release_receipt_path = [IO.Path]::GetFullPath(
            $RecoveryForceReleaseReceiptPath
        )
        installer_exit_receipt_path = [IO.Path]::GetFullPath(
            $InstallerExitReceiptPath
        )
    }
    $preparedAt = [DateTimeOffset]::UtcNow.ToString(
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $receipt = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-recovery-armed'
        rollback_mode = 'bootstrap-v1.3'
        operation_id = $OperationId
        user_sid = $expectedTaskUserSid
        bootstrap_request_sha256 = $BootstrapRequestSha256
        marker_handoff_receipt = [ordered]@{
            path = [IO.Path]::GetFullPath($MarkerHandoffReceiptPath)
            sha256 = $MarkerHandoffReceiptSha256
        }
        linux_frozen_evidence_sha256 = $LinuxEvidenceSha256
        candidate = [ordered]@{
            path = [IO.Path]::GetFullPath($CandidatePath)
            sha256 = $CandidateSha256
        }
        wrapper = [ordered]@{
            source_path = [IO.Path]::GetFullPath($WrapperSourcePath)
            installed_path = [IO.Path]::GetFullPath($installedScript)
            sha256 = $WrapperSha256
        }
        rollback_script = [ordered]@{
            path = [IO.Path]::GetFullPath($RollbackScriptPath)
            sha256 = $RollbackScriptSha256
        }
        rollback_authorization = [ordered]@{
            manifest_path = [IO.Path]::GetFullPath($ManifestPath)
            manifest_sha256 = $ManifestSha256
            token_path = [IO.Path]::GetFullPath($TokenPath)
            token_sha256 = $TokenSha256
        }
        old_task = [ordered]@{
            name = $expectedTaskName
            state = 'Running'
            xml_backup_path = [IO.Path]::GetFullPath($OldTaskXmlBackupPath)
            xml_sha256 = $OldTaskXmlSha256
        }
        old_executable = [ordered]@{
            path = [IO.Path]::GetFullPath($installedBinary)
            sha256 = $OldBinarySha256
            process_id = [long]$OldProcessIdentity.ProcessId
            process_start_filetime = [string]$OldProcessIdentity.ProcessStartFileTime
            session_id = [long]$OldProcessIdentity.SessionId
            owner_sid = [string]$OldProcessIdentity.OwnerSid
        }
        outputs = $outputs
        prepared_at_utc = $preparedAt
    }
    Write-OwnerOnlyCreateOnceJson -Path $Path -Value $receipt
    Assert-OwnerOnlyFileSecurity -Path $Path `
        -Name 'Bootstrap recovery prepared receipt'
    [pscustomobject]@{
        Sha256 = Get-FileSha256Lower -Path $Path
        PreparedAtUtc = $preparedAt
    }
}

function Wait-BootstrapMutationPermit {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$CoordinatorInstanceId,
        [Parameter(Mandatory = $true)][string]$BootstrapRequestSha256,
        [Parameter(Mandatory = $true)][string]$MarkerHandoffSha256,
        [Parameter(Mandatory = $true)][string]$PreparedReceiptSha256,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$CandidateSha256,
        [Parameter(Mandatory = $true)][string]$WrapperSha256,
        [Parameter(Mandatory = $true)][string]$RollbackScriptSha256,
        [Parameter(Mandatory = $true)][string]$ManifestSha256,
        [Parameter(Mandatory = $true)][string]$TokenSha256
    )
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        Assert-PinnedBootstrapRequestCurrent
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $permitRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $Path `
                -Name 'Bootstrap mutation permit'
            $permit = $permitRead.Value
            Assert-ExactPropertySet -Value $permit `
                -Context 'Bootstrap mutation permit' -Names @(
                    'schema_version', 'state', 'operation_id', 'user_sid',
                    'coordinator_instance_id', 'permit_nonce',
                    'bootstrap_request_sha256',
                    'marker_handoff_receipt_sha256',
                    'windows_prepared_receipt_sha256',
                    'linux_frozen_evidence_sha256', 'candidate_sha256',
                    'wrapper_sha256', 'rollback_script_sha256',
                    'rollback_manifest_sha256', 'rollback_token_sha256',
                    'linux_viewflowd_sha256',
                    'linux_deployment_marker_sha256',
                    'linux_viewflow_unit_sha256',
                    'issued_at_utc'
                )
            if ($permit.schema_version -isnot [int] -or
                $permit.schema_version -ne 1 -or
                $permit.state -isnot [string] -or
                $permit.state -cne
                    'viewflow-windows-bootstrap-mutation-permitted' -or
                $permit.operation_id -isnot [string] -or
                $permit.operation_id -cne $OperationId -or
                $permit.user_sid -isnot [string] -or
                $permit.user_sid -cne $expectedTaskUserSid -or
                $permit.coordinator_instance_id -isnot [string] -or
                $permit.coordinator_instance_id -cne $CoordinatorInstanceId -or
                $permit.permit_nonce -isnot [string] -or
                $permit.permit_nonce -cnotmatch '^[0-9a-f]{64}$') {
                throw 'Bootstrap mutation permit schema, operation, or user is invalid'
            }
            foreach ($binding in @(
                @{ Name = 'bootstrap_request_sha256'; Expected = $BootstrapRequestSha256 },
                @{ Name = 'marker_handoff_receipt_sha256'; Expected = $MarkerHandoffSha256 },
                @{ Name = 'windows_prepared_receipt_sha256'; Expected = $PreparedReceiptSha256 },
                @{ Name = 'linux_frozen_evidence_sha256'; Expected = $LinuxEvidenceSha256 },
                @{ Name = 'candidate_sha256'; Expected = $CandidateSha256 },
                @{ Name = 'wrapper_sha256'; Expected = $WrapperSha256 },
                @{ Name = 'rollback_script_sha256'; Expected = $RollbackScriptSha256 },
                @{ Name = 'rollback_manifest_sha256'; Expected = $ManifestSha256 },
                @{ Name = 'rollback_token_sha256'; Expected = $TokenSha256 }
            )) {
                $actual = $permit.PSObject.Properties[$binding.Name].Value
                Assert-LowerSha256 -Value $actual `
                    -Name "Bootstrap mutation permit $($binding.Name)"
                if ([string]$actual -cne [string]$binding.Expected) {
                    throw "Bootstrap mutation permit hash is invalid: $($binding.Name)"
                }
            }
            foreach ($linuxHashName in @(
                'linux_viewflowd_sha256', 'linux_deployment_marker_sha256',
                'linux_viewflow_unit_sha256'
            )) {
                Assert-LowerSha256 `
                    -Value $permit.PSObject.Properties[$linuxHashName].Value `
                    -Name "Bootstrap mutation permit $linuxHashName"
            }
            Assert-FreshUtcTimestamp -Value $permit.issued_at_utc `
                -Name 'Bootstrap mutation permit issued_at_utc'
            return [pscustomobject]@{
                Receipt = $permit
                Sha256 = [string]$permitRead.Sha256
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($wait.Elapsed.TotalSeconds -lt 300)
    throw 'Bootstrap mutation permit was not published within 300 seconds'
}

function Write-BootstrapForceReleaseEnvelope {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$BootstrapRequestSha256,
        [Parameter(Mandatory = $true)][string]$MarkerHandoffSha256,
        [Parameter(Mandatory = $true)][string]$PreparedReceiptSha256,
        [Parameter(Mandatory = $true)][string]$MutationPermitSha256,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [Parameter(Mandatory = $true)][string]$RawForceReceiptPath,
        [Parameter(Mandatory = $true)][string]$RawForceReceiptSha256
    )
    foreach ($binding in @(
        @{ Value = $BootstrapRequestSha256; Name = 'Bootstrap request SHA-256' },
        @{ Value = $MarkerHandoffSha256; Name = 'Marker handoff SHA-256' },
        @{ Value = $PreparedReceiptSha256; Name = 'Prepared receipt SHA-256' },
        @{ Value = $MutationPermitSha256; Name = 'Mutation permit SHA-256' },
        @{ Value = $LinuxEvidenceSha256; Name = 'Linux evidence SHA-256' },
        @{ Value = $RawForceReceiptSha256; Name = 'Raw force-release SHA-256' }
    )) {
        Assert-LowerSha256 -Value $binding.Value -Name $binding.Name
    }
    $envelope = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-force-release-attested'
        operation_id = $OperationId
        user_sid = $expectedTaskUserSid
        bootstrap_request_sha256 = $BootstrapRequestSha256
        marker_handoff_receipt_sha256 = $MarkerHandoffSha256
        windows_prepared_receipt_sha256 = $PreparedReceiptSha256
        mutation_permit_sha256 = $MutationPermitSha256
        linux_frozen_evidence_sha256 = $LinuxEvidenceSha256
        raw_force_release_receipt_path = [IO.Path]::GetFullPath(
            $RawForceReceiptPath
        )
        raw_force_release_receipt_sha256 = $RawForceReceiptSha256
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    Write-OwnerOnlyCreateOnceJson -Path $Path -Value $envelope
    Assert-OwnerOnlyFileSecurity -Path $Path `
        -Name 'Bootstrap force-release envelope'
    [pscustomobject]@{
        Receipt = $envelope
        Sha256 = Get-FileSha256Lower -Path $Path
    }
}

function Write-ReadinessCommitRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [AllowNull()]$ForceReceiptSha256,
        [AllowNull()]$MarkerHandoffReceiptSha256,
        [AllowNull()]$WindowsPreparedReceiptSha256,
        [AllowNull()]$MutationPermitSha256,
        [AllowNull()]$LinuxStageReceiptSha256,
        [AllowNull()]$BootstrapRequestSha256,
        [Parameter(Mandatory = $true)][string]$OldBinarySha256,
        [Parameter(Mandatory = $true)][string]$NewBinarySha256,
        [Parameter(Mandatory = $true)][string]$WrapperSha256,
        [Parameter(Mandatory = $true)][string]$TaskXmlSha256,
        [Parameter(Mandatory = $true)]$ProcessIdentity,
        [Parameter(Mandatory = $true)]$Readiness,
        [Parameter(Mandatory = $true)][string]$ReadinessReceiptPath,
        [Parameter(Mandatory = $true)][string]$ReadinessLockPath,
        [Parameter(Mandatory = $true)][ref]$RequestPublished
    )

    if (@('bootstrap-v1.3', 'normal-v2') -cnotcontains $Mode) {
        throw 'Readiness commit request mode is invalid'
    }
    foreach ($hashBinding in @(
        @{ Value = $LinuxEvidenceSha256; Name = 'Linux evidence SHA-256' },
        @{ Value = $OldBinarySha256; Name = 'Old executable SHA-256' },
        @{ Value = $NewBinarySha256; Name = 'New executable SHA-256' },
        @{ Value = $WrapperSha256; Name = 'Installed wrapper SHA-256' },
        @{ Value = $TaskXmlSha256; Name = 'Scheduled-task XML SHA-256' },
        @{ Value = $Readiness.ReceiptSha256; Name = 'Readiness receipt SHA-256' },
        @{ Value = $Readiness.LockSha256; Name = 'Readiness lock SHA-256' }
    )) {
        Assert-LowerSha256 -Value $hashBinding.Value -Name $hashBinding.Name
    }
    $bootstrapOnlyHashes = @(
        $ForceReceiptSha256, $MarkerHandoffReceiptSha256,
        $WindowsPreparedReceiptSha256, $MutationPermitSha256,
        $LinuxStageReceiptSha256, $BootstrapRequestSha256
    )
    if ($Mode -ceq 'bootstrap-v1.3') {
        $bootstrapHashSeen = @{}
        foreach ($bootstrapHash in $bootstrapOnlyHashes) {
            Assert-LowerSha256 -Value $bootstrapHash `
                -Name 'Bootstrap commit-chain SHA-256'
            if ($bootstrapHashSeen.ContainsKey([string]$bootstrapHash)) {
                throw 'Bootstrap commit-chain SHA-256 values must be pairwise distinct'
            }
            $bootstrapHashSeen[[string]$bootstrapHash] = $true
        }
    } else {
        $nonNullBootstrapOnlyHashes = @(
            $bootstrapOnlyHashes | Where-Object { $null -ne $_ }
        )
        if ($nonNullBootstrapOnlyHashes.Count -ne 0) {
            throw 'Normal readiness commit request must use null bootstrap hashes'
        }
    }

    $null = Assert-ViewflowProcessIdentityCurrent -Identity $ProcessIdentity
    if ([string]$ProcessIdentity.OwnerSid -cne $expectedTaskUserSid) {
        throw 'Started Viewflow process owner SID is invalid'
    }
    $commitNonce = New-RandomLowerHex -ByteCount 16
    $request = [ordered]@{
        schema_version = 5
        state = 'viewflow-install-commit-request'
        mode = $Mode
        operation_id = $OperationId
        commit_nonce = $commitNonce
        daemon_pid = [long]$ProcessIdentity.ProcessId
        daemon_process_start_filetime =
            [string]$ProcessIdentity.ProcessStartFileTime
        connection_generation = [long]$Readiness.ConnectionGeneration
        readiness_receipt_sha256 = [string]$Readiness.ReceiptSha256
        readiness_lock_sha256 = [string]$Readiness.LockSha256
        linux_frozen_evidence_sha256 = $LinuxEvidenceSha256
        force_release_receipt_sha256 = $ForceReceiptSha256
        marker_handoff_receipt_sha256 = $MarkerHandoffReceiptSha256
        windows_prepared_receipt_sha256 = $WindowsPreparedReceiptSha256
        mutation_permit_sha256 = $MutationPermitSha256
        linux_stage_receipt_sha256 = $LinuxStageReceiptSha256
        bootstrap_request_sha256 = $BootstrapRequestSha256
        old_viewflow_executable_sha256 = $OldBinarySha256
        new_viewflow_executable_sha256 = $NewBinarySha256
        installed_wrapper_sha256 = $WrapperSha256
        scheduled_task_xml_sha256 = $TaskXmlSha256
        requested_at_utc = [DateTimeOffset]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    $json = ($request | ConvertTo-Json -Depth 12) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $requestSha256 = Get-BytesSha256Lower -Value $bytes
    Assert-NewAbsoluteOutputPath -Path $Path `
        -Name 'Readiness commit request path'
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $leaf = [IO.Path]::GetFileName([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $parent (
        '.{0}.{1}.commit-request.tmp' -f @(
            $leaf, [Guid]::NewGuid().ToString('N')
        )
    )
    $stream = $null
    $parentLease = Open-SafeDirectoryLease -Path $parent `
        -Name 'Readiness commit request parent'
    try {
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough,
            (New-OwnerOnlyFileSecurity)
        )
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        Assert-AuthenticatedReadinessCommitBoundary -Readiness $Readiness `
            -ReceiptPath $ReadinessReceiptPath -LockPath $ReadinessLockPath `
            -ProcessIdentity $ProcessIdentity `
            -ExpectedTaskXmlSha256 $TaskXmlSha256
        Assert-SafeDirectoryLeaseCurrent -Lease $parentLease `
            -Name 'Readiness commit request parent'
        [IO.File]::Move($temporary, $Path)
        $RequestPublished.Value = $true
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
        $parentLease.Handle.Dispose()
    }
    [pscustomobject]@{
        Mode = $Mode
        Nonce = $commitNonce
        Sha256 = $requestSha256
    }
}

function Assert-DaemonInstallSuccessReceipt {
    param(
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)]$CommitRequest,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [AllowNull()]$ForceReceiptSha256,
        [AllowNull()]$MarkerHandoffReceiptSha256,
        [AllowNull()]$WindowsPreparedReceiptSha256,
        [AllowNull()]$MutationPermitSha256,
        [AllowNull()]$LinuxStageReceiptSha256,
        [AllowNull()]$BootstrapRequestSha256,
        [Parameter(Mandatory = $true)][string]$OldBinarySha256,
        [Parameter(Mandatory = $true)][string]$NewBinarySha256,
        [Parameter(Mandatory = $true)][string]$WrapperSha256,
        [Parameter(Mandatory = $true)][string]$TaskXmlSha256,
        [Parameter(Mandatory = $true)]$ProcessIdentity,
        [Parameter(Mandatory = $true)]$Readiness
    )

    Assert-ExactPropertySet -Value $Receipt `
        -Context 'Daemon-authored install-success receipt' -Names @(
            'schema_version', 'state', 'operation_id', 'commit_nonce',
            'commit_request_sha256', 'commit_mode', 'committed_by_daemon',
            'linux_frozen_evidence_sha256', 'force_release_receipt_sha256',
            'marker_handoff_receipt_sha256',
            'windows_prepared_receipt_sha256', 'mutation_permit_sha256',
            'linux_stage_receipt_sha256', 'bootstrap_request_sha256',
            'readiness_receipt_sha256', 'readiness_lock_sha256',
            'readiness_connection_generation', 'readiness_established_at_utc',
            'old_viewflow_executable_sha256',
            'new_viewflow_executable_sha256', 'installed_wrapper_sha256',
            'scheduled_task_xml_sha256', 'new_process_pid',
            'new_process_start_filetime', 'new_process_session_id',
            'new_process_user_sid', 'protocol_version', 'peer', 'device_id',
            'completed_at_utc', 'committed_at_utc'
        )
    if ($Receipt.schema_version -isnot [int] -or
        $Receipt.schema_version -ne 5 -or
        $Receipt.state -isnot [string] -or
        $Receipt.state -cne 'viewflow-v2-windows-installed' -or
        $Receipt.operation_id -isnot [string] -or
        $Receipt.operation_id -cne $OperationId -or
        $Receipt.commit_nonce -isnot [string] -or
        $Receipt.commit_nonce -cne [string]$CommitRequest.Nonce -or
        $Receipt.commit_request_sha256 -isnot [string] -or
        $Receipt.commit_request_sha256 -cne [string]$CommitRequest.Sha256 -or
        $Receipt.commit_mode -isnot [string] -or
        $Receipt.commit_mode -cne [string]$CommitRequest.Mode -or
        $Receipt.committed_by_daemon -isnot [bool] -or
        -not [bool]$Receipt.committed_by_daemon) {
        throw 'Daemon-authored install-success commit binding is invalid'
    }
    $hashBindings = @(
        @{ Value = $Receipt.commit_request_sha256; Expected = $CommitRequest.Sha256; Name = 'commit_request_sha256' },
        @{ Value = $Receipt.linux_frozen_evidence_sha256; Expected = $LinuxEvidenceSha256; Name = 'linux_frozen_evidence_sha256' },
        @{ Value = $Receipt.readiness_receipt_sha256; Expected = $Readiness.ReceiptSha256; Name = 'readiness_receipt_sha256' },
        @{ Value = $Receipt.readiness_lock_sha256; Expected = $Readiness.LockSha256; Name = 'readiness_lock_sha256' },
        @{ Value = $Receipt.old_viewflow_executable_sha256; Expected = $OldBinarySha256; Name = 'old_viewflow_executable_sha256' },
        @{ Value = $Receipt.new_viewflow_executable_sha256; Expected = $NewBinarySha256; Name = 'new_viewflow_executable_sha256' },
        @{ Value = $Receipt.installed_wrapper_sha256; Expected = $WrapperSha256; Name = 'installed_wrapper_sha256' },
        @{ Value = $Receipt.scheduled_task_xml_sha256; Expected = $TaskXmlSha256; Name = 'scheduled_task_xml_sha256' }
    )
    foreach ($binding in $hashBindings) {
        Assert-LowerSha256 -Value $binding.Value `
            -Name "Daemon install-success $($binding.Name)"
        if ([string]$binding.Value -cne [string]$binding.Expected) {
            throw "Daemon install-success hash binding is invalid: $($binding.Name)"
        }
    }
    $receiptBootstrapBindings = @(
        @{ Name = 'force_release_receipt_sha256'; Expected = $ForceReceiptSha256 },
        @{ Name = 'marker_handoff_receipt_sha256'; Expected = $MarkerHandoffReceiptSha256 },
        @{ Name = 'windows_prepared_receipt_sha256'; Expected = $WindowsPreparedReceiptSha256 },
        @{ Name = 'mutation_permit_sha256'; Expected = $MutationPermitSha256 },
        @{ Name = 'linux_stage_receipt_sha256'; Expected = $LinuxStageReceiptSha256 },
        @{ Name = 'bootstrap_request_sha256'; Expected = $BootstrapRequestSha256 }
    )
    if ([string]$CommitRequest.Mode -ceq 'normal-v2') {
        foreach ($binding in $receiptBootstrapBindings) {
            if ($null -ne $Receipt.PSObject.Properties[$binding.Name].Value -or
                $null -ne $binding.Expected) {
                throw 'Normal install-success receipt must use null bootstrap hashes'
            }
        }
    } else {
        $receiptBootstrapSeen = @{}
        foreach ($binding in $receiptBootstrapBindings) {
            $value = $Receipt.PSObject.Properties[$binding.Name].Value
            Assert-LowerSha256 -Value $value `
                -Name "Daemon install-success $($binding.Name)"
            if ([string]$value -cne [string]$binding.Expected) {
                throw "Bootstrap install-success hash is invalid: $($binding.Name)"
            }
            if ($receiptBootstrapSeen.ContainsKey([string]$value)) {
                throw 'Bootstrap install-success hashes must be pairwise distinct'
            }
            $receiptBootstrapSeen[[string]$value] = $true
        }
    }
    if (-not (Test-JsonInteger -Value $Receipt.readiness_connection_generation) -or
        [long]$Receipt.readiness_connection_generation -ne
            [long]$Readiness.ConnectionGeneration -or
        $Receipt.readiness_established_at_utc -isnot [string] -or
        $Receipt.readiness_established_at_utc -cne
            [string]$Readiness.EstablishedAtUtc -or
        -not (Test-JsonInteger -Value $Receipt.new_process_pid) -or
        [long]$Receipt.new_process_pid -ne [long]$ProcessIdentity.ProcessId -or
        $Receipt.new_process_start_filetime -isnot [string] -or
        $Receipt.new_process_start_filetime -cne
            [string]$ProcessIdentity.ProcessStartFileTime -or
        -not (Test-JsonInteger -Value $Receipt.new_process_session_id) -or
        [long]$Receipt.new_process_session_id -ne
            [long]$ProcessIdentity.SessionId -or
        $Receipt.new_process_user_sid -isnot [string] -or
        $Receipt.new_process_user_sid -cne [string]$ProcessIdentity.OwnerSid -or
        $Receipt.protocol_version -isnot [string] -or
        $Receipt.protocol_version -cne '2.1' -or
        $Receipt.peer -isnot [string] -or $Receipt.peer -cne $expectedPeer -or
        $Receipt.device_id -isnot [string] -or
        $Receipt.device_id -cne $expectedDeviceId) {
        throw 'Daemon-authored install-success live readiness identity is invalid'
    }
    Assert-FreshUtcTimestamp -Value $Receipt.readiness_established_at_utc `
        -Name 'Daemon install-success readiness_established_at_utc'
    Assert-FreshUtcTimestamp -Value $Receipt.completed_at_utc `
        -Name 'Daemon install-success completed_at_utc'
    Assert-FreshUtcTimestamp -Value $Receipt.committed_at_utc `
        -Name 'Daemon install-success committed_at_utc'
    if ([string]$Receipt.completed_at_utc -cne
        [string]$Receipt.committed_at_utc) {
        throw 'Daemon install-success completion and commit timestamps differ'
    }
    $null = Assert-ViewflowProcessIdentityCurrent -Identity $ProcessIdentity
}

function Wait-DaemonInstallSuccessReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$CommitRequest,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$LinuxEvidenceSha256,
        [AllowNull()][string]$ForceReceiptSha256,
        [AllowNull()][string]$MarkerHandoffReceiptSha256,
        [AllowNull()][string]$WindowsPreparedReceiptSha256,
        [AllowNull()][string]$MutationPermitSha256,
        [AllowNull()][string]$LinuxStageReceiptSha256,
        [AllowNull()][string]$BootstrapRequestSha256,
        [Parameter(Mandatory = $true)][string]$OldBinarySha256,
        [Parameter(Mandatory = $true)][string]$NewBinarySha256,
        [Parameter(Mandatory = $true)][string]$WrapperSha256,
        [Parameter(Mandatory = $true)][string]$TaskXmlSha256,
        [Parameter(Mandatory = $true)]$ProcessIdentity,
        [Parameter(Mandatory = $true)]$Readiness,
        [Parameter(Mandatory = $true)][string]$ReadinessReceiptPath,
        [Parameter(Mandatory = $true)][string]$ReadinessLockPath,
        [Parameter(Mandatory = $true)][ref]$InstallCommitted
    )

    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            # Existence is the daemon's irreversible commit linearization. Do
            # not automatically roll back even if strict validation below fails.
            $InstallCommitted.Value = $true
            $receiptRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $Path `
                -Name 'Daemon-authored install-success receipt'
            Assert-DaemonInstallSuccessReceipt -Receipt $receiptRead.Value `
                -CommitRequest $CommitRequest -OperationId $OperationId `
                -LinuxEvidenceSha256 $LinuxEvidenceSha256 `
                -ForceReceiptSha256 $ForceReceiptSha256 `
                -MarkerHandoffReceiptSha256 $MarkerHandoffReceiptSha256 `
                -WindowsPreparedReceiptSha256 $WindowsPreparedReceiptSha256 `
                -MutationPermitSha256 $MutationPermitSha256 `
                -LinuxStageReceiptSha256 $LinuxStageReceiptSha256 `
                -BootstrapRequestSha256 $BootstrapRequestSha256 `
                -OldBinarySha256 $OldBinarySha256 `
                -NewBinarySha256 $NewBinarySha256 `
                -WrapperSha256 $WrapperSha256 -TaskXmlSha256 $TaskXmlSha256 `
                -ProcessIdentity $ProcessIdentity -Readiness $Readiness
            return [pscustomobject]@{
                Receipt = $receiptRead.Value
                Sha256 = [string]$receiptRead.Sha256
            }
        }
        Assert-AuthenticatedReadinessCommitBoundary -Readiness $Readiness `
            -ReceiptPath $ReadinessReceiptPath -LockPath $ReadinessLockPath `
            -ProcessIdentity $ProcessIdentity `
            -ExpectedTaskXmlSha256 $TaskXmlSha256
        Start-Sleep -Milliseconds 50
    } while ($wait.Elapsed.TotalSeconds -lt $commitWaitSeconds)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $InstallCommitted.Value = $true
        return Wait-DaemonInstallSuccessReceipt @PSBoundParameters
    }
    throw "The daemon did not publish install success within $commitWaitSeconds seconds"
}

function Assert-QuiescedMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$InstalledSha256,

        [Parameter(Mandatory = $true)]
        [string]$InstalledWrapperSha256,

        [Parameter(Mandatory = $true)]
        [string]$CandidateSha256,

        [switch]$AllowBootstrap
    )

    function Test-JsonInteger {
        param($Value)
        $Value -is [int] -or $Value -is [long]
    }

    function Assert-FreshUnixMilliseconds {
        param(
            [Parameter(Mandatory = $true)]
            $Value,

            [Parameter(Mandatory = $true)]
            [string]$Name
        )
        if (-not (Test-JsonInteger -Value $Value) -or [long]$Value -le 0) {
            throw "Quiesced marker $Name must be a positive JSON integer"
        }
        try {
            $timestamp = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$Value)
        } catch {
            throw "Quiesced marker $Name is invalid"
        }
        $age = [DateTimeOffset]::UtcNow - $timestamp
        if ($age.TotalSeconds -lt -30 -or
            $age.TotalSeconds -gt $QuiescedMarkerMaxAgeSeconds) {
            throw "Quiesced marker $Name is stale or from the future"
        }
    }

    function Assert-ArtifactHash {
        param(
            [Parameter(Mandatory = $true)]
            $ArtifactHashes,

            [Parameter(Mandatory = $true)]
            [string]$Name,

            [string]$Expected
        )
        $property = $ArtifactHashes.PSObject.Properties[$Name]
        if ($null -eq $property -or
            $property.Value -isnot [string] -or
            [string]$property.Value -cnotmatch '^[0-9a-f]{64}$') {
            throw "Quiesced marker artifact hash is absent or invalid: $Name"
        }
        if (-not [string]::IsNullOrWhiteSpace($Expected) -and
            [string]$property.Value -ine $Expected) {
            throw "Quiesced marker artifact hash does not match: $Name"
        }
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Quiesced marker does not exist: $Path"
    }
    $markerRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $Path `
        -Name 'Quiesced marker'
    $marker = $markerRead.Value
    if ($marker -isnot [pscustomobject]) {
        throw 'Quiesced marker must be a JSON object'
    }
    if ($AllowBootstrap) {
        $validatedBootstrap = Assert-V13BootstrapEvidence -Marker $marker
        return [pscustomobject]@{
            Kind = 'BootstrapV13'
            OperationId = [string]$validatedBootstrap.operation_id
            Marker = $validatedBootstrap
            Sha256 = [string]$markerRead.Sha256
        }
    }
    Assert-ExactPropertySet -Value $marker -Context 'Quiesced marker' -Names @(
        'schema_version', 'state', 'operation_id', 'task_name', 'peer',
        'device_id', 'protocol_version', 'daemon_instance_id', 'local_device',
        'target_device', 'daemon_sha256', 'daemon_pid', 'daemon_start_ticks',
        'boot_id', 'cleanup', 'route_status', 'peer_disconnect_status',
        'daemon_exit_evidence', 'artifact_hashes', 'completed_at_unix_ms',
        'created_utc'
    )
    if ($marker.schema_version -isnot [int] -or
        $marker.schema_version -ne 4 -or
        $marker.state -isnot [string] -or
        $marker.state -cne 'viewflow-input-quiesced') {
        throw 'Quiesced marker schema or state is invalid'
    }
    foreach ($legacyField in @(
        'release_all_applied',
        'route_revoked',
        'peer_disconnected',
        'confirmation_source'
    )) {
        if ($null -ne $marker.PSObject.Properties[$legacyField]) {
            throw "Quiesced marker contains forbidden legacy assertion: $legacyField"
        }
    }
    if ($marker.task_name -isnot [string] -or
        $marker.task_name -cne $expectedTaskName) {
        throw 'Quiesced marker task name does not match the installed task'
    }
    if ($marker.peer -isnot [string] -or
        $marker.peer -cne $expectedPeer -or
        $marker.device_id -isnot [string] -or
        $marker.device_id -cne $expectedDeviceId) {
        throw 'Quiesced marker peer or device identity is invalid'
    }
    if ($marker.operation_id -isnot [string] -or
        $marker.operation_id -cnotmatch '^[A-Za-z0-9_-]{16,128}$') {
        throw 'Quiesced marker operation_id is invalid'
    }
    if (-not (Test-JsonInteger -Value $marker.daemon_pid) -or
        [long]$marker.daemon_pid -le 0 -or
        -not (Test-JsonInteger -Value $marker.daemon_start_ticks) -or
        [long]$marker.daemon_start_ticks -le 0 -or
        $marker.boot_id -isnot [string] -or
        $marker.boot_id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'Quiesced marker daemon identity is invalid'
    }
    $expectedDaemonInstanceId = '{0}-{1}-{2}' -f @(
        $marker.boot_id,
        [long]$marker.daemon_pid,
        [long]$marker.daemon_start_ticks
    )
    if ($marker.daemon_instance_id -isnot [string] -or
        $marker.daemon_instance_id -cne $expectedDaemonInstanceId -or
        $marker.daemon_sha256 -isnot [string] -or
        $marker.daemon_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Quiesced marker daemon instance binding is invalid'
    }
    if ($marker.protocol_version -isnot [string] -or
        $marker.protocol_version -cne '2.1' -or
        $marker.local_device -isnot [string] -or
        $marker.local_device -cne $expectedLocalDeviceId -or
        $marker.target_device -isnot [string] -or
        $marker.target_device -cne $expectedDeviceId) {
        throw 'Quiesced marker protocol or endpoint identity is invalid'
    }
    if ($marker.route_status -isnot [string] -or
        $marker.route_status -cne 'removed' -or
        $marker.peer_disconnect_status -isnot [string] -or
        $marker.peer_disconnect_status -cne 'confirmed_by_daemon_exit') {
        throw 'Quiesced marker route or peer-disconnect status is invalid'
    }

    $cleanup = $marker.cleanup
    Assert-ExactPropertySet -Value $cleanup -Context 'Quiesced marker cleanup' -Names @(
        'route_ever_activated', 'route_was_active', 'active_lease_generation',
        'last_input_sequence', 'release_all', 'lease_revoke',
        'bound_peer_epoch', 'bound_peer_socket', 'source_display', 'route_generation'
    )
    Assert-ExactPropertySet -Value $cleanup.release_all `
        -Context 'Quiesced marker release_all' -Names @('status', 'ack')
    Assert-ExactPropertySet -Value $cleanup.lease_revoke `
        -Context 'Quiesced marker lease_revoke' -Names @('status', 'generation', 'ack')
    if ($cleanup.route_ever_activated -isnot [bool] -or
        $cleanup.route_was_active -isnot [bool] -or
        $cleanup.release_all -isnot [pscustomobject] -or
        $cleanup.lease_revoke -isnot [pscustomobject]) {
        throw 'Quiesced marker cleanup evidence is invalid'
    }
    if ($cleanup.route_was_active -eq $false) {
        if ($cleanup.route_ever_activated -ne $false -or
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
            throw 'Quiesced marker inactive-route cleanup evidence is inconsistent'
        }
    } else {
        $ack = $cleanup.release_all.ack
        $revokeAck = $cleanup.lease_revoke.ack
        Assert-ExactPropertySet -Value $ack `
            -Context 'Quiesced marker ReleaseAll Applied ACK' -Names @(
                'lease_generation', 'target_device', 'event_sequence', 'result'
            )
        Assert-ExactPropertySet -Value $revokeAck `
            -Context 'Quiesced marker LeaseRevoke Applied ACK' -Names @(
                'operation_id', 'lease_generation', 'owner_device',
                'target_device', 'state', 'result'
            )
        $socketMatch = [regex]::Match(
            [string]$cleanup.bound_peer_socket,
            '^172\.16\.105\.70:(?<port>[0-9]{1,5})$'
        )
        if ($cleanup.route_ever_activated -ne $true -or
            $cleanup.source_display -isnot [string] -or
            $cleanup.source_display -cne $expectedSourceDisplayId -or
            -not (Test-JsonInteger -Value $cleanup.route_generation) -or
            [long]$cleanup.route_generation -le 0 -or
            [long]$cleanup.route_generation -gt $maximumJsonInteger -or
            -not (Test-JsonInteger -Value $cleanup.active_lease_generation) -or
            [long]$cleanup.active_lease_generation -le 0 -or
            [long]$cleanup.active_lease_generation -eq [long]::MaxValue -or
            -not (Test-JsonInteger -Value $cleanup.last_input_sequence) -or
            [long]$cleanup.last_input_sequence -lt 0 -or
            [long]$cleanup.last_input_sequence -eq [long]::MaxValue -or
            -not (Test-JsonInteger -Value $cleanup.bound_peer_epoch) -or
            [long]$cleanup.bound_peer_epoch -le 0 -or
            $cleanup.bound_peer_socket -isnot [string] -or
            -not $socketMatch.Success -or
            [int]$socketMatch.Groups['port'].Value -lt 1 -or
            [int]$socketMatch.Groups['port'].Value -gt 65535 -or
            $cleanup.release_all.status -isnot [string] -or
            $cleanup.release_all.status -cne 'applied' -or
            $ack -isnot [pscustomobject] -or
            $ack.result -isnot [string] -or
            $ack.result -cne 'applied' -or
            -not (Test-JsonInteger -Value $ack.lease_generation) -or
            [long]$ack.lease_generation -ne [long]$cleanup.active_lease_generation -or
            $ack.target_device -isnot [string] -or
            $ack.target_device -cne $expectedDeviceId -or
            -not (Test-JsonInteger -Value $ack.event_sequence) -or
            [long]$ack.event_sequence -ne ([long]$cleanup.last_input_sequence + 1) -or
            $cleanup.lease_revoke.status -isnot [string] -or
            $cleanup.lease_revoke.status -cne 'applied' -or
            -not (Test-JsonInteger -Value $cleanup.lease_revoke.generation) -or
            [long]$cleanup.lease_revoke.generation -ne
                ([long]$cleanup.active_lease_generation + 1) -or
            $revokeAck.operation_id -isnot [string] -or
            $revokeAck.operation_id -cnotmatch '^[0-9a-f]{32}$' -or
            $revokeAck.operation_id -ceq ('0' * 32) -or
            $revokeAck.operation_id.Substring(0, 16) -cne
                ('{0:x16}' -f [long]$cleanup.bound_peer_epoch) -or
            -not (Test-JsonInteger -Value $revokeAck.lease_generation) -or
            [long]$revokeAck.lease_generation -ne [long]$cleanup.lease_revoke.generation -or
            $revokeAck.owner_device -isnot [string] -or
            $revokeAck.owner_device -cne $expectedLocalDeviceId -or
            $revokeAck.target_device -isnot [string] -or
            $revokeAck.target_device -cne $expectedDeviceId -or
            $revokeAck.state -isnot [string] -or
            $revokeAck.state -cne 'revoked' -or
            $revokeAck.result -isnot [string] -or
            $revokeAck.result -cne 'applied') {
            throw 'Quiesced marker active-route cleanup evidence is inconsistent'
        }
    }

    $exitEvidence = $marker.daemon_exit_evidence
    if ($exitEvidence -isnot [pscustomobject] -or
        $exitEvidence.schema_version -isnot [int] -or
        $exitEvidence.schema_version -ne 1 -or
        $exitEvidence.state -isnot [string] -or
        $exitEvidence.state -cne 'viewflow-daemon-exited' -or
        $exitEvidence.operation_id -isnot [string] -or
        $exitEvidence.operation_id -cne $marker.operation_id -or
        -not (Test-JsonInteger -Value $exitEvidence.daemon_pid) -or
        [long]$exitEvidence.daemon_pid -ne [long]$marker.daemon_pid -or
        -not (Test-JsonInteger -Value $exitEvidence.daemon_start_ticks) -or
        [long]$exitEvidence.daemon_start_ticks -ne [long]$marker.daemon_start_ticks -or
        $exitEvidence.boot_id -isnot [string] -or
        $exitEvidence.boot_id -cne $marker.boot_id -or
        $exitEvidence.unit -isnot [string] -or
        $exitEvidence.unit -cne 'viewflow-peer.service' -or
        $exitEvidence.active_state -isnot [string] -or
        $exitEvidence.active_state -cne 'inactive' -or
        -not (Test-JsonInteger -Value $exitEvidence.main_pid) -or
        [long]$exitEvidence.main_pid -ne 0 -or
        -not (Test-JsonInteger -Value $exitEvidence.exact_process_count) -or
        [long]$exitEvidence.exact_process_count -ne 0 -or
        -not (Test-JsonInteger -Value $exitEvidence.udp_listener_count) -or
        [long]$exitEvidence.udp_listener_count -ne 0 -or
        $exitEvidence.sidecar_socket_present -isnot [bool] -or
        $exitEvidence.sidecar_socket_present -ne $false -or
        $exitEvidence.observation_sha256 -isnot [string] -or
        $exitEvidence.observation_sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Quiesced marker daemon-exit evidence is invalid or unbound'
    }

    Assert-FreshUnixMilliseconds -Value $marker.completed_at_unix_ms `
        -Name 'completed_at_unix_ms'
    Assert-FreshUnixMilliseconds -Value $exitEvidence.observed_at_unix_ms `
        -Name 'daemon_exit_evidence.observed_at_unix_ms'
    if ([long]$exitEvidence.observed_at_unix_ms -lt
        [long]$marker.completed_at_unix_ms) {
        throw 'Quiesced marker daemon-exit evidence predates daemon cleanup completion'
    }
    if ($marker.created_utc -isnot [string]) {
        throw 'Quiesced marker created_utc must be a string'
    }
    try {
        $createdUtc = [DateTimeOffset]::Parse(
            [string]$marker.created_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
    } catch {
        throw 'Quiesced marker created_utc is invalid'
    }
    $createdAge = [DateTimeOffset]::UtcNow - $createdUtc
    if ($createdAge.TotalSeconds -lt -30 -or
        $createdAge.TotalSeconds -gt $QuiescedMarkerMaxAgeSeconds) {
        throw 'Quiesced marker created_utc is stale or from the future'
    }

    if ($marker.artifact_hashes -isnot [pscustomobject]) {
        throw 'Quiesced marker artifact_hashes must be a JSON object'
    }
    $requiredArtifactHashes = @(
        'linux_viewflowd',
        'linux_peer_certificate',
        'linux_peer_private_key',
        'linux_certificate_authority',
        'windows_installed_viewflowd',
        'windows_candidate_viewflowd',
        'windows_client_wrapper',
        'windows_peer_certificate',
        'windows_peer_private_key',
        'windows_certificate_authority'
    )
    if (@($marker.artifact_hashes.PSObject.Properties).Count -ne
        $requiredArtifactHashes.Count) {
        throw 'Quiesced marker artifact_hashes has an unexpected field set'
    }
    foreach ($artifactName in $requiredArtifactHashes) {
        Assert-ArtifactHash -ArtifactHashes $marker.artifact_hashes -Name $artifactName
    }
    Assert-ArtifactHash -ArtifactHashes $marker.artifact_hashes `
        -Name 'linux_viewflowd' -Expected $marker.daemon_sha256
    Assert-ArtifactHash -ArtifactHashes $marker.artifact_hashes `
        -Name 'windows_installed_viewflowd' -Expected $InstalledSha256
    Assert-ArtifactHash -ArtifactHashes $marker.artifact_hashes `
        -Name 'windows_candidate_viewflowd' -Expected $CandidateSha256
    Assert-ArtifactHash -ArtifactHashes $marker.artifact_hashes `
        -Name 'windows_client_wrapper' -Expected $InstalledWrapperSha256
    $identityHashBindings = @{
        'windows_peer_certificate' = $expectedCert
        'windows_peer_private_key' = $expectedKey
        'windows_certificate_authority' = $expectedCa
    }
    foreach ($artifactName in $identityHashBindings.Keys) {
        $identityHash = (
            Get-FileHash -LiteralPath $identityHashBindings[$artifactName] `
                -Algorithm SHA256
        ).Hash
        Assert-ArtifactHash -ArtifactHashes $marker.artifact_hashes `
            -Name $artifactName -Expected $identityHash
    }
    [pscustomobject]@{
        Kind = 'NormalV2'
        OperationId = [string]$marker.operation_id
        Marker = $marker
        Sha256 = [string]$markerRead.Sha256
    }
}

foreach ($requiredFile in @($CandidatePath, $sourceScript, $sourceRollbackScript,
        $installedBinary, $installedScript)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required file does not exist: $requiredFile"
    }
}
if ($AllowV13Bootstrap -and
    [string]::IsNullOrWhiteSpace($BootstrapRequestPath)) {
    throw 'Bootstrap installation requires the pinned BootstrapRequestPath interface'
}

$candidateHash = Get-FileSha256Lower -Path $CandidatePath
$expectedCandidateHash = $ExpectedSha256.ToLowerInvariant()
if ($candidateHash -cne $expectedCandidateHash) {
    throw "Candidate SHA256 mismatch: expected $expectedCandidateHash, got $candidateHash"
}
$sourceScriptHash = Get-FileSha256Lower -Path $sourceScript
$sourceRollbackScriptHash = Get-FileSha256Lower -Path $sourceRollbackScript
$expectedSourceScriptHash = $ExpectedWrapperSha256.ToLowerInvariant()
if ($sourceScriptHash -cne $expectedSourceScriptHash) {
    throw "Reviewed wrapper SHA256 mismatch: expected $expectedSourceScriptHash, got $sourceScriptHash"
}

foreach ($readinessPath in @(
        $ReadinessReceiptPath,
        $ReadinessLockPath,
        $ReadinessCommitRequestPath,
        $InstallSuccessReceiptPath,
        $RollbackManifestPath,
        $RollbackTokenPath,
        $RecoveryBundlePath,
        $RecoveryForceReleaseReceiptPath
    )) {
    Assert-NewAbsoluteOutputPath -Path $readinessPath -Name 'Required output path'
}
$rollbackMode = if ($AllowV13Bootstrap) { 'bootstrap-v1.3' } else { 'normal-v2' }
$commonOutputPaths = @(
    $ReadinessReceiptPath,
    $ReadinessLockPath,
    $ReadinessCommitRequestPath,
    $InstallSuccessReceiptPath,
    $RollbackManifestPath,
    $RollbackTokenPath,
    $RecoveryBundlePath,
    $RecoveryForceReleaseReceiptPath
)

if ($AllowV13Bootstrap) {
    foreach ($bootstrapPath in @(
        $ForceReleaseReceiptPath,
        $LinuxDeactivationProofPath, $LinuxDeactivationTranscriptPath,
        $BootstrapRecoveryPreparedReceiptPath,
        $BootstrapMutationPermitPath,
        $BootstrapForceReleaseEnvelopePath,
        $LinuxStageReceiptPath,
        $BootstrapInstallerExitReceiptPath
    )) {
        Assert-NewAbsoluteOutputPath -Path $bootstrapPath `
            -Name 'Required bootstrap output path'
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeReceiptPath) -or
        -not [string]::IsNullOrWhiteSpace($DaemonExitEvidencePath) -or
        -not [string]::IsNullOrWhiteSpace($DaemonExitObservationPath)) {
        throw 'Normal daemon-exit evidence paths are forbidden for bootstrap install'
    }
    Assert-DistinctBootstrapOutputPaths -OutputPaths ($commonOutputPaths + @(
        $ForceReleaseReceiptPath,
        $LinuxDeactivationProofPath,
        $LinuxDeactivationTranscriptPath,
        $BootstrapRecoveryPreparedReceiptPath,
        $BootstrapMutationPermitPath,
        $BootstrapForceReleaseEnvelopePath,
        $LinuxStageReceiptPath,
        $BootstrapInstallerExitReceiptPath
    )) -ProtectedPaths @(
        $CandidatePath, $sourceScript, $sourceRollbackScript,
        $installedBinary, $installedScript, $installedRollbackScript,
        $QuiescedMarkerPath, $MarkerHandoffReceiptPath, $BootstrapRequestPath
    )
} else {
    if (-not [string]::IsNullOrWhiteSpace($ForceReleaseReceiptPath) -or
        -not [string]::IsNullOrWhiteSpace($LinuxDeactivationProofPath) -or
        -not [string]::IsNullOrWhiteSpace($LinuxDeactivationTranscriptPath) -or
        -not [string]::IsNullOrWhiteSpace(
            $BootstrapRecoveryPreparedReceiptPath
        ) -or
        -not [string]::IsNullOrWhiteSpace($MarkerHandoffReceiptPath) -or
        -not [string]::IsNullOrWhiteSpace($BootstrapMutationPermitPath) -or
        -not [string]::IsNullOrWhiteSpace($BootstrapForceReleaseEnvelopePath) -or
        -not [string]::IsNullOrWhiteSpace($LinuxStageReceiptPath) -or
        -not [string]::IsNullOrWhiteSpace($BootstrapInstallerExitReceiptPath)) {
        throw 'Bootstrap-only force-release and deactivation paths are forbidden for normal install'
    }
    foreach ($normalEvidencePath in @(
        $RuntimeReceiptPath,
        $DaemonExitEvidencePath,
        $DaemonExitObservationPath
    )) {
        if ([string]::IsNullOrWhiteSpace($normalEvidencePath) -or
            -not [IO.Path]::IsPathRooted($normalEvidencePath) -or
            -not (Test-Path -LiteralPath $normalEvidencePath -PathType Leaf)) {
            throw 'Normal rollback evidence paths must be existing absolute files'
        }
        $normalEvidenceItem = Get-Item -LiteralPath $normalEvidencePath -Force
        if (($normalEvidenceItem.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Normal rollback evidence paths must not be reparse points'
        }
        Assert-OwnerOnlyFileSecurity -Path $normalEvidencePath `
            -Name 'Normal rollback evidence'
    }
    Assert-DistinctBootstrapOutputPaths -OutputPaths $commonOutputPaths `
        -ProtectedPaths @(
            $CandidatePath, $sourceScript, $sourceRollbackScript,
            $installedBinary, $installedScript, $installedRollbackScript,
            $QuiescedMarkerPath, $RuntimeReceiptPath,
            $DaemonExitEvidencePath, $DaemonExitObservationPath
        )
    Assert-DistinctBootstrapOutputPaths -OutputPaths @(
        $RuntimeReceiptPath, $DaemonExitEvidencePath, $DaemonExitObservationPath
    ) -ProtectedPaths @(
        $CandidatePath, $sourceScript, $sourceRollbackScript,
        $installedBinary, $installedScript, $installedRollbackScript,
        $QuiescedMarkerPath
    )
}

Assert-ExpectedWrapperConfiguration -Path $sourceScript
Assert-ExpectedIdentityMaterial
$task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
Assert-UpdatableScheduledTask -Task $task -RequireRunning `
    -AllowLegacyLogonTrigger
$runningBefore = @(Get-ExactInstalledViewflowProcesses)
if ($runningBefore.Count -ne 1) {
    throw 'Exactly one installed Viewflow process must be running before update'
}
Assert-ExpectedViewflowProcess -Process $runningBefore[0]
$oldProcessIdentity = Get-ViewflowProcessIdentity -Process $runningBefore[0]

$oldBinaryHash = Get-FileSha256Lower -Path $installedBinary
$oldScriptHash = Get-FileSha256Lower -Path $installedScript
if ($AllowV13Bootstrap -and $oldBinaryHash -ceq $candidateHash) {
    throw 'Bootstrap candidate must differ from the installed protocol-1.3 binary'
}
$authorization = Assert-QuiescedMarker -Path $QuiescedMarkerPath `
    -InstalledSha256 $oldBinaryHash `
    -InstalledWrapperSha256 $oldScriptHash `
    -CandidateSha256 $candidateHash `
    -AllowBootstrap:$AllowV13Bootstrap
$operationId = [string]$authorization.OperationId
$expectedOperationId = $operationId
$linuxEvidenceSha256 = [string]$authorization.Sha256
$markerHandoffPinned = $null
if ($AllowV13Bootstrap) {
    if ([string]$bootstrapRequest.linux_frozen_evidence_sha256 -cne
        $linuxEvidenceSha256) {
        throw 'Pinned bootstrap request Linux frozen evidence hash is inconsistent'
    }
    $markerHandoffPinned = Open-PinnedReadinessReceiptSnapshot `
        -Path $MarkerHandoffReceiptPath -Name 'Marker handoff receipt'
    Assert-MarkerHandoffReceipt -Receipt $markerHandoffPinned.Value `
        -OperationId $operationId
    if ([string]$markerHandoffPinned.Sha256 -cne
        [string]$bootstrapRequest.marker_handoff_receipt_sha256) {
        throw 'Pinned marker handoff receipt hash differs from bootstrap request'
    }
    Assert-PinnedBootstrapRequestCurrent
}
$backupRoot = $null
$backupBinary = $null
$backupScript = $null
$backupTaskXml = $null
$backupRollbackScript = $null
$backupForceReleaseTool = $null
$oldTaskXml = $null
$oldTaskXmlHash = $null
$oldRollbackExisted = $false
$oldRollbackHash = $null
$rollbackPrepared = $false
$consumedEvidence = $null
$forceReceipt = $null
$running = $null
$readinessLease = $null
$authorizationConsumed = $false
$transactionMutated = $false
$installCommitted = $false
$commitRequestPublished = $false
$installSuccessReceipt = $null
$bootstrapRecoveryPrepared = $false
$bootstrapRecoveryPreparedReceipt = $null
$bootstrapMutationPermit = $null
$bootstrapMutationPermitted = $false
$bootstrapForceReleaseEnvelope = $null
$linuxStageReceipt = $null
$token = $null

# Establish every artifact needed for an inactive automatic rollback before the
# one-shot authorization is consumed or the live task is stopped.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $installRoot ("backup-{0}-{1}" -f @(
    $stamp, [Guid]::NewGuid().ToString('N').Substring(0, 8)
))
New-Item -ItemType Directory -Path $backupRoot | Out-Null
$backupBinary = Join-Path $backupRoot 'viewflowd.exe'
$backupScript = Join-Path $backupRoot 'viewflow-client.ps1'
$backupTaskXml = Join-Path $backupRoot 'Viewflow-Peer.xml'
$backupRollbackScript = Join-Path $backupRoot 'rollback-viewflow.ps1'
$backupForceReleaseTool = Join-Path $backupRoot 'force-release-viewflowd.exe'
Copy-Item -LiteralPath $installedBinary -Destination $backupBinary
Set-OwnerOnlyFileSecurity -Path $backupBinary -Name 'Prepared rollback backup binary'
Copy-Item -LiteralPath $installedScript -Destination $backupScript
Set-OwnerOnlyFileSecurity -Path $backupScript -Name 'Prepared rollback backup wrapper'
$oldRollbackExisted = Test-Path -LiteralPath $installedRollbackScript -PathType Leaf
if ($oldRollbackExisted) {
    Copy-Item -LiteralPath $installedRollbackScript -Destination $backupRollbackScript
    $oldRollbackHash = Get-FileSha256Lower -Path $backupRollbackScript
}
Copy-Item -LiteralPath $CandidatePath -Destination $backupForceReleaseTool
Set-OwnerOnlyFileSecurity -Path $backupForceReleaseTool `
    -Name 'Prepared rollback force-release tool'
if ((Get-FileSha256Lower -Path $backupBinary) -cne $oldBinaryHash -or
    (Get-FileSha256Lower -Path $backupScript) -cne $oldScriptHash -or
    (Get-FileSha256Lower -Path $backupForceReleaseTool) -cne $candidateHash) {
    throw 'Prepared rollback artifacts do not match their reviewed hashes'
}
$oldTaskXml = Export-ScheduledTask -TaskPath $taskPath -TaskName $taskName
Assert-TaskXmlContract -Xml $oldTaskXml -AllowLegacyLogonTrigger
$oldTaskXmlBytes = Get-Utf16TaskXmlBytes -Xml $oldTaskXml
Write-OwnerOnlyCreateOnceBytes -Path $backupTaskXml -Bytes $oldTaskXmlBytes
$oldTaskXmlHash = Get-FileSha256Lower -Path $backupTaskXml
if ($oldTaskXmlHash -cne (Get-BytesSha256Lower -Value $oldTaskXmlBytes)) {
    throw 'Prepared scheduled-task rollback XML hash is inconsistent'
}
$rollbackPrepared = $true

if ($AllowV13Bootstrap) {
    # Install and verify the reviewed standalone rollback implementation while
    # the old peer is still healthy. Token, manifest, and prepared receipt are
    # all create-once and owner-only; no stop, force-release, daemon/wrapper
    # replacement, task replacement, or start occurs before publication.
    Replace-FileAtomically -Source $sourceRollbackScript `
        -Destination $installedRollbackScript `
        -ExpectedSha256 $sourceRollbackScriptHash -Name 'Rollback tool'
    $installedRollbackItem = Get-Item -LiteralPath $installedRollbackScript -Force
    if (($installedRollbackItem.Attributes -band
        [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (Get-FileSha256Lower -Path $installedRollbackScript) -cne
            $sourceRollbackScriptHash) {
        throw 'Installed reviewed rollback tool is not a regular hash-bound file'
    }
    $token = New-RollbackAuthorization -OperationId $operationId `
        -RollbackMode $rollbackMode -TokenPath $RollbackTokenPath
    Write-RollbackManifest -Path $RollbackManifestPath `
        -RollbackMode $rollbackMode `
        -OperationId $operationId -CandidateSha256 $candidateHash `
        -NewWrapperSha256 $sourceScriptHash `
        -BackupBinaryPath $backupBinary -BackupBinarySha256 $oldBinaryHash `
        -BackupWrapperPath $backupScript -BackupWrapperSha256 $oldScriptHash `
        -BackupTaskXmlPath $backupTaskXml -BackupTaskXmlSha256 $oldTaskXmlHash `
        -TokenPath $RollbackTokenPath -TokenSha256 $token.Sha256 `
        -RollbackNonce $token.Nonce `
        -ForceReleaseToolPath $backupForceReleaseTool `
        -ForceReleaseToolSha256 $candidateHash `
        -RecoveryBundlePath $RecoveryBundlePath `
        -LinuxDeactivationProofPath $LinuxDeactivationProofPath `
        -LinuxDeactivationTranscriptPath $LinuxDeactivationTranscriptPath `
        -RecoveryForceReleaseReceiptPath $RecoveryForceReleaseReceiptPath
    $manifestRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $RollbackManifestPath `
        -Name 'Prepared rollback manifest'
    $tokenRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $RollbackTokenPath `
        -Name 'Prepared rollback token'
    if ([string]$manifestRead.Sha256 -cne
            (Get-FileSha256Lower -Path $RollbackManifestPath) -or
        [string]$tokenRead.Sha256 -cne $token.Sha256) {
        throw 'Prepared rollback authorization hashes changed before publication'
    }
    $null = Assert-ViewflowProcessIdentityCurrent -Identity $oldProcessIdentity
    $prePublishTask = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Assert-UpdatableScheduledTask -Task $prePublishTask -RequireRunning `
        -AllowLegacyLogonTrigger
    if ((Get-FileSha256Lower -Path $installedBinary) -cne $oldBinaryHash -or
        (Get-FileSha256Lower -Path $installedScript) -cne $oldScriptHash -or
        (Get-FileSha256Lower -Path $installedRollbackScript) -cne
            $sourceRollbackScriptHash) {
        throw 'Bootstrap recovery identities changed before prepared publication'
    }
    $bootstrapRecoveryPreparedReceipt =
        Write-BootstrapRecoveryPreparedReceipt `
            -Path $BootstrapRecoveryPreparedReceiptPath `
            -OperationId $operationId `
            -LinuxEvidenceSha256 $linuxEvidenceSha256 `
            -BootstrapRequestSha256 $bootstrapRequestSha256 `
            -MarkerHandoffReceiptPath $MarkerHandoffReceiptPath `
            -MarkerHandoffReceiptSha256 $markerHandoffPinned.Sha256 `
            -CandidatePath $CandidatePath -CandidateSha256 $candidateHash `
            -WrapperSourcePath $sourceScript -WrapperSha256 $sourceScriptHash `
            -RollbackScriptPath $installedRollbackScript `
            -RollbackScriptSha256 $sourceRollbackScriptHash `
            -ManifestPath $RollbackManifestPath `
            -ManifestSha256 ([string]$manifestRead.Sha256) `
            -TokenPath $RollbackTokenPath -TokenSha256 $token.Sha256 `
            -OldTaskXmlBackupPath $backupTaskXml `
            -OldTaskXmlSha256 $oldTaskXmlHash `
            -OldBinarySha256 $oldBinaryHash `
            -OldProcessIdentity $oldProcessIdentity `
            -ForceReleaseReceiptPath $ForceReleaseReceiptPath `
            -ReadinessReceiptPath $ReadinessReceiptPath `
            -ReadinessLockPath $ReadinessLockPath `
            -ReadinessCommitRequestPath $ReadinessCommitRequestPath `
            -InstallSuccessReceiptPath $InstallSuccessReceiptPath `
            -RecoveryBundlePath $RecoveryBundlePath `
            -LinuxDeactivationProofPath $LinuxDeactivationProofPath `
            -LinuxDeactivationTranscriptPath $LinuxDeactivationTranscriptPath `
            -RecoveryForceReleaseReceiptPath $RecoveryForceReleaseReceiptPath `
            -MutationPermitPath $BootstrapMutationPermitPath `
            -ForceReleaseEnvelopePath $BootstrapForceReleaseEnvelopePath `
            -LinuxStageReceiptPath $LinuxStageReceiptPath `
            -InstallerExitReceiptPath $BootstrapInstallerExitReceiptPath
    $bootstrapRecoveryPrepared = $true
    $bootstrapMutationPermit = Wait-BootstrapMutationPermit `
        -Path $BootstrapMutationPermitPath -OperationId $operationId `
        -CoordinatorInstanceId $markerHandoffPinned.Value.coordinator_instance_id `
        -BootstrapRequestSha256 $bootstrapRequestSha256 `
        -MarkerHandoffSha256 $markerHandoffPinned.Sha256 `
        -PreparedReceiptSha256 $bootstrapRecoveryPreparedReceipt.Sha256 `
        -LinuxEvidenceSha256 $linuxEvidenceSha256 `
        -CandidateSha256 $candidateHash -WrapperSha256 $sourceScriptHash `
        -RollbackScriptSha256 $sourceRollbackScriptHash `
        -ManifestSha256 $manifestRead.Sha256 -TokenSha256 $token.Sha256
    $bootstrapMutationPermitted = $true
    foreach ($preMutationBinding in @(
        @{ Path = $BootstrapRecoveryPreparedReceiptPath; Expected = $bootstrapRecoveryPreparedReceipt.Sha256; Name = 'prepared receipt' },
        @{ Path = $BootstrapMutationPermitPath; Expected = $bootstrapMutationPermit.Sha256; Name = 'mutation permit' }
    )) {
        $preMutationRead = Read-OwnerOnlyUtf8JsonSnapshot `
            -Path $preMutationBinding.Path `
            -Name "Bootstrap $($preMutationBinding.Name) pre-mutation revalidation"
        if ([string]$preMutationRead.Sha256 -cne
            [string]$preMutationBinding.Expected) {
            throw "Bootstrap $($preMutationBinding.Name) changed before mutation"
        }
    }
    Assert-PinnedBootstrapRequestCurrent
    $markerHandoffAgain = Read-Utf8JsonStreamSnapshot `
        -Stream $markerHandoffPinned.Stream `
        -Name 'Pinned marker handoff receipt revalidation'
    if ([string]$markerHandoffAgain.Sha256 -cne
        [string]$markerHandoffPinned.Sha256) {
        throw 'Pinned marker handoff receipt changed before mutation'
    }
}
try {
    # Same-directory File.Move is the one-shot authorization boundary. The
    # evidence is retained under an operation-scoped consumed name.
    $consumedEvidence = Move-ConsumedEvidence -Path $QuiescedMarkerPath `
        -OperationId $operationId
    $authorizationConsumed = $true
    $consumedAuthorization = Assert-QuiescedMarker -Path $consumedEvidence `
        -InstalledSha256 $oldBinaryHash `
        -InstalledWrapperSha256 $oldScriptHash `
        -CandidateSha256 $candidateHash `
        -AllowBootstrap:$AllowV13Bootstrap
    if ([string]$consumedAuthorization.OperationId -cne $operationId -or
        [string]$consumedAuthorization.Sha256 -cne $linuxEvidenceSha256) {
        throw 'Consumed evidence identity or SHA256 changed at the transaction boundary'
    }

    Stop-ViewflowTaskAndWait
    $transactionMutated = $true

    if (-not $AllowV13Bootstrap) {
        Replace-FileAtomically -Source $sourceRollbackScript `
            -Destination $installedRollbackScript `
            -ExpectedSha256 $sourceRollbackScriptHash -Name 'Rollback tool'
        $token = New-RollbackAuthorization -OperationId $operationId `
            -RollbackMode $rollbackMode -TokenPath $RollbackTokenPath
        Write-RollbackManifest -Path $RollbackManifestPath `
            -RollbackMode $rollbackMode `
            -OperationId $operationId -CandidateSha256 $candidateHash `
            -NewWrapperSha256 $sourceScriptHash `
            -BackupBinaryPath $backupBinary -BackupBinarySha256 $oldBinaryHash `
            -BackupWrapperPath $backupScript -BackupWrapperSha256 $oldScriptHash `
            -BackupTaskXmlPath $backupTaskXml `
            -BackupTaskXmlSha256 $oldTaskXmlHash `
            -TokenPath $RollbackTokenPath -TokenSha256 $token.Sha256 `
            -RollbackNonce $token.Nonce `
            -ForceReleaseToolPath $backupForceReleaseTool `
            -ForceReleaseToolSha256 $candidateHash `
            -RecoveryBundlePath $RecoveryBundlePath `
            -RuntimeReceiptPath $RuntimeReceiptPath `
            -DaemonExitEvidencePath $DaemonExitEvidencePath `
            -DaemonExitObservationPath $DaemonExitObservationPath `
            -RecoveryForceReleaseReceiptPath $RecoveryForceReleaseReceiptPath
    }
    if ($AllowV13Bootstrap) {
        $forceReceipt = Invoke-BootstrapForceRelease -Candidate $CandidatePath `
            -ReceiptPath $ForceReleaseReceiptPath -OperationId $operationId `
            -CandidateSha256 $candidateHash `
            -LinuxEvidenceSha256 $linuxEvidenceSha256
        $bootstrapForceReleaseEnvelope =
            Write-BootstrapForceReleaseEnvelope `
                -Path $BootstrapForceReleaseEnvelopePath `
                -OperationId $operationId `
                -BootstrapRequestSha256 $bootstrapRequestSha256 `
                -MarkerHandoffSha256 $markerHandoffPinned.Sha256 `
                -PreparedReceiptSha256 $bootstrapRecoveryPreparedReceipt.Sha256 `
                -MutationPermitSha256 $bootstrapMutationPermit.Sha256 `
                -LinuxEvidenceSha256 $linuxEvidenceSha256 `
                -RawForceReceiptPath $ForceReleaseReceiptPath `
                -RawForceReceiptSha256 $forceReceipt.Sha256
    }

    Register-ExpectedScheduledTask -PreviousTask $task `
        -OperationId $operationId `
        -ReadinessReceiptPath $ReadinessReceiptPath `
        -ReadinessLockPath $ReadinessLockPath `
        -ReadinessCommitRequestPath $ReadinessCommitRequestPath `
        -InstallSuccessReceiptPath $InstallSuccessReceiptPath
    Replace-FileAtomically -Source $CandidatePath -Destination $installedBinary `
        -ExpectedSha256 $candidateHash -Name 'Viewflow binary'
    Replace-FileAtomically -Source $sourceScript -Destination $installedScript `
        -ExpectedSha256 $sourceScriptHash -Name 'Viewflow client wrapper'
    $installedHash = Get-FileSha256Lower -Path $installedBinary
    $installedScriptHash = Get-FileSha256Lower -Path $installedScript
    if ($installedHash -cne $candidateHash) {
        throw 'Installed Viewflow binary SHA256 mismatch'
    }
    if ($installedScriptHash -cne $sourceScriptHash) {
        throw 'Installed client wrapper SHA256 mismatch'
    }

    Enable-ScheduledTask -TaskPath $taskPath -TaskName $taskName | Out-Null
    $enabledTask = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Assert-ExpectedScheduledTask -Task $enabledTask -RequireReady
    $bootstrapStageContext = $null
    if ($AllowV13Bootstrap) {
        $bootstrapStageContext = @{
            Path = $LinuxStageReceiptPath
            OperationId = $operationId
            BootstrapRequestSha256 = $bootstrapRequestSha256
            MarkerHandoff = $markerHandoffPinned.Value
            MarkerHandoffSha256 = $markerHandoffPinned.Sha256
            PreparedReceiptSha256 = $bootstrapRecoveryPreparedReceipt.Sha256
            MutationPermit = $bootstrapMutationPermit.Receipt
            MutationPermitPath = $BootstrapMutationPermitPath
            MutationPermitSha256 = $bootstrapMutationPermit.Sha256
            ForceEnvelopeSha256 = $bootstrapForceReleaseEnvelope.Sha256
            LinuxEvidenceSha256 = $linuxEvidenceSha256
            WindowsCandidateSha256 = $candidateHash
        }
    }
    $startResult = Start-ViewflowTaskAndWait -OperationId $operationId `
        -ReadinessReceiptPath $ReadinessReceiptPath `
        -ReadinessLockPath $ReadinessLockPath `
        -ExpectedDaemonSha256 $candidateHash `
        -BootstrapStageContext $bootstrapStageContext
    $readinessLease = $startResult.Readiness
    $linuxStageReceipt = $startResult.LinuxStageReceipt
    $running = @($startResult.Process)
    $startedTask = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Assert-ExpectedScheduledTask -Task $startedTask -RequireRunning
    $newTaskXml = Export-ScheduledTask -TaskPath $taskPath -TaskName $taskName
    Assert-TaskXmlContract -Xml $newTaskXml -RequireCurrentReadinessBinding
    $newTaskXmlHash = Get-BytesSha256Lower -Value (
        Get-Utf16TaskXmlBytes -Xml $newTaskXml
    )

    $forceReceiptHash = $null
    $markerHandoffCommitHash = $null
    $preparedCommitHash = $null
    $mutationPermitCommitHash = $null
    $linuxStageCommitHash = $null
    $bootstrapRequestCommitHash = $null
    if ($AllowV13Bootstrap) {
        $forceReceiptRead = Assert-ForceReleaseReceipt `
            -Path $ForceReleaseReceiptPath -OperationId $operationId `
            -CandidateSha256 $candidateHash `
            -LinuxEvidenceSha256 $linuxEvidenceSha256
        $forceReceipt = $forceReceiptRead.Receipt
        $forceReceiptHash = [string]$forceReceiptRead.Sha256
        $processStartFileTime = [string]$startResult.Identity.ProcessStartFileTime
        if ([string]$forceReceipt.tool_user_sid -cne
            [string]$startResult.Identity.OwnerSid -or
            ([long]$forceReceipt.tool_pid -eq
                [long]$startResult.Identity.ProcessId -and
                [string]$forceReceipt.tool_process_start_filetime -ceq
                    $processStartFileTime)) {
            throw ('Started Viewflow process is not distinct from the ' +
                'force-release tool identity')
        }
        foreach ($chainBinding in @(
            @{ Path = $BootstrapRecoveryPreparedReceiptPath; Expected = $bootstrapRecoveryPreparedReceipt.Sha256; Name = 'prepared receipt' },
            @{ Path = $BootstrapMutationPermitPath; Expected = $bootstrapMutationPermit.Sha256; Name = 'mutation permit' },
            @{ Path = $BootstrapForceReleaseEnvelopePath; Expected = $bootstrapForceReleaseEnvelope.Sha256; Name = 'force-release envelope' },
            @{ Path = $LinuxStageReceiptPath; Expected = $linuxStageReceipt.Sha256; Name = 'Linux stage receipt' }
        )) {
            $chainRead = Read-OwnerOnlyUtf8JsonSnapshot -Path $chainBinding.Path `
                -Name "Bootstrap $($chainBinding.Name) commit revalidation"
            if ([string]$chainRead.Sha256 -cne [string]$chainBinding.Expected) {
                throw "Bootstrap $($chainBinding.Name) changed before commit"
            }
        }
        Assert-PinnedBootstrapRequestCurrent
        $markerHandoffCommitRead = Read-Utf8JsonStreamSnapshot `
            -Stream $markerHandoffPinned.Stream `
            -Name 'Marker handoff commit revalidation'
        if ([string]$markerHandoffCommitRead.Sha256 -cne
            [string]$markerHandoffPinned.Sha256) {
            throw 'Marker handoff receipt changed before commit'
        }
        $markerHandoffCommitHash = [string]$markerHandoffPinned.Sha256
        $preparedCommitHash = [string]$bootstrapRecoveryPreparedReceipt.Sha256
        $mutationPermitCommitHash = [string]$bootstrapMutationPermit.Sha256
        $linuxStageCommitHash = [string]$linuxStageReceipt.Sha256
        $bootstrapRequestCommitHash = [string]$bootstrapRequestSha256
    }
    $commitRequest = Write-ReadinessCommitRequest `
        -Path $ReadinessCommitRequestPath -Mode $rollbackMode `
        -OperationId $operationId `
        -LinuxEvidenceSha256 $linuxEvidenceSha256 `
        -ForceReceiptSha256 $forceReceiptHash `
        -MarkerHandoffReceiptSha256 $markerHandoffCommitHash `
        -WindowsPreparedReceiptSha256 $preparedCommitHash `
        -MutationPermitSha256 $mutationPermitCommitHash `
        -LinuxStageReceiptSha256 $linuxStageCommitHash `
        -BootstrapRequestSha256 $bootstrapRequestCommitHash `
        -OldBinarySha256 $oldBinaryHash -NewBinarySha256 $installedHash `
        -WrapperSha256 $installedScriptHash -TaskXmlSha256 $newTaskXmlHash `
        -ProcessIdentity $startResult.Identity -Readiness $readinessLease `
        -ReadinessReceiptPath $ReadinessReceiptPath `
        -ReadinessLockPath $ReadinessLockPath `
        -RequestPublished ([ref]$commitRequestPublished)
    $installSuccessReceipt = Wait-DaemonInstallSuccessReceipt `
        -Path $InstallSuccessReceiptPath -CommitRequest $commitRequest `
        -OperationId $operationId `
        -LinuxEvidenceSha256 $linuxEvidenceSha256 `
        -ForceReceiptSha256 $forceReceiptHash `
        -MarkerHandoffReceiptSha256 $markerHandoffCommitHash `
        -WindowsPreparedReceiptSha256 $preparedCommitHash `
        -MutationPermitSha256 $mutationPermitCommitHash `
        -LinuxStageReceiptSha256 $linuxStageCommitHash `
        -BootstrapRequestSha256 $bootstrapRequestCommitHash `
        -OldBinarySha256 $oldBinaryHash -NewBinarySha256 $installedHash `
        -WrapperSha256 $installedScriptHash -TaskXmlSha256 $newTaskXmlHash `
        -ProcessIdentity $startResult.Identity -Readiness $readinessLease `
        -ReadinessReceiptPath $ReadinessReceiptPath `
        -ReadinessLockPath $ReadinessLockPath `
        -InstallCommitted ([ref]$installCommitted)
    Close-AuthenticatedReadinessLease -Readiness $readinessLease
    $readinessLease = $null
} catch {
    $installFailure = $_
    $readinessCloseFailure = $null
    try {
        Close-AuthenticatedReadinessLease -Readiness $readinessLease
    } catch {
        $readinessCloseFailure = $_
    }
    $readinessLease = $null
    if ($installCommitted -or
        ($commitRequestPublished -and
            -not ($AllowV13Bootstrap -and $bootstrapRecoveryPrepared))) {
        $message = if ($installCommitted) {
            'Viewflow daemon install success was already committed; automatic rollback was not attempted'
        } else {
            'Viewflow commit request was already published; automatic rollback was not attempted because commit outcome is uncertain'
        }
        if ($null -ne $readinessCloseFailure) {
            $message = '{0}; readiness handle cleanup failed: {1}' -f @(
                $message,
                $readinessCloseFailure.Exception.Message
            )
        }
        throw ([InvalidOperationException]::new(
            $message,
            $installFailure.Exception
        ))
    }
    $installException = $installFailure.Exception
    if ($null -ne $readinessCloseFailure) {
        $installException = [AggregateException]::new(
            'Viewflow install and readiness handle cleanup both failed',
            [Exception[]]@(
                $installFailure.Exception,
                $readinessCloseFailure.Exception
            )
        )
    }
    $containmentFailure = $null
    if (-not $authorizationConsumed -and -not $transactionMutated -and
        -not ($AllowV13Bootstrap -and $bootstrapRecoveryPrepared -and
            $bootstrapMutationPermitted)) {
        throw $installException
    }
    try {
        # Establish containment before any authorization-file operation that
        # can fail. A collision must never leave the candidate running.
        Stop-ViewflowTaskAndWait -IgnoreStopError -AllowDisabled
    } catch {
        $containmentFailure = $_
    }
    if ($null -ne $containmentFailure) {
        throw (('Viewflow install failed: {0}; inactive containment failed: {1}; ' +
            'backup retained at {2}') -f @(
                $installException.Message,
                $containmentFailure.Exception.Message,
                $backupRoot
            ))
    }
    if (-not $rollbackPrepared) {
        throw $installException
    }

    if ($AllowV13Bootstrap -and $bootstrapRecoveryPrepared) {
        throw ([InvalidOperationException]::new(
            ('Viewflow bootstrap install failed after durable recovery was ' +
                'armed; the task is Ready and inactive and external rollback ' +
                'authorization remains available at {0}; backup retained at {1}' -f @(
                    $BootstrapRecoveryPreparedReceiptPath,
                    $backupRoot
                )),
            $installException
        ))
    }

    try {
        # Invalidate any published rollback capability before restoring the
        # old artifacts. Operation-scoped files remain available for forensics.
        foreach ($authorizationPath in @($RollbackTokenPath, $RollbackManifestPath)) {
            if (-not [string]::IsNullOrWhiteSpace($authorizationPath) -and
                (Test-Path -LiteralPath $authorizationPath -PathType Leaf)) {
                $null = Move-ConsumedEvidence -Path $authorizationPath `
                    -OperationId $operationId
            }
        }

        Replace-FileAtomically -Source $backupBinary -Destination $installedBinary `
            -ExpectedSha256 $oldBinaryHash -Name 'Restored Viewflow binary'
        Replace-FileAtomically -Source $backupScript -Destination $installedScript `
            -ExpectedSha256 $oldScriptHash -Name 'Restored Viewflow wrapper'
        if ($oldRollbackExisted) {
            Replace-FileAtomically -Source $backupRollbackScript `
                -Destination $installedRollbackScript `
                -ExpectedSha256 $oldRollbackHash -Name 'Restored rollback tool'
        } elseif (Test-Path -LiteralPath $installedRollbackScript) {
            Remove-Item -LiteralPath $installedRollbackScript -Force
        }
        if ($null -ne $oldTaskXml) {
            Register-ScheduledTask -TaskPath $taskPath -TaskName $taskName `
                -Xml $oldTaskXml -Force | Out-Null
        }

        # Registering the legacy definition must not reactivate it through a
        # trigger race. Observe the same stable fail-closed boundary again.
        Stop-ViewflowTaskAndWait -IgnoreStopError

        if ((Get-FileSha256Lower -Path $installedBinary) -cne $oldBinaryHash -or
            (Get-FileSha256Lower -Path $installedScript) -cne $oldScriptHash) {
            throw 'Restored Viewflow artifacts do not match pre-update hashes'
        }
        if ($null -ne $oldTaskXmlHash -and
            (Get-FileSha256Lower -Path $backupTaskXml) -cne $oldTaskXmlHash) {
            throw 'Retained scheduled-task rollback XML hash changed'
        }
        if ($oldRollbackExisted -and
            (Get-FileSha256Lower -Path $installedRollbackScript) -cne
                $oldRollbackHash) {
            throw 'Restored rollback tool does not match its pre-update hash'
        }
        $restoredTask = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName
        if ($restoredTask.State -ne 'Ready' -or
            @(Get-ExactInstalledViewflowProcesses).Count -ne 0) {
            throw 'Rollback did not leave the old Viewflow task Ready and inactive'
        }
        Assert-UpdatableScheduledTask -Task $restoredTask `
            -AllowLegacyLogonTrigger
        $restoredTaskXml = Export-ScheduledTask -TaskPath $taskPath `
            -TaskName $taskName
        Assert-TaskXmlContract -Xml $restoredTaskXml `
            -AllowLegacyLogonTrigger
        $restoredTaskXmlHash = Get-BytesSha256Lower -Value (
            Get-Utf16TaskXmlBytes -Xml $restoredTaskXml
        )
        if ($restoredTaskXmlHash -cne $oldTaskXmlHash) {
            throw 'Restored scheduled-task XML differs from the prepared rollback XML'
        }
    } catch {
        $rollbackFailure = $_
        throw (('Viewflow install failed: {0}; automatic rollback failed: {1}; ' +
            'backup retained at {2}') -f @(
                $installException.Message,
                $rollbackFailure.Exception.Message,
                $backupRoot
            ))
    }
    throw $installException
}

[pscustomobject]@{
    TaskName = $expectedTaskName
    OperationId = $operationId
    RollbackMode = $rollbackMode
    ProcessId = $startResult.Identity.ProcessId
    SessionId = $startResult.Identity.SessionId
    Sha256 = $candidateHash
    ScriptSha256 = $sourceScriptHash
    ConsumedEvidence = $consumedEvidence
    ForceReleaseReceipt = $ForceReleaseReceiptPath
    ReadinessCommitRequest = $ReadinessCommitRequestPath
    ReadinessCommitRequestSha256 = $commitRequest.Sha256
    InstallSuccessReceipt = $InstallSuccessReceiptPath
    InstallSuccessReceiptSha256 = $installSuccessReceipt.Sha256
    RollbackManifest = $RollbackManifestPath
    RollbackToken = $RollbackTokenPath
    BootstrapRecoveryPreparedReceipt = $BootstrapRecoveryPreparedReceiptPath
    BootstrapRecoveryPreparedReceiptSha256 = if (
        $null -ne $bootstrapRecoveryPreparedReceipt
    ) { $bootstrapRecoveryPreparedReceipt.Sha256 } else { $null }
    Backup = $backupRoot
}
