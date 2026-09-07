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
            $Node -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $Node.Name -ceq $Name
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
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage
    )
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") {
            throw "Unexpected error: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected failure was not raised: $ExpectedMessage"
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

function Get-Sha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace(
                '-',
                ''
            ).ToLowerInvariant()
        } finally {
            $sha256.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Test-ScriptExecutionNode {
    param([Parameter(Mandatory = $true)]$Node)

    $current = $Node.Parent
    while ($null -ne $current) {
        if ($current -is
                [System.Management.Automation.Language.FunctionDefinitionAst] -or
            $current -is
                [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            return $false
        }
        $current = $current.Parent
    }
    return $true
}

function Test-CommandParameterValue {
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $true)][string]$ParameterName,
        [Parameter(Mandatory = $true)][string]$ValueText
    )

    $elements = @($Command.CommandElements)
    for ($index = 1; $index -lt ($elements.Count - 1); $index++) {
        $parameter = $elements[$index]
        if ($parameter -is
                [System.Management.Automation.Language.CommandParameterAst] -and
            $parameter.ParameterName -ceq $ParameterName -and
            $elements[$index + 1].Extent.Text.Trim() -ceq $ValueText) {
            return $true
        }
    }
    return $false
}

function Get-ContainingAssignment {
    param([Parameter(Mandatory = $true)]$Node)

    $current = $Node.Parent
    while ($null -ne $current) {
        if ($current -is
            [System.Management.Automation.Language.AssignmentStatementAst]) {
            return $current
        }
        $current = $current.Parent
    }
    return $null
}

function Test-IfConditionHasHashPath {
    param(
        [Parameter(Mandatory = $true)]$IfStatement,
        [Parameter(Mandatory = $true)][string]$PathText
    )

    $conditionCommands = @()
    foreach ($clause in $IfStatement.Clauses) {
        $conditionCommands += @($clause.Item1.FindAll(
            {
                param($Node)
                $Node -is [System.Management.Automation.Language.CommandAst]
            },
            $true
        ))
    }
    return @($conditionCommands | Where-Object {
        $_.GetCommandName() -ceq 'Get-FileSha256Lower' -and
        (Test-CommandParameterValue -Command $_ -ParameterName 'Path' `
            -ValueText $PathText)
    }).Count -eq 1
}

function Throw-InstallerContractFailure {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerFullPath,
        [Parameter(Mandatory = $true)][string]$InstallerSha256,
        [Parameter(Mandatory = $true)][string]$Message
    )

    throw ("Installer contract failure: {0}; path={1}; sha256={2}" -f @(
        $Message,
        $InstallerFullPath,
        $InstallerSha256
    ))
}

function Get-UniqueInstallerEvent {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Matches,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$InstallerFullPath,
        [Parameter(Mandatory = $true)][string]$InstallerSha256
    )

    if ($Matches.Count -ne 1) {
        Throw-InstallerContractFailure -InstallerFullPath $InstallerFullPath `
            -InstallerSha256 $InstallerSha256 `
            -Message ("anchor '{0}' expected exactly once, found {1}" -f @(
                $Name,
                $Matches.Count
            ))
    }
    return $Matches[0]
}

function Assert-InstallerBootstrapOrderingContract {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedInstaller = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $installerFullPath = [IO.Path]::GetFullPath($resolvedInstaller)
    $installerSha256 = Get-Sha256Lower -Path $installerFullPath
    $contractTokens = $null
    $contractParseErrors = $null
    $contractAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $installerFullPath,
        [ref]$contractTokens,
        [ref]$contractParseErrors
    )
    if ($contractParseErrors.Count -ne 0) {
        Throw-InstallerContractFailure -InstallerFullPath $installerFullPath `
            -InstallerSha256 $installerSha256 `
            -Message ("PowerShell parser errors: {0}" -f
                $contractParseErrors.Count)
    }

    $commands = @($contractAst.FindAll(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.CommandAst]
        },
        $true
    ) | Where-Object { Test-ScriptExecutionNode -Node $_ })
    $assignments = @($contractAst.FindAll(
        {
            param($Node)
            $Node -is
                [System.Management.Automation.Language.AssignmentStatementAst]
        },
        $true
    ) | Where-Object { Test-ScriptExecutionNode -Node $_ })

    $mainAnchor = Get-UniqueInstallerEvent -Name 'rollback-prepared assignment' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($assignments | Where-Object {
            $_.Left.Extent.Text.Trim() -ceq '$rollbackPrepared' -and
            $_.Right.Extent.Text.Trim() -ceq '$true'
        })
    $preparedPublish = Get-UniqueInstallerEvent `
        -Name 'prepared-receipt assignment/command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Write-BootstrapRecoveryPreparedReceipt' -and
            (Get-ContainingAssignment -Node $_).Left.Extent.Text.Trim() -ceq
                '$bootstrapRecoveryPreparedReceipt'
        })
    $rollbackInstall = Get-UniqueInstallerEvent `
        -Name 'pre-permit rollback-tool install' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Replace-FileAtomically' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Source' `
                -ValueText '$sourceRollbackScript') -and
            $_.Extent.StartOffset -gt $mainAnchor.Extent.StartOffset -and
            $_.Extent.StartOffset -lt $preparedPublish.Extent.StartOffset
        })
    $tokenPublish = Get-UniqueInstallerEvent `
        -Name 'rollback authorization assignment/command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'New-RollbackAuthorization' -and
            (Get-ContainingAssignment -Node $_).Left.Extent.Text.Trim() -ceq
                '$token' -and
            $_.Extent.StartOffset -gt $rollbackInstall.Extent.StartOffset -and
            $_.Extent.StartOffset -lt $preparedPublish.Extent.StartOffset
        })
    $manifestPublish = Get-UniqueInstallerEvent `
        -Name 'pre-permit rollback manifest publication' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Write-RollbackManifest' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Path' `
                -ValueText '$RollbackManifestPath') -and
            $_.Extent.StartOffset -gt $tokenPublish.Extent.StartOffset -and
            $_.Extent.StartOffset -lt $preparedPublish.Extent.StartOffset
        })
    $permitGate = Get-UniqueInstallerEvent `
        -Name 'mutation-permit assignment/command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Wait-BootstrapMutationPermit' -and
            (Get-ContainingAssignment -Node $_).Left.Extent.Text.Trim() -ceq
                '$bootstrapMutationPermit'
        })
    $markerConsume = Get-UniqueInstallerEvent `
        -Name 'quiesced-evidence consume assignment/command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Move-ConsumedEvidence' -and
            (Get-ContainingAssignment -Node $_).Left.Extent.Text.Trim() -ceq
                '$consumedEvidence'
        })
    $stableStop = Get-UniqueInstallerEvent -Name 'stable task stop command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Stop-ViewflowTaskAndWait' -and
            $_.CommandElements.Count -eq 1
        })
    $forceRelease = Get-UniqueInstallerEvent `
        -Name 'bootstrap force-release assignment/command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Invoke-BootstrapForceRelease' -and
            (Get-ContainingAssignment -Node $_).Left.Extent.Text.Trim() -ceq
                '$forceReceipt'
        })
    $candidateReplace = Get-UniqueInstallerEvent `
        -Name 'candidate binary replacement command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Replace-FileAtomically' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Source' `
                -ValueText '$CandidatePath') -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Destination' `
                -ValueText '$installedBinary')
        })
    $taskStart = Get-UniqueInstallerEvent `
        -Name 'new task start assignment/command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Start-ViewflowTaskAndWait' -and
            (Get-ContainingAssignment -Node $_).Left.Extent.Text.Trim() -ceq
                '$startResult'
        })

    $orderedEvents = @(
        $mainAnchor, $rollbackInstall, $tokenPublish, $manifestPublish,
        $preparedPublish, $permitGate, $markerConsume, $stableStop,
        $forceRelease, $candidateReplace, $taskStart
    )
    for ($index = 1; $index -lt $orderedEvents.Count; $index++) {
        if ($orderedEvents[$index - 1].Extent.StartOffset -ge
            $orderedEvents[$index].Extent.StartOffset) {
            Throw-InstallerContractFailure -InstallerFullPath $installerFullPath `
                -InstallerSha256 $installerSha256 `
                -Message 'Bootstrap recovery prepare/stop/force/replace/start ordering is unsafe'
        }
    }

    $backupBinaryCopy = Get-UniqueInstallerEvent `
        -Name 'backup binary copy command' -InstallerFullPath $installerFullPath `
        -InstallerSha256 $installerSha256 -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Copy-Item' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'LiteralPath' `
                -ValueText '$installedBinary') -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Destination' `
                -ValueText '$backupBinary')
        })
    $backupBinaryAcl = Get-UniqueInstallerEvent `
        -Name 'backup binary owner-only ACL command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Set-OwnerOnlyFileSecurity' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Path' `
                -ValueText '$backupBinary')
        })
    $backupWrapperCopy = Get-UniqueInstallerEvent `
        -Name 'backup wrapper copy command' -InstallerFullPath $installerFullPath `
        -InstallerSha256 $installerSha256 -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Copy-Item' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'LiteralPath' `
                -ValueText '$installedScript') -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Destination' `
                -ValueText '$backupScript')
        })
    $backupWrapperAcl = Get-UniqueInstallerEvent `
        -Name 'backup wrapper owner-only ACL command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Set-OwnerOnlyFileSecurity' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Path' `
                -ValueText '$backupScript')
        })
    $forceReleaseCopy = Get-UniqueInstallerEvent `
        -Name 'force-release tool backup copy command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Copy-Item' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'LiteralPath' `
                -ValueText '$CandidatePath') -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Destination' `
                -ValueText '$backupForceReleaseTool')
        })
    $forceReleaseAcl = Get-UniqueInstallerEvent `
        -Name 'force-release tool owner-only ACL command' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($commands | Where-Object {
            $_.GetCommandName() -ceq 'Set-OwnerOnlyFileSecurity' -and
            (Test-CommandParameterValue -Command $_ -ParameterName 'Path' `
                -ValueText '$backupForceReleaseTool')
        })
    $backupHashCheck = Get-UniqueInstallerEvent `
        -Name 'prepared backup hashes condition' `
        -InstallerFullPath $installerFullPath -InstallerSha256 $installerSha256 `
        -Matches @($contractAst.FindAll(
            {
                param($Node)
                $Node -is [System.Management.Automation.Language.IfStatementAst]
            },
            $true
        ) | Where-Object {
            (Test-ScriptExecutionNode -Node $_) -and
            (Test-IfConditionHasHashPath -IfStatement $_ `
                -PathText '$backupBinary') -and
            (Test-IfConditionHasHashPath -IfStatement $_ `
                -PathText '$backupScript') -and
            (Test-IfConditionHasHashPath -IfStatement $_ `
                -PathText '$backupForceReleaseTool')
        })
    $backupEvents = @(
        $backupBinaryCopy, $backupBinaryAcl, $backupWrapperCopy,
        $backupWrapperAcl, $forceReleaseCopy, $forceReleaseAcl, $backupHashCheck,
        $permitGate
    )
    for ($index = 1; $index -lt $backupEvents.Count; $index++) {
        if ($backupEvents[$index - 1].Extent.StartOffset -ge
            $backupEvents[$index].Extent.StartOffset) {
            Throw-InstallerContractFailure -InstallerFullPath $installerFullPath `
                -InstallerSha256 $installerSha256 `
                -Message 'Rollback backup copies must become owner-only before hashing and permit validation'
        }
    }

    $dangerousCommands = @($commands | Where-Object {
        $name = $_.GetCommandName()
        $isDangerousName = $name -in @(
            'Stop-ViewflowTaskAndWait',
            'Invoke-BootstrapForceRelease',
            'Register-ExpectedScheduledTask',
            'Start-ViewflowTaskAndWait'
        )
        $isDangerousReplace = $name -ceq 'Replace-FileAtomically' -and (
            (Test-CommandParameterValue -Command $_ -ParameterName 'Source' `
                -ValueText '$CandidatePath') -or
            (Test-CommandParameterValue -Command $_ -ParameterName 'Source' `
                -ValueText '$sourceScript')
        )
        $isDangerousName -or $isDangerousReplace
    })
    if (@($dangerousCommands | Where-Object {
        $_.Extent.StartOffset -gt $rollbackInstall.Extent.StartOffset -and
        $_.Extent.StartOffset -lt $preparedPublish.Extent.StartOffset
    }).Count -ne 0) {
        Throw-InstallerContractFailure -InstallerFullPath $installerFullPath `
            -InstallerSha256 $installerSha256 `
            -Message 'Dangerous live mutation appeared before prepared receipt publication'
    }
    if (@($dangerousCommands | Where-Object {
        $_.Extent.StartOffset -gt $preparedPublish.Extent.StartOffset -and
        $_.Extent.StartOffset -lt $markerConsume.Extent.StartOffset
    }).Count -ne 0) {
        Throw-InstallerContractFailure -InstallerFullPath $installerFullPath `
            -InstallerSha256 $installerSha256 `
            -Message 'Dangerous live mutation appeared before mutation permit validation'
    }

    return [pscustomobject]@{
        Ast = $contractAst
        FullPath = $installerFullPath
        Sha256 = $installerSha256
        MainAnchor = $mainAnchor
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
$installerContract = Assert-InstallerBootstrapOrderingContract -Path $InstallerPath
foreach ($name in @(
    'Initialize-NativeFileIdentityType',
    'Assert-NoReparseAncestors',
    'Assert-RegularNonReparseFile',
    'Open-SafeDirectoryLease',
    'Assert-SafeDirectoryLeaseCurrent',
    'Test-JsonInteger',
    'Assert-LowerSha256',
    'Assert-NewAbsoluteOutputPath',
    'New-OwnerOnlyFileSecurity',
    'Set-OwnerOnlyFileSecurity',
    'Write-OwnerOnlyCreateOnceBytes',
    'Write-OwnerOnlyCreateOnceJson',
    'Get-FileSha256Lower',
    'Assert-OwnerOnlyFileSecurity',
    'Write-BootstrapRecoveryPreparedReceipt'
)) {
    Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
}

$installerText = [IO.File]::ReadAllText($installerContract.FullPath)
if ($installerText -notmatch
    '\$bootstrapMutationPermit = Wait-BootstrapMutationPermit[\s\S]*' +
        '\$bootstrapMutationPermitted = \$true' -or
    $installerText -notmatch
    '-not \(\$AllowV13Bootstrap -and \$bootstrapRecoveryPrepared -and\s*' +
        '\$bootstrapMutationPermitted\)') {
    throw 'Failure containment could stop Viewflow without a validated permit'
}

$mutationPath = Join-Path ([IO.Path]::GetTempPath()) (
    'viewflow-installer-ast-mutation-{0}.ps1' -f
        [Guid]::NewGuid().ToString('N')
)
try {
    $mutationText = $installerText.Remove(
        $installerContract.MainAnchor.Extent.StartOffset,
        $installerContract.MainAnchor.Extent.EndOffset -
            $installerContract.MainAnchor.Extent.StartOffset
    ).Insert(
        $installerContract.MainAnchor.Extent.StartOffset,
        '$rollbackPrepared = $false'
    )
    $mutationText += @'

# Dead contract text must not satisfy the script-level AST assertion.
function Test-DeadBootstrapContractText {
    $rollbackPrepared = $true
}
'@
    [IO.File]::WriteAllText(
        $mutationPath,
        $mutationText,
        [Text.UTF8Encoding]::new($false)
    )
    Assert-Throws -ExpectedMessage (
        "anchor 'rollback-prepared assignment' expected exactly once, " +
            "found 0; path=$mutationPath; sha256="
    ) -Action {
        Assert-InstallerBootstrapOrderingContract -Path $mutationPath
    }
} finally {
    if (Test-Path -LiteralPath $mutationPath) {
        Remove-Item -LiteralPath $mutationPath -Force
    }
}

$expectedTaskUserSid =
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$expectedTaskName = '\Viewflow Peer'
$fixtureRoot = Join-Path $env:TEMP (
    'viewflow-bootstrap-prepared-{0}' -f [Guid]::NewGuid().ToString('N')
)
$installedRoot = Join-Path $fixtureRoot 'installed'
$installedBinary = Join-Path $installedRoot 'viewflowd.exe'
$installedScript = Join-Path $installedRoot 'viewflow-client.ps1'
$lowerSha = 'a' * 64
$operationId = 'bootstrap-recovery-fixture-001'

try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot
    $null = New-Item -ItemType Directory -Path $installedRoot
    [IO.File]::WriteAllBytes($installedBinary, [byte[]](1, 2, 3))
    [IO.File]::WriteAllBytes($installedScript, [byte[]](4, 5, 6))

    $backupSource = Join-Path $fixtureRoot 'backup-source.bin'
    $backupCopy = Join-Path $fixtureRoot 'backup-copy.bin'
    [IO.File]::WriteAllBytes($backupSource, [byte[]](7, 8, 9))
    Copy-Item -LiteralPath $backupSource -Destination $backupCopy
    Set-OwnerOnlyFileSecurity -Path $backupCopy `
        -Name 'Prepared backup copy baseline'
    $inheritedAcl = Get-Acl -LiteralPath $backupCopy
    $inheritedAcl.SetAccessRuleProtection($false, $true)
    Set-Acl -LiteralPath $backupCopy -AclObject $inheritedAcl
    Assert-Throws -ExpectedMessage 'ACL must have inheritance disabled' -Action {
        Assert-OwnerOnlyFileSecurity -Path $backupCopy -Name 'Inherited backup copy'
    }
    Set-OwnerOnlyFileSecurity -Path $backupCopy -Name 'Prepared backup copy'
    Assert-OwnerOnlyFileSecurity -Path $backupCopy -Name 'Prepared backup copy'

    $receiptPath = Join-Path $fixtureRoot 'prepared.json'
    $arguments = @{
        Path = $receiptPath
        OperationId = $operationId
        LinuxEvidenceSha256 = $lowerSha
        BootstrapRequestSha256 = $lowerSha
        MarkerHandoffReceiptPath = (Join-Path $fixtureRoot 'H.json')
        MarkerHandoffReceiptSha256 = $lowerSha
        CandidatePath = (Join-Path $fixtureRoot 'candidate.exe')
        CandidateSha256 = $lowerSha
        WrapperSourcePath = (Join-Path $fixtureRoot 'reviewed-wrapper.ps1')
        WrapperSha256 = $lowerSha
        RollbackScriptPath = (Join-Path $installedRoot 'rollback-viewflow.ps1')
        RollbackScriptSha256 = $lowerSha
        ManifestPath = (Join-Path $fixtureRoot 'rollback-manifest.json')
        ManifestSha256 = $lowerSha
        TokenPath = (Join-Path $fixtureRoot 'rollback-token.json')
        TokenSha256 = $lowerSha
        OldTaskXmlBackupPath = (Join-Path $fixtureRoot 'Viewflow-Peer.xml')
        OldTaskXmlSha256 = $lowerSha
        OldBinarySha256 = $lowerSha
        OldProcessIdentity = [pscustomobject]@{
            ProcessId = 1234
            ProcessStartFileTime = '133700000000000000'
            SessionId = 1
            OwnerSid = $expectedTaskUserSid
        }
        ForceReleaseReceiptPath = (Join-Path $fixtureRoot 'F.json')
        ReadinessReceiptPath = (Join-Path $fixtureRoot 'readiness.json')
        ReadinessLockPath = (Join-Path $fixtureRoot 'readiness.lock')
        ReadinessCommitRequestPath = (Join-Path $fixtureRoot 'commit-request.json')
        InstallSuccessReceiptPath = (Join-Path $fixtureRoot 'W.json')
        RecoveryBundlePath = (Join-Path $fixtureRoot 'recovery-bundle.json')
        LinuxDeactivationProofPath = (Join-Path $fixtureRoot 'linux-proof.json')
        LinuxDeactivationTranscriptPath = (Join-Path $fixtureRoot 'linux.txt')
        RecoveryForceReleaseReceiptPath = (Join-Path $fixtureRoot 'recovery-F.json')
        MutationPermitPath = (Join-Path $fixtureRoot 'permit.json')
        ForceReleaseEnvelopePath = (Join-Path $fixtureRoot 'F-envelope.json')
        LinuxStageReceiptPath = (Join-Path $fixtureRoot 'Ls.json')
        InstallerExitReceiptPath = (Join-Path $fixtureRoot 'exit.json')
    }
    $result = Write-BootstrapRecoveryPreparedReceipt @arguments
    Assert-OwnerOnlyFileSecurity -Path $receiptPath `
        -Name 'Bootstrap recovery prepared receipt fixture'
    if ((Get-FileSha256Lower -Path $receiptPath) -cne $result.Sha256) {
        throw 'Prepared receipt producer returned the wrong SHA-256'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    Assert-ExactKeys -Value $receipt -Context 'Prepared receipt' -Names @(
        'schema_version', 'state', 'rollback_mode', 'operation_id', 'user_sid',
        'bootstrap_request_sha256', 'marker_handoff_receipt',
        'linux_frozen_evidence_sha256', 'candidate', 'wrapper',
        'rollback_script', 'rollback_authorization', 'old_task',
        'old_executable', 'outputs', 'prepared_at_utc'
    )
    Assert-ExactKeys -Value $receipt.outputs -Context 'Prepared outputs' -Names @(
        'mutation_permit_path', 'force_release_receipt_path',
        'force_release_envelope_path', 'linux_stage_receipt_path',
        'readiness_receipt_path',
        'readiness_lock_path', 'readiness_commit_request_path',
        'install_success_receipt_path', 'recovery_bundle_path',
        'linux_deactivation_proof_path',
        'linux_deactivation_transcript_path',
        'recovery_force_release_receipt_path', 'installer_exit_receipt_path'
    )
    if ($receipt.schema_version -ne 1 -or
        $receipt.state -cne 'viewflow-windows-bootstrap-recovery-armed' -or
        $receipt.operation_id -cne $operationId -or
        $receipt.outputs.force_release_receipt_path -cne
            [IO.Path]::GetFullPath($arguments.ForceReleaseReceiptPath) -or
        $receipt.outputs.install_success_receipt_path -cne
            [IO.Path]::GetFullPath($arguments.InstallSuccessReceiptPath) -or
        $receipt.rollback_authorization.manifest_sha256 -cne $lowerSha -or
        $receipt.rollback_authorization.token_sha256 -cne $lowerSha -or
        $receipt.old_executable.process_id -ne 1234) {
        throw 'Prepared receipt lost a schema, F/W, hash, or identity binding'
    }

    $invalidHashArguments = @{} + $arguments
    $invalidHashArguments.Path = Join-Path $fixtureRoot 'invalid-hash.json'
    $invalidHashArguments.CandidateSha256 = 'A' * 64
    Assert-Throws -ExpectedMessage 'Candidate SHA-256 must be a lowercase' `
        -Action { Write-BootstrapRecoveryPreparedReceipt @invalidHashArguments }

    $realParent = Join-Path $fixtureRoot 'real-parent'
    $junctionParent = Join-Path $fixtureRoot 'junction-parent'
    $null = New-Item -ItemType Directory -Path $realParent
    $null = New-Item -ItemType Junction -Path $junctionParent -Target $realParent
    $reparseArguments = @{} + $arguments
    $reparseArguments.Path = Join-Path $junctionParent 'reparse.json'
    Assert-Throws -ExpectedMessage 'must not be a reparse point' `
        -Action { Write-BootstrapRecoveryPreparedReceipt @reparseArguments }

    $acl = Get-Acl -LiteralPath $receiptPath
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $extraRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $usersSid,
        [Security.AccessControl.FileSystemRights]::Read,
        [Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($extraRule)
    Set-Acl -LiteralPath $receiptPath -AclObject $acl
    Assert-Throws -ExpectedMessage 'exactly one explicit access rule' -Action {
        Assert-OwnerOnlyFileSecurity -Path $receiptPath -Name 'Tampered receipt'
    }

    Write-Output 'viewflow bootstrap recovery prepared PS5.1 fixture passed'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
