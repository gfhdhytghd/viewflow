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

function Assert-ThrowsMessage {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage
    )

    $observed = $null
    try {
        & $Action
    } catch {
        $observed = $_.Exception.Message
    }
    if ($null -eq $observed) {
        throw 'Expected readiness disconnect to reject commit-request publication'
    }
    if ($observed.IndexOf(
        $ExpectedMessage,
        [StringComparison]::Ordinal
    ) -lt 0) {
        throw "Unexpected readiness disconnect failure: $observed"
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
    'Assert-LowerSha256',
    'Assert-NewAbsoluteOutputPath',
    'New-OwnerOnlyFileSecurity',
    'New-RandomLowerHex',
    'Get-BytesSha256Lower',
    'Get-Utf16TaskXmlBytes',
    'Read-Utf8JsonStreamSnapshot',
    'Assert-ReadinessLockIsLive',
    'Assert-AuthenticatedReadinessCommitBoundary',
    'Close-AuthenticatedReadinessLease',
    'Write-ReadinessCommitRequest'
)) {
    Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
}

$script:fixtureMockCanary = 'VIEWFLOW_READINESS_DISCONNECT_FIXTURE'
$script:identityChecks = 0
$script:taskReads = 0
$script:taskValidations = 0
$script:taskXmlExports = 0
$script:taskXmlValidations = 0
$script:fixtureTaskXml = '<Task fixture="readiness-disconnect" />'
function global:Assert-ViewflowProcessIdentityCurrent {
    param([Parameter(Mandatory = $true)]$Identity)
    if ($script:fixtureMockCanary -cne
        'VIEWFLOW_READINESS_DISCONNECT_FIXTURE') {
        throw 'Readiness disconnect process mock is not armed'
    }
    $script:identityChecks++
    [pscustomobject]@{ Id = [long]$Identity.ProcessId }
}
function global:Get-ScheduledTask {
    param([string]$TaskPath, [string]$TaskName)
    if ($script:fixtureMockCanary -cne
        'VIEWFLOW_READINESS_DISCONNECT_FIXTURE') {
        throw 'Readiness disconnect task mock is not armed'
    }
    $script:taskReads++
    [pscustomobject]@{ State = 'Running' }
}
function global:Assert-ExpectedScheduledTask {
    param($Task, [switch]$RequireRunning)
    if ($script:fixtureMockCanary -cne
        'VIEWFLOW_READINESS_DISCONNECT_FIXTURE') {
        throw 'Readiness disconnect task validation mock is not armed'
    }
    if (-not $RequireRunning -or $Task.State -cne 'Running') {
        throw 'Readiness disconnect task validation mock received invalid state'
    }
    $script:taskValidations++
}
function global:Export-ScheduledTask {
    param([string]$TaskPath, [string]$TaskName)
    if ($script:fixtureMockCanary -cne
        'VIEWFLOW_READINESS_DISCONNECT_FIXTURE') {
        throw 'Readiness disconnect task XML mock is not armed'
    }
    $script:taskXmlExports++
    $script:fixtureTaskXml
}
function global:Assert-TaskXmlContract {
    param([string]$Xml, [switch]$RequireCurrentReadinessBinding)
    if ($script:fixtureMockCanary -cne
        'VIEWFLOW_READINESS_DISCONNECT_FIXTURE') {
        throw 'Readiness disconnect task XML validation mock is not armed'
    }
    if (-not $RequireCurrentReadinessBinding -or
        $Xml -cne $script:fixtureTaskXml) {
        throw 'Readiness disconnect task XML validation mock received invalid XML'
    }
    $script:taskXmlValidations++
}
foreach ($mockName in @(
    'Assert-ViewflowProcessIdentityCurrent',
    'Get-ScheduledTask',
    'Assert-ExpectedScheduledTask',
    'Export-ScheduledTask',
    'Assert-TaskXmlContract'
)) {
    $resolvedMock = Get-Command $mockName -CommandType Function -ErrorAction Stop
    if ($resolvedMock.Definition -notmatch
        'VIEWFLOW_READINESS_DISCONNECT_FIXTURE') {
        throw "Refusing fixture execution: $mockName did not resolve to the mock"
    }
}

$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$expectedTaskUserSid = $currentIdentity.User.Value
$expectedPeer = 'fixture.invalid:44119'
$expectedDeviceId = 'windows-fixture'
$taskPath = '\'
$taskName = 'Viewflow Peer'
$lowerSha = 'a' * 64
$handoffSha = 'b' * 64
$preparedSha = 'c' * 64
$permitSha = 'd' * 64
$stageSha = 'e' * 64
$bootstrapRequestSha = 'f' * 64
$taskXmlSha = Get-BytesSha256Lower -Value (
    Get-Utf16TaskXmlBytes -Xml $script:fixtureTaskXml
)
$processIdentity = [pscustomobject]@{
    ProcessId = 424242
    ProcessStartFileTime = '133700000000000000'
    SessionId = 1
    OwnerSid = $expectedTaskUserSid
}
$fixtureRoot = Join-Path $env:TEMP (
    'viewflow-readiness-disconnect-{0}' -f [Guid]::NewGuid().ToString('N')
)
$receiptPath = Join-Path $fixtureRoot 'readiness.json'
$lockPath = Join-Path $fixtureRoot 'readiness.lock'
$requestPath = Join-Path $fixtureRoot 'commit-request.json'
$receiptStream = $null
$lockStream = $null
$daemonLock = $null
$readiness = $null

try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $receiptBytes = $utf8.GetBytes("{`"fixture`":`"receipt`"}`n")
    $lockBytes = $utf8.GetBytes("{`"fixture`":`"lock`"}`n")
    [System.IO.File]::WriteAllBytes($receiptPath, $receiptBytes)
    [System.IO.File]::WriteAllBytes($lockPath, $lockBytes)

    # Model the daemon's live lock: writers are denied while readers, including
    # the installer's pinned snapshot, remain allowed.
    $daemonLock = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::Read
    )
    $receiptStream = [System.IO.File]::Open(
        $receiptPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $lockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $readiness = [pscustomobject]@{
        ReceiptSha256 = Get-BytesSha256Lower -Value $receiptBytes
        LockSha256 = Get-BytesSha256Lower -Value $lockBytes
        ConnectionGeneration = 9
        EstablishedAtUtc = '2026-08-29T00:00:00.000Z'
        ReceiptStream = $receiptStream
        LockStream = $lockStream
    }
    $requestPublished = $false

    # Positive control: the original installer liveness probe recognizes the
    # held daemon lock before the simulated disconnect.
    Assert-ReadinessLockIsLive -Path $lockPath
    $duplicatePath = Join-Path $fixtureRoot 'commit-request-duplicate.json'
    $duplicatePublished = $false
    Assert-ThrowsMessage `
        -ExpectedMessage 'must be pairwise distinct' `
        -Action {
            Write-ReadinessCommitRequest -Path $duplicatePath `
                -Mode 'bootstrap-v1.3' `
                -OperationId 'readiness-disconnect-fixture' `
                -LinuxEvidenceSha256 $lowerSha -ForceReceiptSha256 $lowerSha `
                -MarkerHandoffReceiptSha256 $handoffSha `
                -WindowsPreparedReceiptSha256 $preparedSha `
                -MutationPermitSha256 $permitSha `
                -LinuxStageReceiptSha256 $stageSha `
                -BootstrapRequestSha256 $stageSha `
                -OldBinarySha256 $lowerSha -NewBinarySha256 $lowerSha `
                -WrapperSha256 $lowerSha -TaskXmlSha256 $taskXmlSha `
                -ProcessIdentity $processIdentity -Readiness $readiness `
                -ReadinessReceiptPath $receiptPath -ReadinessLockPath $lockPath `
                -RequestPublished ([ref]$duplicatePublished)
        }
    if ($duplicatePublished -or (Test-Path -LiteralPath $duplicatePath)) {
        throw 'Duplicate bootstrap chain published a commit request'
    }
    $validRequestPath = Join-Path $fixtureRoot 'commit-request-valid.json'
    $validPublished = $false
    $validRequest = Write-ReadinessCommitRequest -Path $validRequestPath `
        -Mode 'bootstrap-v1.3' `
        -OperationId 'readiness-disconnect-fixture' `
        -LinuxEvidenceSha256 $lowerSha -ForceReceiptSha256 $lowerSha `
        -MarkerHandoffReceiptSha256 $handoffSha `
        -WindowsPreparedReceiptSha256 $preparedSha `
        -MutationPermitSha256 $permitSha `
        -LinuxStageReceiptSha256 $stageSha `
        -BootstrapRequestSha256 $bootstrapRequestSha `
        -OldBinarySha256 $lowerSha -NewBinarySha256 $lowerSha `
        -WrapperSha256 $lowerSha -TaskXmlSha256 $taskXmlSha `
        -ProcessIdentity $processIdentity -Readiness $readiness `
        -ReadinessReceiptPath $receiptPath -ReadinessLockPath $lockPath `
        -RequestPublished ([ref]$validPublished)
    if (-not $validPublished -or
        (Get-BytesSha256Lower -Value ([IO.File]::ReadAllBytes($validRequestPath))) -cne
            $validRequest.Sha256) {
        throw 'Schema-5 bootstrap commit request was not published exactly once'
    }
    $validValue = Get-Content -LiteralPath $validRequestPath -Raw |
        ConvertFrom-Json
    $validKeys = @($validValue.PSObject.Properties | ForEach-Object Name)
    foreach ($requiredField in @(
        'marker_handoff_receipt_sha256',
        'windows_prepared_receipt_sha256', 'mutation_permit_sha256',
        'linux_stage_receipt_sha256', 'bootstrap_request_sha256'
    )) {
        if ($validKeys -cnotcontains $requiredField) {
            throw "Schema-5 bootstrap commit request omitted $requiredField"
        }
    }
    $validChainHashes = @(
        $validValue.force_release_receipt_sha256,
        $validValue.marker_handoff_receipt_sha256,
        $validValue.windows_prepared_receipt_sha256,
        $validValue.mutation_permit_sha256,
        $validValue.linux_stage_receipt_sha256,
        $validValue.bootstrap_request_sha256
    )
    if ($validValue.schema_version -ne 5 -or
        @($validChainHashes | Sort-Object -Unique).Count -ne 6) {
        throw 'Schema-5 bootstrap commit request lost its pairwise-distinct chain'
    }
    $normalRequestPath = Join-Path $fixtureRoot 'commit-request-normal.json'
    $normalPublished = $false
    $null = Write-ReadinessCommitRequest -Path $normalRequestPath `
        -Mode 'normal-v2' -OperationId 'readiness-normal-fixture' `
        -LinuxEvidenceSha256 $lowerSha `
        -OldBinarySha256 $lowerSha -NewBinarySha256 $lowerSha `
        -WrapperSha256 $lowerSha -TaskXmlSha256 $taskXmlSha `
        -ProcessIdentity $processIdentity -Readiness $readiness `
        -ReadinessReceiptPath $receiptPath -ReadinessLockPath $lockPath `
        -RequestPublished ([ref]$normalPublished)
    $normalValue = Get-Content -LiteralPath $normalRequestPath -Raw |
        ConvertFrom-Json
    if (-not $normalPublished -or
        $null -ne $normalValue.force_release_receipt_sha256 -or
        $null -ne $normalValue.marker_handoff_receipt_sha256 -or
        $null -ne $normalValue.windows_prepared_receipt_sha256 -or
        $null -ne $normalValue.mutation_permit_sha256 -or
        $null -ne $normalValue.linux_stage_receipt_sha256 -or
        $null -ne $normalValue.bootstrap_request_sha256) {
        throw 'Schema-5 normal commit request must carry six explicit nulls'
    }
    $script:identityChecks = 0
    $script:taskReads = 0
    $script:taskValidations = 0
    $script:taskXmlExports = 0
    $script:taskXmlValidations = 0
    $daemonLock.Dispose()
    $daemonLock = $null

    Assert-ThrowsMessage `
        -ExpectedMessage 'Readiness lock is not held by the running daemon' `
        -Action {
            Write-ReadinessCommitRequest -Path $requestPath `
                -Mode 'bootstrap-v1.3' `
                -OperationId 'readiness-disconnect-fixture' `
                -LinuxEvidenceSha256 $lowerSha `
                -ForceReceiptSha256 $lowerSha `
                -MarkerHandoffReceiptSha256 $handoffSha `
                -WindowsPreparedReceiptSha256 $preparedSha `
                -MutationPermitSha256 $permitSha `
                -LinuxStageReceiptSha256 $stageSha `
                -BootstrapRequestSha256 $bootstrapRequestSha `
                -OldBinarySha256 $lowerSha `
                -NewBinarySha256 $lowerSha `
                -WrapperSha256 $lowerSha `
                -TaskXmlSha256 $taskXmlSha `
                -ProcessIdentity $processIdentity `
                -Readiness $readiness `
                -ReadinessReceiptPath $receiptPath `
                -ReadinessLockPath $lockPath `
                -RequestPublished ([ref]$requestPublished)
        }

    if (Test-Path -LiteralPath $requestPath) {
        throw 'Disconnect fixture published a commit request'
    }
    if ($requestPublished) {
        throw 'Disconnect fixture marked the commit request published'
    }
    $commitTemporaries = @(
        Get-ChildItem -LiteralPath $fixtureRoot -File |
            Where-Object {
                $_.Name -like '.commit-request.json.*.commit-request.tmp'
            }
    )
    if ($commitTemporaries.Count -ne 0) {
        throw 'Disconnect fixture retained a commit-request temporary file'
    }
    if ($script:identityChecks -ne 2 -or
        $script:taskReads -ne 1 -or
        $script:taskValidations -ne 1 -or
        $script:taskXmlExports -ne 1 -or
        $script:taskXmlValidations -ne 1) {
        throw (
            'Commit-boundary fixture did not execute the expected process and ' +
            'task revalidation path'
        )
    }
    if (-not $readiness.ReceiptStream.CanRead -or
        -not $readiness.LockStream.CanRead) {
        throw 'Pinned readiness handles closed before fixture cleanup'
    }

    Close-AuthenticatedReadinessLease -Readiness $readiness
    $receiptStream = $null
    $lockStream = $null
    if ($null -ne $readiness.ReceiptStream -or
        $null -ne $readiness.LockStream) {
        throw 'Pinned readiness handles were not cleared after fixture cleanup'
    }

    Write-Output (
        'viewflow readiness disconnect-before-commit PS5.1 fixture passed'
    )
} finally {
    if ($null -ne $daemonLock) {
        $daemonLock.Dispose()
    }
    if ($null -ne $receiptStream) {
        $receiptStream.Dispose()
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
    Remove-Item Function:\Assert-ViewflowProcessIdentityCurrent `
        -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-ScheduledTask -ErrorAction SilentlyContinue
    Remove-Item Function:\Assert-ExpectedScheduledTask `
        -ErrorAction SilentlyContinue
    Remove-Item Function:\Export-ScheduledTask -ErrorAction SilentlyContinue
    Remove-Item Function:\Assert-TaskXmlContract -ErrorAction SilentlyContinue
}
