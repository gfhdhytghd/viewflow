param(
    [ValidateRange(1, 60000)]
    [int]$InitialRestartDelayMs = 250,

    [ValidateRange(1, 60000)]
    [int]$MaximumRestartDelayMs = 5000,

    # Zero keeps supervising until Task Scheduler stops this foreground action.
    [ValidateRange(0, 2147483647)]
    [int]$MaximumAttempts = 0,

    [string]$ReadinessReceiptPath,

    [string]$ReadinessLockPath,

    [string]$ReadinessCommitRequestPath,

    [string]$InstallSuccessReceiptPath,

    [string]$OperationId
)

$ErrorActionPreference = 'Stop'

if ($InitialRestartDelayMs -gt $MaximumRestartDelayMs) {
    throw 'InitialRestartDelayMs must not exceed MaximumRestartDelayMs'
}

$readinessOptionCount = @(
    $ReadinessReceiptPath,
    $ReadinessLockPath,
    $ReadinessCommitRequestPath,
    $InstallSuccessReceiptPath,
    $OperationId
).Where({ -not [string]::IsNullOrWhiteSpace($_) }).Count
if ($readinessOptionCount -ne 0 -and $readinessOptionCount -ne 5) {
    throw ('ReadinessReceiptPath, ReadinessLockPath, ' +
        'ReadinessCommitRequestPath, InstallSuccessReceiptPath, and ' +
        'OperationId must be provided together')
}
$readinessArguments = @()
if ($readinessOptionCount -eq 5) {
    foreach ($entry in @(
        @{ Path = $ReadinessReceiptPath; Name = 'ReadinessReceiptPath' },
        @{ Path = $ReadinessLockPath; Name = 'ReadinessLockPath' },
        @{
            Path = $ReadinessCommitRequestPath
            Name = 'ReadinessCommitRequestPath'
        },
        @{
            Path = $InstallSuccessReceiptPath
            Name = 'InstallSuccessReceiptPath'
        }
    )) {
        if (-not [System.IO.Path]::IsPathRooted($entry.Path)) {
            throw "$($entry.Name) must be absolute"
        }
    }
    $normalizedReadinessPaths = @(
        $ReadinessReceiptPath,
        $ReadinessLockPath,
        $ReadinessCommitRequestPath,
        $InstallSuccessReceiptPath
    ) | ForEach-Object { [System.IO.Path]::GetFullPath($_) }
    for ($left = 0; $left -lt $normalizedReadinessPaths.Count; $left++) {
        for ($right = $left + 1; $right -lt $normalizedReadinessPaths.Count; $right++) {
            if ($normalizedReadinessPaths[$left].Equals(
                $normalizedReadinessPaths[$right],
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw 'Readiness evidence and commit paths must be pairwise distinct'
            }
        }
    }
    if ($OperationId -cnotmatch '^[A-Za-z0-9_-]{16,128}$') {
        throw 'OperationId is invalid'
    }
    $readinessArguments = @(
        '--readiness-receipt', [System.IO.Path]::GetFullPath($ReadinessReceiptPath),
        '--readiness-lock', [System.IO.Path]::GetFullPath($ReadinessLockPath),
        '--readiness-commit-request',
            [System.IO.Path]::GetFullPath($ReadinessCommitRequestPath),
        '--install-success-receipt',
            [System.IO.Path]::GetFullPath($InstallSuccessReceiptPath),
        '--operation-id', $OperationId
    )
}

$installRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$identityRoot = Join-Path $installRoot 'identity'
$viewflowExecutable = Join-Path $installRoot 'viewflowd.exe'
$logRoot = Join-Path $env:LOCALAPPDATA 'Viewflow\logs'
$logFile = Join-Path $logRoot 'peer.log'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

function Write-ViewflowLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $line = "$(Get-Date -Format o) $Message"
    $line | Tee-Object -FilePath $logFile -Append
}

$attempt = 0
$restartDelayMs = $InitialRestartDelayMs

while ($true) {
    $attempt++
    $startedAt = [DateTime]::UtcNow
    Write-ViewflowLog "supervisor starting viewflowd attempt=$attempt"

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = 1
    $LASTEXITCODE = $null
    try {
        # Windows PowerShell 5.1 represents native stderr records as PowerShell
        # errors. Continue plus 2>&1 keeps those records in the log instead of
        # terminating the supervisor. Keep this invocation synchronous so
        # Stop-ScheduledTask terminates the action and its child process tree.
        & $viewflowExecutable connect `
            --peer 172.16.105.62:44119 `
            --server-name viewflow-linux `
            --cert (Join-Path $identityRoot 'peer.pem') `
            --key (Join-Path $identityRoot 'peer.key') `
            --ca (Join-Path $identityRoot 'ca.pem') `
            --input-backend native `
            --device-id 00000000000000000000000000000002 `
            --probe-interval-ms 1000 `
            --probe-timeout-ms 3000 `
            @readinessArguments 2>&1 | ForEach-Object {
                Write-ViewflowLog "viewflowd $_"
            }

        if ($null -ne $LASTEXITCODE) {
            $exitCode = $LASTEXITCODE
        }
    } catch {
        $exitCode = 1
        Write-ViewflowLog "supervisor invocation failed error=$($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    $runtimeMs = [Math]::Max(
        [long]0,
        [long][Math]::Round(([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
    )
    Write-ViewflowLog "viewflowd exited attempt=$attempt code=$exitCode runtime_ms=$runtimeMs"

    if ($MaximumAttempts -ne 0 -and $attempt -ge $MaximumAttempts) {
        Write-ViewflowLog "supervisor stopped after attempt limit code=$exitCode"
        exit $exitCode
    }

    # A process that stayed healthy for at least 30 seconds starts a fresh
    # reconnect series. Rapid failures back off exponentially to the cap.
    if ($runtimeMs -ge 30000) {
        $restartDelayMs = $InitialRestartDelayMs
    }

    Write-ViewflowLog "supervisor restarting viewflowd delay_ms=$restartDelayMs"
    Start-Sleep -Milliseconds $restartDelayMs
    $restartDelayMs = [Math]::Min(
        $MaximumRestartDelayMs,
        [Math]::Max($InitialRestartDelayMs, $restartDelayMs * 2)
    )
}
