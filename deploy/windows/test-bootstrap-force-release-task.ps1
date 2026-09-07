param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'install-viewflow.ps1')
)

# This fixture uses only mocked ScheduledTasks/CIM commands.  It is safe to run
# on the Windows host because it never registers or starts a real task.
$ErrorActionPreference = 'Stop'

function Get-InstallerFunctionText {
    param([Parameter(Mandatory = $true)]$Ast,
          [Parameter(Mandatory = $true)][string]$Name)
    $found = $Ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $Name
    }, $true)
    if ($null -eq $found) { throw "Installer function was not found: $Name" }
    $found.Extent.Text
}

function Assert-Fixture {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw "Installer has $($parseErrors.Count) PowerShell parser error(s)"
}
foreach ($name in @(
    'Get-ExceptionChainText',
    'Get-BootstrapForceReleaseAttemptEvidencePath',
    'Get-BootstrapForceReleaseDeadlineFailure',
    'Get-BootstrapForceReleaseMonotonicSeconds',
    'Invoke-BootstrapForceRelease'
)) {
    Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
}

$bootstrapTaskPath = '\'
$bootstrapTaskDispatchDeadlineSeconds = 1
$bootstrapTaskExecutionDeadlineSeconds = 2
$stopStableObservationMs = 0
$global:fixtureScenario = $null
$global:fixtureRegistered = $false
$global:fixtureStarted = $false
$global:fixturePoll = 0
$global:fixtureAttempts = @()
$global:fixtureCleanupFailure = $false
$global:fixtureCandidatePath = 'C:\fixture\viewflowd.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'viewflow-bootstrap-force-release-{0}' -f [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Reset-Fixture([string]$Name) {
    $global:fixtureScenario = $Name
    $global:fixtureRegistered = $false
    $global:fixtureStarted = $false
    $global:fixturePoll = 0
    $global:fixtureAttempts = @()
    $global:fixtureCleanupFailure = $false
    $script:bootstrapTaskDispatchDeadlineSeconds = if ($Name -ceq 'delayed') {
        5
    } else {
        1
    }
    $script:bootstrapTaskExecutionDeadlineSeconds = if ($Name -ceq 'delayed') {
        1
    } else {
        2
    }
    $global:fixtureClockSeconds = 0
}

function global:Assert-NewAbsoluteOutputPath { param([string]$Path, [string]$Name) }
function global:New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory) [pscustomobject]@{} }
function global:New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) [pscustomobject]@{} }
function global:New-ScheduledTaskSettingsSet {
    param($MultipleInstances, [switch]$AllowStartIfOnBatteries,
          [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit, $RestartCount)
    [pscustomobject]@{ ExecutionTimeLimit = $ExecutionTimeLimit }
}
function global:Register-ScheduledTask { param($TaskPath, $TaskName, $Action, $Principal, $Settings, [switch]$Force) $global:fixtureRegistered = $true }
function global:Start-ScheduledTask { param($TaskPath, $TaskName) $global:fixtureStarted = $true }
function global:Stop-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction) }
function global:Unregister-ScheduledTask {
    param($TaskPath, $TaskName, $Confirm, $ErrorAction)
    $global:fixtureRegistered = $false
    if ($global:fixtureCleanupFailure) { throw 'fixture unregister failure' }
}
function global:Get-ScheduledTask {
    param($TaskPath, $TaskName, $ErrorAction)
    if (-not $global:fixtureRegistered) { return $null }
    if (-not $global:fixtureStarted) { return [pscustomobject]@{ State = 'Ready' } }
    $global:fixturePoll++
    if ($global:fixtureScenario -ceq 'never') { return [pscustomobject]@{ State = 'Ready' } }
    if ($global:fixtureScenario -ceq 'delayed') {
        if ($global:fixturePoll -le 5) { return [pscustomobject]@{ State = 'Ready' } }
        if ($global:fixturePoll -eq 6) { return [pscustomobject]@{ State = 'Running' } }
        return [pscustomobject]@{ State = 'Ready' }
    }
    if ($global:fixturePoll -eq 1) { return [pscustomobject]@{ State = 'Running' } }
    [pscustomobject]@{ State = 'Ready' }
}
function global:Get-ScheduledTaskInfo {
    param($TaskPath, $TaskName, $ErrorAction)
    [pscustomobject]@{
        LastTaskResult = if ($global:fixtureScenario -ceq 'nonzero') { 7 } else { 0 }
        LastRunTime = if ($global:fixtureScenario -ceq 'history-disabled') {
            [DateTime]::MinValue
        } else {
            [DateTime]::UtcNow
        }
    }
}
function global:Get-BootstrapForceReleaseCandidateProcesses {
    param([string]$CandidateFullPath)
    $present = $false
    if ($global:fixtureScenario -ceq 'delayed') { $present = $global:fixturePoll -eq 6 }
    elseif ($global:fixtureScenario -notin @('never', 'no-pid')) { $present = $global:fixturePoll -eq 1 }
    if ($present) {
        return @([pscustomobject]@{
            ProcessId = 4242
            ExecutablePath = $global:fixtureCandidatePath
        })
    }
    @()
}
function global:Get-ProcessStartFileTimeString { param([int]$ProcessId) '133700000000000000' }
function global:Assert-ForceReleaseReceipt {
    param($Path, $OperationId, $CandidateSha256, $LinuxEvidenceSha256,
          $ObservedPid, $ObservedProcessStartFileTime)
    Assert-Fixture ($ObservedPid -eq 4242 -and
        $ObservedProcessStartFileTime -ceq '133700000000000000') `
        'valid receipt was not bound to the observed candidate PID/FILETIME'
    [pscustomobject]@{ Receipt = [pscustomobject]@{}; Sha256 = 'f' * 64 }
}
function global:Get-BootstrapForceReleaseAttemptSnapshot {
    param($TaskPath, $TaskName, $CandidateFullPath, $ReceiptPath,
          [long]$ObservedPid, [string]$ObservedProcessStartFileTime)
    if ($global:fixtureScenario -notin @('never', 'no-pid')) {
        Assert-Fixture ($ObservedPid -eq 4242 -and
            $ObservedProcessStartFileTime -ceq '133700000000000000') `
            'attempt snapshot did not retain loop-observed PID/FILETIME'
    }
    [ordered]@{
        task_state = 'Ready'
        last_task_result = if ($global:fixtureScenario -ceq 'nonzero') { [long]7 } else { [long]0 }
        last_run_time_utc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        observed_pid = if ($global:fixtureScenario -in @('never', 'no-pid')) { $null } else { $ObservedPid }
        observed_process_start_filetime = if ($global:fixtureScenario -in @('never', 'no-pid')) { $null } else { $ObservedProcessStartFileTime }
        receipt_exists = $global:fixtureScenario -ne 'never'
        snapshot_error_chain = $null
    }
}
function global:Write-BootstrapForceReleaseAttemptEvidence {
    param($Path, $OperationId, $TaskName, $CandidateFullPath, $CandidateSha256,
          $ReceiptPath, $Outcome, $Phase, $StartedAtUtc, $Snapshot, $Failure,
          $CleanupErrorChain)
    $global:fixtureAttempts += [pscustomobject]@{
        Path = $Path; TaskName = $TaskName; Outcome = $Outcome; Phase = $Phase
        Snapshot = $Snapshot; ErrorChain = (Get-ExceptionChainText -ErrorRecord $Failure)
        CleanupErrorChain = $CleanupErrorChain
    }
    [pscustomobject]@{ Path = $Path; Sha256 = 'e' * 64 }
}

foreach ($mockName in @(
    'Assert-NewAbsoluteOutputPath', 'New-ScheduledTaskAction',
    'New-ScheduledTaskPrincipal', 'New-ScheduledTaskSettingsSet',
    'Register-ScheduledTask', 'Get-ScheduledTask', 'Start-ScheduledTask',
    'Stop-ScheduledTask', 'Unregister-ScheduledTask',
    'Get-ScheduledTaskInfo', 'Get-BootstrapForceReleaseCandidateProcesses',
    'Get-BootstrapForceReleaseAttemptSnapshot',
    'Write-BootstrapForceReleaseAttemptEvidence', 'Assert-ForceReleaseReceipt'
)) {
    if ((Get-Command $mockName -CommandType Function -ErrorAction Stop).ModuleName) {
        throw "Fixture mock did not override command: $mockName"
    }
}

function Invoke-Case {
    param([string]$Name, [bool]$ShouldPass)
    Reset-Fixture $Name
    if ($Name -ceq 'cleanup-failure') { $global:fixtureCleanupFailure = $true }
    $receiptPath = Join-Path $testRoot 'raw-force-release.json'
    if (Test-Path -LiteralPath $receiptPath) {
        Remove-Item -LiteralPath $receiptPath -Force
    }
    if ($Name -cne 'never') {
        [IO.File]::WriteAllText($receiptPath, '{}')
    }
    $threw = $false
    $message = ''
    try {
        $null = Invoke-BootstrapForceRelease -Candidate $global:fixtureCandidatePath `
            -ReceiptPath $receiptPath `
            -OperationId 'fixture-operation-00000001' -CandidateSha256 ('a' * 64) `
            -LinuxEvidenceSha256 ('b' * 64) -MonotonicSeconds {
                $global:fixtureClockSeconds += 0.75
                $global:fixtureClockSeconds
            }
    } catch {
        $threw = $true
        $message = $_.Exception.ToString()
    }
    Assert-Fixture ($threw -ne $ShouldPass) "case $Name pass expectation failed: $message"
    Assert-Fixture ($global:fixtureAttempts.Count -eq 1) "case $Name did not publish one attempt evidence object"
    $attempt = $global:fixtureAttempts[0]
    Assert-Fixture ($attempt.Path -match 'force-release-attempt\.json$') "case $Name used wrong evidence leaf"
    Assert-Fixture ($attempt.TaskName -ceq 'Viewflow Bootstrap Force Release fixture-operation-00000001') "case $Name used non-operation task name"
    Assert-Fixture (($attempt.Outcome -ceq 'succeeded') -eq $ShouldPass) "case $Name evidence outcome is wrong"
    if (-not $ShouldPass) {
        Assert-Fixture (-not [string]::IsNullOrWhiteSpace($attempt.ErrorChain) -or
            -not [string]::IsNullOrWhiteSpace($attempt.CleanupErrorChain)) "case $Name did not preserve failure evidence"
    }
    [pscustomobject]@{ Case = $Name; Passed = $true; Message = $message }
}

try {
    $results = @()
    # Model the real boundary directly: a queued task may consume 31 seconds
    # (beyond the old one-window 30s limit) and still receive its 30s execution
    # budget; only the 120s dispatch deadline bounds the queue.
    $script:bootstrapTaskDispatchDeadlineSeconds = 120
    $script:bootstrapTaskExecutionDeadlineSeconds = 30
    Assert-Fixture ($null -eq (Get-BootstrapForceReleaseDeadlineFailure `
        -DispatchElapsedSeconds 31 -ExecutionElapsedSeconds 0 `
        -TaskFullName '\Viewflow Bootstrap Force Release fixture-operation-00000001')) `
        '31-second dispatch queue incorrectly consumed the execution deadline'
    Assert-Fixture ((Get-BootstrapForceReleaseDeadlineFailure `
        -DispatchElapsedSeconds 120 -ExecutionElapsedSeconds -1 `
        -TaskFullName '\Viewflow Bootstrap Force Release fixture-operation-00000001') -match 'never dispatched') `
        'never-dispatched deadline was not enforced'
    # This end-to-end mock queues for 4.5s (> its 1s execution budget) before
    # Running/PID begins; it must still receive a fresh full execution budget.
    $results += Invoke-Case -Name 'delayed' -ShouldPass $true
    $results += Invoke-Case -Name 'never' -ShouldPass $false
    $results += Invoke-Case -Name 'nonzero' -ShouldPass $false
    $results += Invoke-Case -Name 'no-pid' -ShouldPass $false
    $results += Invoke-Case -Name 'success' -ShouldPass $true
    $results += Invoke-Case -Name 'cleanup-failure' -ShouldPass $false
    $results += Invoke-Case -Name 'history-disabled' -ShouldPass $false
    $results | Format-Table -AutoSize
    Write-Output 'bootstrap force-release temporary-task fixture passed'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
