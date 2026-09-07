param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'install-viewflow.ps1'),
    [string]$FixturePath,
    [string]$CargoPath = 'cargo'
)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'viewflow-force-release-contract-{0}' -f [Guid]::NewGuid().ToString('N')
)

function Get-InstallerFunctionText {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string]$Name
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

function Copy-ReceiptObject {
    param([Parameter(Mandatory = $true)]$Receipt)
    $Receipt | ConvertTo-Json -Depth 4 | ConvertFrom-Json
}

function Set-TestOwnerOnlyAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = New-Object Security.AccessControl.FileSecurity
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $sid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Assert-ReceiptCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][bool]$ShouldPass,
        [string]$ExpectedErrorPattern,
        [long]$ObservedPid = 0,
        [string]$ObservedProcessStartFileTime
    )
    $path = Join-Path $testRoot "$Name.json"
    [System.IO.File]::WriteAllText(
        $path,
        $Json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    Set-TestOwnerOnlyAcl -Path $path
    $passed = $true
    $failureMessage = $null
    try {
        $null = Assert-ForceReleaseReceipt -Path $path `
            -OperationId $operationId `
            -CandidateSha256 $candidateSha256 `
            -LinuxEvidenceSha256 $linuxEvidenceSha256 `
            -ObservedPid $ObservedPid `
            -ObservedProcessStartFileTime $ObservedProcessStartFileTime
    } catch {
        $passed = $false
        $failureMessage = $_.Exception.Message
    }
    if ($passed -ne $ShouldPass) {
        throw "Receipt case '$Name' expected pass=$ShouldPass, got pass=$passed; $failureMessage"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedErrorPattern) -and
        $failureMessage -notmatch $ExpectedErrorPattern) {
        throw "Receipt case '$Name' returned unexpected error: $failureMessage"
    }
    [pscustomobject]@{
        Case = $Name
        ExpectedPass = $ShouldPass
        PassedExpectation = $true
        ValidationError = $failureMessage
    }
}

function Assert-ReceiptObjectCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Receipt,
        [Parameter(Mandatory = $true)][bool]$ShouldPass,
        [string]$ExpectedErrorPattern
    )
    Assert-ReceiptCase -Name $Name `
        -Json ($Receipt | ConvertTo-Json -Depth 4) `
        -ShouldPass $ShouldPass `
        -ExpectedErrorPattern $ExpectedErrorPattern
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
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
        'Get-BytesSha256Lower',
        'Assert-OwnerOnlyFileSecurity',
        'Read-OwnerOnlyUtf8JsonSnapshot',
        'Test-JsonInteger',
        'Assert-ExactPropertySet',
        'Assert-LowerSha256',
        'Assert-FreshUtcTimestamp',
        'Assert-ForceReleaseReceipt'
    )) {
        Invoke-Expression (Get-InstallerFunctionText -Ast $ast -Name $name)
    }

    $operationId = 'deploy-20260829-abcdef'
    $candidateSha256 = 'a' * 64
    $linuxEvidenceSha256 = 'b' * 64
    $expectedTaskUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $QuiescedMarkerMaxAgeSeconds = 300

    $generatedFixture = $FixturePath
    if ([string]::IsNullOrWhiteSpace($generatedFixture)) {
        $generatedFixture = Join-Path $testRoot 'rust-force-release-receipt.json'
        $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $oldFixture = $env:VIEWFLOW_FORCE_RELEASE_FIXTURE
        $oldCompletedAt = $env:VIEWFLOW_FORCE_RELEASE_COMPLETED_AT_UTC
        try {
            $env:VIEWFLOW_FORCE_RELEASE_FIXTURE = $generatedFixture
            $env:VIEWFLOW_FORCE_RELEASE_COMPLETED_AT_UTC = (
                [DateTimeOffset]::UtcNow.ToString(
                    "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
                    [Globalization.CultureInfo]::InvariantCulture
                )
            )
            & $CargoPath test --locked --offline --manifest-path (Join-Path $repoRoot 'Cargo.toml') `
                -p viewflowd --test force_release_receipt_contract `
                emit_force_release_receipt_fixture -- --ignored --exact
            if ($LASTEXITCODE -ne 0) {
                throw "Rust receipt fixture generator failed with exit code $LASTEXITCODE"
            }
        } finally {
            $env:VIEWFLOW_FORCE_RELEASE_FIXTURE = $oldFixture
            $env:VIEWFLOW_FORCE_RELEASE_COMPLETED_AT_UTC = $oldCompletedAt
        }
    }
    if (-not (Test-Path -LiteralPath $generatedFixture -PathType Leaf)) {
        throw "Rust receipt fixture does not exist: $generatedFixture"
    }

    $validJson = Get-Content -LiteralPath $generatedFixture -Raw
    $base = $validJson | ConvertFrom-Json
    if ([string]$base.tool_user_sid -eq 'S-1-5-21-1') {
        $base.tool_user_sid = $expectedTaskUserSid
        $validJson = $base | ConvertTo-Json -Depth 4
    }
    $results = @()
    $results += Assert-ReceiptCase -Name 'rust-producer-valid' `
        -Json $validJson -ShouldPass $true
    $results += Assert-ReceiptCase -Name 'observed-identity-valid' `
        -Json $validJson -ShouldPass $true `
        -ObservedPid ([long]$base.tool_pid) `
        -ObservedProcessStartFileTime ([string]$base.tool_process_start_filetime)
    $results += Assert-ReceiptCase -Name 'observed-pid-mismatch' `
        -Json $validJson -ShouldPass $false `
        -ExpectedErrorPattern 'does not match the observed tool process identity' `
        -ObservedPid ([long]$base.tool_pid + 1) `
        -ObservedProcessStartFileTime ([string]$base.tool_process_start_filetime)
    $results += Assert-ReceiptCase -Name 'observed-filetime-mismatch' `
        -Json $validJson -ShouldPass $false `
        -ExpectedErrorPattern 'does not match the observed tool process identity' `
        -ObservedPid ([long]$base.tool_pid) `
        -ObservedProcessStartFileTime '1'

    foreach ($field in @($base.PSObject.Properties.Name)) {
        $receipt = Copy-ReceiptObject $base
        $receipt.PSObject.Properties.Remove($field)
        $results += Assert-ReceiptObjectCase -Name "missing-$field" `
            -Receipt $receipt -ShouldPass $false `
            -ExpectedErrorPattern 'unexpected property set'
    }
    $receipt = Copy-ReceiptObject $base
    Add-Member -InputObject $receipt -NotePropertyName unexpected -NotePropertyValue $true
    $results += Assert-ReceiptObjectCase -Name 'extra-field' -Receipt $receipt `
        -ShouldPass $false -ExpectedErrorPattern 'unexpected property set'

    foreach ($case in @(
        @('schema-string', 'schema_version', '3'),
        @('operation-number', 'operation_id', 123),
        @('linux-hash-number', 'linux_frozen_evidence_sha256', 123),
        @('tool-hash-number', 'tool_executable_sha256', 123),
        @('pid-string', 'tool_pid', '42'),
        @('filetime-number', 'tool_process_start_filetime', 100),
        @('session-string', 'tool_session_id', '1'),
        @('sid-number', 'tool_user_sid', 123),
        @('desktop-number', 'input_desktop', 123),
        @('requested-string', 'requested_input_count', '135'),
        @('inserted-string', 'inserted_input_count', '135'),
        @('stable-string', 'verification_stable_ms', '500'),
        @('completed-number', 'completed_at_utc', 123)
    )) {
        $receipt = Copy-ReceiptObject $base
        $receipt.($case[1]) = $case[2]
        $results += Assert-ReceiptObjectCase -Name $case[0] -Receipt $receipt `
            -ShouldPass $false
    }
    foreach ($replacement in @(
        @('schema-double', '"schema_version": 3.0'),
        @('pid-double', '"tool_pid": 42.0'),
        @('session-double', '"tool_session_id": 1.0'),
        @('requested-double', '"requested_input_count": 135.0'),
        @('inserted-double', '"inserted_input_count": 135.0'),
        @('stable-double', '"verification_stable_ms": 500.0')
    )) {
        $field = $replacement[0] -replace '-double$','' -replace '^requested$','requested_input_count' `
            -replace '^inserted$','inserted_input_count' -replace '^stable$','verification_stable_ms'
        if ($field -eq 'schema') { $field = 'schema_version' }
        if ($field -eq 'pid') { $field = 'tool_pid' }
        if ($field -eq 'session') { $field = 'tool_session_id' }
        $pattern = '"{0}"\s*:\s*[0-9]+' -f [regex]::Escape($field)
        $json = [regex]::Replace($validJson, $pattern, $replacement[1], 1)
        $results += Assert-ReceiptCase -Name $replacement[0] -Json $json -ShouldPass $false
    }

    foreach ($case in @(
        @('filetime-u64-zero', '0'),
        @('filetime-leading-zero', '0100'),
        @('filetime-u64-overflow', '18446744073709551616'),
        @('filetime-negative', '-1')
    )) {
        $receipt = Copy-ReceiptObject $base
        $receipt.tool_process_start_filetime = $case[1]
        $results += Assert-ReceiptObjectCase -Name $case[0] -Receipt $receipt `
            -ShouldPass $false
    }

    foreach ($case in @(
        @('wrong-state', 'state', 'viewflow-input-quiesced'),
        @('wrong-operation', 'operation_id', 'deploy-other'),
        @('uppercase-tool-hash', 'tool_executable_sha256', ('A' * 64)),
        @('wrong-tool-hash', 'tool_executable_sha256', ('c' * 64)),
        @('wrong-linux-hash', 'linux_frozen_evidence_sha256', ('c' * 64)),
        @('short-linux-hash', 'linux_frozen_evidence_sha256', ('b' * 63)),
        @('pid-zero', 'tool_pid', 0),
        @('pid-negative', 'tool_pid', -1),
        @('session-zero', 'tool_session_id', 0),
        @('session-two', 'tool_session_id', 2),
        @('wrong-sid', 'tool_user_sid', 'S-1-5-21-2'),
        @('sid-case-change', 'tool_user_sid', 's-1-5-21-1'),
        @('wrong-desktop', 'input_desktop', 'Winlogon'),
        @('desktop-case-change', 'input_desktop', 'default'),
        @('requested-low', 'requested_input_count', 134),
        @('requested-high', 'requested_input_count', 136),
        @('inserted-low', 'inserted_input_count', 134),
        @('inserted-high', 'inserted_input_count', 136),
        @('stable-low', 'verification_stable_ms', 499),
        @('stable-high', 'verification_stable_ms', 501)
    )) {
        $receipt = Copy-ReceiptObject $base
        $receipt.($case[1]) = $case[2]
        $results += Assert-ReceiptObjectCase -Name $case[0] -Receipt $receipt `
            -ShouldPass $false
    }

    foreach ($case in @(
        @('timestamp-no-milliseconds', [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)),
        @('timestamp-offset', [DateTimeOffset]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffzzz', [Globalization.CultureInfo]::InvariantCulture)),
        @('timestamp-stale', [DateTimeOffset]::UtcNow.AddSeconds(-301).ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)),
        @('timestamp-future', [DateTimeOffset]::UtcNow.AddSeconds(31).ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture))
    )) {
        $receipt = Copy-ReceiptObject $base
        $receipt.completed_at_utc = $case[1]
        $results += Assert-ReceiptObjectCase -Name $case[0] -Receipt $receipt `
            -ShouldPass $false
    }

    $results
    Write-Output 'viewflow Rust-to-PS5.1 force-release receipt contract passed'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
