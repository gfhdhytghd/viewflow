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

function Get-AggregateException {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [AggregateException]) {
            return $current
        }
        $current = $current.InnerException
    }
    throw 'Readiness lease close did not throw an AggregateException'
}

function Assert-LeaseCleared {
    param([Parameter(Mandatory = $true)]$Lease)

    if ($null -ne $Lease.ReceiptStream -or $null -ne $Lease.LockStream) {
        throw 'Readiness lease retained a stream after close'
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
Invoke-Expression (Get-InstallerFunctionText -Ast $ast `
    -Name 'Close-AuthenticatedReadinessLease')

if ($null -eq ('ViewflowTests.DisposeProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
namespace ViewflowTests {
    public sealed class DisposeProbe : IDisposable {
        private readonly bool throwOnDispose;
        public int DisposeCount { get; private set; }

        public DisposeProbe(bool throwOnDispose) {
            this.throwOnDispose = throwOnDispose;
        }

        public void Dispose() {
            DisposeCount++;
            if (throwOnDispose) {
                throw new InvalidOperationException("configured dispose failure");
            }
        }
    }
}
'@
}

$receipt = [ViewflowTests.DisposeProbe]::new($true)
$lock = [ViewflowTests.DisposeProbe]::new($false)
$lease = [pscustomobject]@{
    ReceiptStream = $receipt
    LockStream = $lock
}
$observed = $null
try {
    Close-AuthenticatedReadinessLease -Readiness $lease
} catch {
    $observed = $_.Exception
}
if ($null -eq $observed) {
    throw 'Single dispose failure was not reported'
}
$aggregate = Get-AggregateException -Exception $observed
if ($aggregate.InnerExceptions.Count -ne 1 -or
    $aggregate.InnerExceptions[0].Message -cnotmatch 'ReceiptStream') {
    throw 'Single dispose failure did not preserve ReceiptStream context'
}
if ($receipt.DisposeCount -ne 1 -or $lock.DisposeCount -ne 1) {
    throw 'Single dispose failure skipped or repeated a readiness handle'
}
Assert-LeaseCleared -Lease $lease
Close-AuthenticatedReadinessLease -Readiness $lease
if ($receipt.DisposeCount -ne 1 -or $lock.DisposeCount -ne 1) {
    throw 'Repeated readiness close was not idempotent'
}

$receipt = [ViewflowTests.DisposeProbe]::new($true)
$lock = [ViewflowTests.DisposeProbe]::new($true)
$lease = [pscustomobject]@{
    ReceiptStream = $receipt
    LockStream = $lock
}
$observed = $null
try {
    Close-AuthenticatedReadinessLease -Readiness $lease
} catch {
    $observed = $_.Exception
}
if ($null -eq $observed) {
    throw 'Dual dispose failures were not reported'
}
$aggregate = Get-AggregateException -Exception $observed
$messages = @($aggregate.InnerExceptions | ForEach-Object { $_.Message })
if ($aggregate.InnerExceptions.Count -ne 2 -or
    -not ($messages -match 'ReceiptStream') -or
    -not ($messages -match 'LockStream')) {
    throw 'Dual dispose failures were not aggregated with stream context'
}
if ($receipt.DisposeCount -ne 1 -or $lock.DisposeCount -ne 1) {
    throw 'Dual dispose failures skipped or repeated a readiness handle'
}
Assert-LeaseCleared -Lease $lease
Close-AuthenticatedReadinessLease -Readiness $lease
if ($receipt.DisposeCount -ne 1 -or $lock.DisposeCount -ne 1) {
    throw 'Repeated dual-failure close disposed a readiness handle twice'
}

Close-AuthenticatedReadinessLease -Readiness $null
Write-Output 'viewflow readiness lease-close PS5.1 fixture passed'
