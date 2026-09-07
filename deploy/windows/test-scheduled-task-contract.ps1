param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'install-viewflow.ps1')
)

$ErrorActionPreference = 'Stop'

function Get-InstallerFunctionText {
    param(
        [Parameter(Mandatory = $true)]
        $Ast,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $functionAst = $Ast.Find(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $Node.Name -eq $Name
        },
        $true
    )
    if ($null -eq $functionAst) {
        throw "Installer function was not found: $Name"
    }
    $functionAst.Extent.Text
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    $threw = $false
    try {
        & $Action
    } catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "Expected scheduled-task case to fail: $Name"
    }
}

try {
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
        'Split-WindowsCommandLine',
        'Assert-ExactArguments',
        'Assert-TaskActionArguments',
        'Resolve-LegacyLogonTriggerSid',
        'Assert-LegacyOrNoTaskTriggers',
        'Assert-UpdatableScheduledTask',
        'Assert-ExpectedScheduledTask',
        'Register-ExpectedScheduledTask'
    )) {
        Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
    }

    $taskPath = '\'
    $taskName = 'Viewflow Peer'
    $expectedTaskName = '\Viewflow Peer'
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Viewflow'
    $installedScript = Join-Path $installRoot 'viewflow-client.ps1'
    $expectedPowerShell = [System.IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    )
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $expectedTaskUserSid = $currentIdentity.User.Value
    $currentUserName = $currentIdentity.Name
    $expectedOperationId = 'fixture-operation-00000001'
    $expectedReadinessReceiptPath = Join-Path $env:TEMP 'viewflow-readiness.json'
    $expectedReadinessLockPath = Join-Path $env:TEMP 'viewflow-readiness.lock'
    $expectedReadinessCommitRequestPath = Join-Path $env:TEMP 'viewflow-commit.request'
    $expectedInstallSuccessReceiptPath = Join-Path $env:TEMP 'viewflow-install-success.json'

    $legacyTask = [pscustomobject]@{
        State = 'Running'
        Actions = @([pscustomobject]@{
            Execute = 'powershell.exe'
            Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
                '-WindowStyle Hidden -File "{0}"' -f $installedScript)
            WorkingDirectory = $installRoot
        })
        Principal = [pscustomobject]@{
            UserId = $currentUserName
            LogonType = 'Interactive'
            RunLevel = 'Limited'
        }
        Triggers = @()
        Description = 'Viewflow test task'
    }
    Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning
    $legacyTask.Triggers = $null
    Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning
    $legacyTask.Triggers = @()
    $legacyLogonTrigger = [pscustomobject]@{
        CimClass = [pscustomobject]@{
            CimClassName = 'MSFT_TaskLogonTrigger'
        }
        UserId = $currentUserName
        Enabled = $null
    }
    $legacyTask.Triggers = @($legacyLogonTrigger)
    Assert-Throws -Name 'legacy LogonTrigger requires explicit compatibility' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning
    }
    Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
        -AllowLegacyLogonTrigger
    $legacyLogonTrigger.Enabled = $true
    Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
        -AllowLegacyLogonTrigger
    $legacyLogonTrigger.Enabled = $false
    Assert-Throws -Name 'disabled legacy LogonTrigger is rejected' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
            -AllowLegacyLogonTrigger
    }
    $legacyLogonTrigger.Enabled = 'true'
    Assert-Throws -Name 'non-Boolean legacy LogonTrigger Enabled is rejected' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
            -AllowLegacyLogonTrigger
    }
    $legacyLogonTrigger.Enabled = $null
    $legacyLogonTrigger.UserId = 'S-1-5-18'
    Assert-Throws -Name 'wrong-user legacy LogonTrigger is rejected' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
            -AllowLegacyLogonTrigger
    }
    $missingUserTrigger = [pscustomobject]@{
        CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' }
        Enabled = $true
    }
    $legacyTask.Triggers = @($missingUserTrigger)
    Assert-Throws -Name 'legacy LogonTrigger without UserId is rejected' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
            -AllowLegacyLogonTrigger
    }
    $legacyLogonTrigger.UserId = $currentUserName
    $legacyTask.Triggers = @($legacyLogonTrigger, $legacyLogonTrigger)
    Assert-Throws -Name 'multiple legacy LogonTriggers are rejected' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
            -AllowLegacyLogonTrigger
    }
    $legacyTask.Triggers = @([pscustomobject]@{
        CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskBootTrigger' }
        UserId = $currentUserName
        Enabled = $true
    })
    Assert-Throws -Name 'non-logon legacy trigger is rejected' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning `
            -AllowLegacyLogonTrigger
    }
    $legacyTask.Triggers = @()
    $legacyTask.State = 'Ready'
    Assert-Throws -Name 'preflight Ready is rejected' -Action {
        Assert-UpdatableScheduledTask -Task $legacyTask -RequireRunning
    }
    $legacyTask.State = 'Running'

    $script:registeredTask = $null
    $script:nextRegisteredState = 'Disabled'
    $script:fixtureMockCanary = 'VIEWFLOW_FIXTURE_MOCK_ONLY'
    function global:Register-ScheduledTask {
        param(
            [string]$TaskPath,
            [string]$TaskName,
            $Action,
            $Principal,
            $Settings,
            $Trigger,
            [string]$Description,
            [switch]$Force
        )
        if ($script:fixtureMockCanary -cne 'VIEWFLOW_FIXTURE_MOCK_ONLY') {
            throw 'Scheduled-task fixture registration mock is not armed'
        }
        $script:registeredTask = [pscustomobject]@{
            State = $script:nextRegisteredState
            Actions = @($Action)
            Principal = $Principal
            Settings = $Settings
            Triggers = if ($null -eq $Trigger) { @() } else { @($Trigger) }
            Description = $Description
        }
        $script:registeredTask
    }
    function global:Get-ScheduledTask {
        param([string]$TaskPath, [string]$TaskName)
        if ($script:fixtureMockCanary -cne 'VIEWFLOW_FIXTURE_MOCK_ONLY') {
            throw 'Scheduled-task fixture read mock is not armed'
        }
        $script:registeredTask
    }
    function global:New-ScheduledTaskAction {
        param([string]$Execute, [string]$Argument, [string]$WorkingDirectory)
        [pscustomobject]@{
            Execute = $Execute
            Arguments = $Argument
            WorkingDirectory = $WorkingDirectory
        }
    }
    function global:New-ScheduledTaskPrincipal {
        param([string]$UserId, [string]$LogonType, [string]$RunLevel)
        [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel }
    }
    function global:New-ScheduledTaskSettingsSet {
        param(
            [switch]$Disable,
            [string]$MultipleInstances,
            [switch]$AllowStartIfOnBatteries,
            [switch]$DontStopIfGoingOnBatteries,
            [TimeSpan]$ExecutionTimeLimit,
            [uint32]$RestartCount
        )
        [pscustomobject]@{
            MultipleInstances = $MultipleInstances
            Enabled = $false
            DisallowStartIfOnBatteries = (-not $AllowStartIfOnBatteries)
            StopIfGoingOnBatteries = (-not $DontStopIfGoingOnBatteries)
            AllowHardTerminate = $true
            RestartCount = [uint32]$RestartCount
            ExecutionTimeLimit = 'PT0S'
        }
    }
    foreach ($mockName in @('Register-ScheduledTask', 'Get-ScheduledTask')) {
        $resolvedMock = Get-Command $mockName -CommandType Function -ErrorAction Stop
        if ($resolvedMock.Definition -notmatch 'VIEWFLOW_FIXTURE_MOCK_ONLY') {
            throw "Refusing fixture execution: $mockName did not resolve to the mock"
        }
    }

    Write-Output 'fixture: registering disabled task'
    Register-ExpectedScheduledTask -PreviousTask $legacyTask `
        -OperationId $expectedOperationId `
        -ReadinessReceiptPath $expectedReadinessReceiptPath `
        -ReadinessLockPath $expectedReadinessLockPath `
        -ReadinessCommitRequestPath $expectedReadinessCommitRequestPath `
        -InstallSuccessReceiptPath $expectedInstallSuccessReceiptPath
    if ($null -eq $script:registeredTask) {
        throw 'Registration fixture did not capture the normalized task'
    }
    if ($script:registeredTask.Settings.RestartCount -isnot [uint32] -or
        [uint32]$script:registeredTask.Settings.RestartCount -ne 0) {
        throw 'Normalized RestartCount must be System.UInt32 zero'
    }
    if ($script:registeredTask.Settings.AllowHardTerminate -isnot [bool] -or
        $script:registeredTask.Settings.AllowHardTerminate -ne $true) {
        throw 'Normalized AllowHardTerminate must default to boolean true'
    }
    Assert-ExpectedScheduledTask -Task $script:registeredTask -RequireDisabled
    Write-Output 'fixture: rejecting Disabled task with Enabled=true'
    $script:registeredTask.Settings.Enabled = $true
    Assert-Throws -Name 'Disabled task cannot be enabled' -Action {
        Assert-ExpectedScheduledTask -Task $script:registeredTask -RequireDisabled
    }
    $script:registeredTask.Settings.Enabled = $false
    $script:registeredTask.State = 'Ready'
    $script:registeredTask.Settings.Enabled = $true
    Assert-ExpectedScheduledTask -Task $script:registeredTask -RequireReady
    $script:registeredTask.Triggers = @($legacyLogonTrigger)
    Assert-Throws -Name 'normalized task LogonTrigger is rejected' -Action {
        Assert-ExpectedScheduledTask -Task $script:registeredTask -RequireReady
    }
    $script:registeredTask.Triggers = @()
    Write-Output 'fixture: rejecting Ready task with Enabled=false'
    $script:registeredTask.Settings.Enabled = $false
    Assert-Throws -Name 'Ready task cannot be disabled' -Action {
        Assert-ExpectedScheduledTask -Task $script:registeredTask -RequireReady
    }
    $script:registeredTask.Settings.Enabled = $true

    Write-Output 'fixture: rejecting Running post-register state'
    $script:nextRegisteredState = 'Running'
    Assert-Throws -Name 'post-register Running is rejected' -Action {
        Register-ExpectedScheduledTask -PreviousTask $legacyTask `
            -OperationId $expectedOperationId `
            -ReadinessReceiptPath $expectedReadinessReceiptPath `
            -ReadinessLockPath $expectedReadinessLockPath `
            -ReadinessCommitRequestPath $expectedReadinessCommitRequestPath `
            -InstallSuccessReceiptPath $expectedInstallSuccessReceiptPath
    }

    Write-Output 'fixture: accepting Running post-start state'
    $script:registeredTask.State = 'Running'
    $script:registeredTask.Settings.Enabled = $true
    Assert-ExpectedScheduledTask -Task $script:registeredTask -RequireRunning
    Write-Output 'fixture: rejecting Ready post-start state'
    $script:registeredTask.State = 'Ready'
    Assert-Throws -Name 'post-start Ready is rejected' -Action {
        Assert-ExpectedScheduledTask -Task $script:registeredTask -RequireRunning
    }

    Write-Output 'viewflow scheduled-task PS5.1 fixture passed'
} catch {
    Write-Error $_
    exit 1
}
