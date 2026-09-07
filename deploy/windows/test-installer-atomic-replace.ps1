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
    'Get-FileSha256Lower',
    'Assert-RegularNonReparseFile',
    'Replace-FileAtomically'
)) {
    Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
}

function Write-FixtureBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value
    )
    [IO.File]::WriteAllBytes(
        $Path,
        [Text.UTF8Encoding]::new($false).GetBytes($Value)
    )
}

function Assert-NoAtomicTemporaryFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $leftovers = @(
        Get-ChildItem -LiteralPath $Root -Force -File |
            Where-Object {
                $_.Name -like '*.install.tmp' -or $_.Name -like '*.install.bak'
            }
    )
    if ($leftovers.Count -ne 0) {
        throw 'Atomic replacement left a staged file or backup behind after success'
    }
}

$fixtureRoot = Join-Path $env:TEMP (
    'viewflow-installer-atomic-replace-{0}' -f [Guid]::NewGuid().ToString('N')
)
$source = Join-Path $fixtureRoot 'source.bin'
$destination = Join-Path $fixtureRoot 'destination.bin'

try {
    $null = New-Item -ItemType Directory -Path $fixtureRoot

    # Same-hash destination must remain the same file: no staging/replacement
    # side effect is allowed while the parent directory lease is current.
    Write-FixtureBytes -Path $source -Value 'same-hash-source'
    Write-FixtureBytes -Path $destination -Value 'same-hash-source'
    $sameExpectedSha = Get-FileSha256Lower -Path $source
    $sameBefore = Get-Item -LiteralPath $destination -Force
    $sameTicks = $sameBefore.LastWriteTimeUtc.Ticks
    Replace-FileAtomically -Source $source -Destination $destination `
        -ExpectedSha256 $sameExpectedSha -Name 'same-hash fixture'
    $sameAfter = Get-Item -LiteralPath $destination -Force
    if ((Get-FileSha256Lower -Path $destination) -cne $sameExpectedSha -or
        $sameAfter.LastWriteTimeUtc.Ticks -ne $sameTicks) {
        throw 'Same-hash replacement rewrote the destination'
    }
    Assert-NoAtomicTemporaryFiles -Root $fixtureRoot

    # This uses the real Windows PowerShell 5.1/.NET Framework File.Replace
    # path against an existing NTFS file; it must succeed and remove its backup.
    Write-FixtureBytes -Path $source -Value 'different-hash-new'
    Write-FixtureBytes -Path $destination -Value 'different-hash-old'
    $differentExpectedSha = Get-FileSha256Lower -Path $source
    Replace-FileAtomically -Source $source -Destination $destination `
        -ExpectedSha256 $differentExpectedSha -Name 'different-hash fixture'
    if ((Get-FileSha256Lower -Path $destination) -cne $differentExpectedSha) {
        throw 'Different-hash replacement did not install the expected bytes'
    }
    Assert-NoAtomicTemporaryFiles -Root $fixtureRoot
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}

Write-Output 'viewflow installer atomic replacement PS5.1 fixture passed'
