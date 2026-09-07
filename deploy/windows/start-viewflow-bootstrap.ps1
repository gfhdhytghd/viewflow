param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Worker', 'Status', 'Stop')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$RequestPath
)

$ErrorActionPreference = 'Stop'
$maximumJsonInteger = 9007199254740991L
$deploymentTaskPath = '\'
$expectedPeer = '172.16.105.62:44119'
$expectedServerName = 'viewflow-linux'
$expectedLocalDeviceId = '00000000000000000000000000000001'
$expectedDeviceId = '00000000000000000000000000000002'
$expectedSourceDisplayId = '00000000000000000000000000000101'

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    if ($Value -isnot [pscustomobject]) {
        throw "$Context must be a JSON object"
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if ($actual.Count -ne $expected.Count -or
        (Compare-Object -CaseSensitive -ReferenceObject $expected `
            -DifferenceObject $actual)) {
        throw "$Context has an unexpected property set"
    }
}

function Assert-LowerSha256 {
    param($Value, [string]$Name)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256"
    }
}

function Assert-JsonInteger {
    param($Value, [string]$Name, [long]$Minimum = 0)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or
        [long]$Value -lt $Minimum -or [long]$Value -gt $maximumJsonInteger) {
        throw "$Name must be an exact JSON integer"
    }
}

function Get-Sha256Lower {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Lower {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        ([BitConverter]::ToString($algorithm.ComputeHash($Bytes)) `
            -replace '-', '').ToLowerInvariant()
    } finally {
        $algorithm.Dispose()
    }
}

function Get-TextSha256Lower {
    param([Parameter(Mandatory = $true)][string]$Text)
    Get-BytesSha256Lower -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Assert-AbsoluteCanonicalPath {
    param($Value, [string]$Name)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        -not [IO.Path]::IsPathRooted($Value)) {
        throw "$Name must be an absolute path"
    }
    $canonical = [IO.Path]::GetFullPath($Value)
    if (-not [string]::Equals(
        $canonical, $Value, [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "$Name must already be canonical"
    }
    $canonical
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Name)
    $current = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -Force
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name must not have a reparse-point ancestor: $($current.FullName)"
        }
        $parent = [IO.Directory]::GetParent($current.FullName)
        if ($null -eq $parent) { break }
        $current = Get-Item -LiteralPath $parent.FullName -Force
    }
}

function Assert-RegularPinnedInput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name is not a regular non-reparse file"
    }
    Assert-NoReparsePath -Path $item.Directory.FullName -Name $Name
    if ((Get-Sha256Lower -Path $item.FullName) -cne $Sha256) {
        throw "$Name SHA-256 mismatch"
    }
}

function Convert-IdentityReferenceToSid {
    param([Parameter(Mandatory = $true)]$IdentityReference)
    if ($IdentityReference -is [Security.Principal.SecurityIdentifier]) {
        return $IdentityReference.Value
    }
    $IdentityReference.Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
}

function Set-AndAssert-OperationAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OwnerSid
    )
    $owner = [Security.Principal.SecurityIdentifier]::new($OwnerSid)
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($sid in @($owner, $system)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl

    Assert-OperationAcl -Path $Path -OwnerSid $OwnerSid
}

function Assert-OperationAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$OwnerSid
    )
    $owner = [Security.Principal.SecurityIdentifier]::new($OwnerSid)
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $actual = Get-Acl -LiteralPath $Path
    $actualOwnerIdentity = if ($actual.Owner -match '^S-1-') {
        [Security.Principal.SecurityIdentifier]::new($actual.Owner)
    } else {
        [Security.Principal.NTAccount]::new($actual.Owner)
    }
    $actualOwnerSid = Convert-IdentityReferenceToSid `
        -IdentityReference $actualOwnerIdentity
    if (-not $actual.AreAccessRulesProtected -or
        $actualOwnerSid -cne $owner.Value) {
        throw 'Operation root ACL owner/protection is invalid'
    }
    $rules = @($actual.Access)
    if ($rules.Count -ne 2) {
        throw 'Operation root ACL must contain exactly owner and SYSTEM'
    }
    foreach ($rule in $rules) {
        $ruleSid = Convert-IdentityReferenceToSid `
            -IdentityReference $rule.IdentityReference
        if ($rule.AccessControlType -ne
                [Security.AccessControl.AccessControlType]::Allow -or
            ($ruleSid -cne $owner.Value -and $ruleSid -cne $system.Value) -or
            (($rule.FileSystemRights -band
                [Security.AccessControl.FileSystemRights]::FullControl) -ne
                [Security.AccessControl.FileSystemRights]::FullControl)) {
            throw 'Operation root ACL contains an unexpected rule'
        }
    }
}

function Assert-OwnerSystemFileSecurity {
    param([string]$Path, [string]$OwnerSid, [string]$Name)
    $acl = Get-Acl -LiteralPath $Path
    $ownerIdentity = if ($acl.Owner -match '^S-1-') {
        [Security.Principal.SecurityIdentifier]::new($acl.Owner)
    } else {
        [Security.Principal.NTAccount]::new($acl.Owner)
    }
    if ((Convert-IdentityReferenceToSid $ownerIdentity) -cne $OwnerSid) {
        throw "$Name owner SID is invalid"
    }
    foreach ($rule in @($acl.Access)) {
        $ruleSid = Convert-IdentityReferenceToSid $rule.IdentityReference
        if ($rule.AccessControlType -ne
                [Security.AccessControl.AccessControlType]::Allow -or
            ($ruleSid -cne $OwnerSid -and $ruleSid -cne 'S-1-5-18')) {
            throw "$Name ACL grants an identity other than owner or SYSTEM"
        }
    }
}

function Assert-OwnerOnlyFileSecurity {
    param([string]$Path, [string]$OwnerSid, [string]$Name)
    $acl = Get-Acl -LiteralPath $Path
    $ownerIdentity = if ($acl.Owner -match '^S-1-') {
        [Security.Principal.SecurityIdentifier]::new($acl.Owner)
    } else {
        [Security.Principal.NTAccount]::new($acl.Owner)
    }
    $rules = @($acl.GetAccessRules(
        $true, $false, [Security.Principal.SecurityIdentifier]
    ))
    if ((Convert-IdentityReferenceToSid $ownerIdentity) -cne $OwnerSid -or
        -not $acl.AreAccessRulesProtected -or $rules.Count -ne 1 -or
        $rules[0].IdentityReference.Value -cne $OwnerSid -or
        $rules[0].AccessControlType -ne
            [Security.AccessControl.AccessControlType]::Allow -or
        (($rules[0].FileSystemRights -band
            [Security.AccessControl.FileSystemRights]::FullControl) -ne
            [Security.AccessControl.FileSystemRights]::FullControl)) {
        throw "$Name must be protected owner-only FullControl"
    }
}

function Assert-OwnerOnlyRegularFile {
    param([string]$Path, [string]$OwnerSid, [string]$Name)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Name must be a regular non-reparse file"
    }
    Assert-NoReparsePath -Path $item.Directory.FullName -Name $Name
    Assert-OwnerOnlyFileSecurity -Path $item.FullName -OwnerSid $OwnerSid `
        -Name $Name
}

function Write-OwnerSystemCreateOnceBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $leaf = [IO.Path]::GetFileName([IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $parent (
        '.{0}.{1}.launcher.tmp' -f $leaf, [Guid]::NewGuid().ToString('N')
    )
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $identity = $currentIdentity.User
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    $stream = $null
    try {
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough,
            $acl
        )
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [IO.File]::Move($temporary, $Path)
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Write-OwnerSystemCreateOnceJson {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Compress -Depth 12
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    Write-OwnerSystemCreateOnceBytes -Path $Path -Bytes $bytes
}

function Read-StrictJsonBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 65536) {
        throw 'JSON document size is invalid'
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $text = $encoding.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) {
        throw 'JSON document must not contain a BOM'
    }
    $value = $text | ConvertFrom-Json
    $canonical = ($value | ConvertTo-Json -Compress -Depth 12) + "`n"
    if ($text -cne $canonical) {
        throw 'JSON must be canonical one-line UTF-8 with no duplicate keys'
    }
    [pscustomobject]@{ Bytes = $bytes; Value = $value }
}

function Get-FixedOperationPaths {
    param([string]$OperationRoot)
    [ordered]@{
        launcher_path = (Join-Path $OperationRoot 'start-viewflow-bootstrap.ps1')
        installer_path = (Join-Path $OperationRoot 'install-viewflow.ps1')
        candidate_path = (Join-Path $OperationRoot 'viewflowd.exe')
        wrapper_path = (Join-Path $OperationRoot 'viewflow-client.ps1')
        rollback_script_path = (Join-Path $OperationRoot 'rollback-viewflow.ps1')
        marker_handoff_receipt_path = (Join-Path $OperationRoot 'marker-handoff-receipt.json')
        linux_frozen_evidence_path = (Join-Path $OperationRoot 'linux-v13-frozen-evidence.json')
        prepared_receipt_path = (Join-Path $OperationRoot 'bootstrap-prepared.json')
        mutation_permit_path = (Join-Path $OperationRoot 'mutation-permit.json')
        raw_force_release_receipt_path = (Join-Path $OperationRoot 'raw-force-release.json')
        force_release_envelope_path = (Join-Path $OperationRoot 'force-release-envelope.json')
        linux_stage_receipt_path = (Join-Path $OperationRoot 'linux-stage-receipt.json')
        install_success_receipt_path = (Join-Path $OperationRoot 'windows-install-success.json')
        installer_exit_receipt_path = (Join-Path $OperationRoot 'installer-exit.json')
        readiness_receipt_path = (Join-Path $OperationRoot 'readiness.json')
        readiness_lock_path = (Join-Path $OperationRoot 'readiness.lock')
        readiness_commit_request_path = (Join-Path $OperationRoot 'readiness-commit-request.json')
        rollback_manifest_path = (Join-Path $OperationRoot 'rollback-manifest.json')
        rollback_token_path = (Join-Path $OperationRoot 'rollback-token.json')
        recovery_bundle_path = (Join-Path $OperationRoot 'recovery-bundle.json')
        linux_deactivation_proof_path = (Join-Path $OperationRoot 'linux-deactivation-proof.json')
        linux_deactivation_transcript_path = (Join-Path $OperationRoot 'linux-deactivation-transcript.json')
        recovery_force_release_receipt_path = (Join-Path $OperationRoot 'recovery-force-release.json')
    }
}

function Get-ConsumedLinuxFrozenEvidencePath {
    param(
        [Parameter(Mandatory = $true)][string]$OperationRoot,
        [Parameter(Mandatory = $true)][string]$OperationId
    )
    if ($OperationId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'operation ID is unsafe for consumed Linux frozen evidence'
    }
    Join-Path ([IO.Path]::GetFullPath($OperationRoot)) (
        'linux-v13-frozen-evidence.consumed.{0}.json' -f $OperationId
    )
}

function Assert-BootstrapLinuxFrozenEvidence {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$OperationRoot,
        [Parameter(Mandatory = $true)][string]$OwnerSid,
        [switch]$AllowConsumedEvidence
    )
    $original = [IO.Path]::GetFullPath(
        [string]$Request.linux_frozen_evidence_path
    )
    $expectedConsumed = Get-ConsumedLinuxFrozenEvidencePath `
        -OperationRoot $OperationRoot -OperationId $Request.operation_id
    $consumedCandidates = @(Get-ChildItem -LiteralPath $OperationRoot -Force `
        -Filter 'linux-v13-frozen-evidence.consumed.*.json')
    $originalPresent = Test-Path -LiteralPath $original
    if ($originalPresent) {
        if ($consumedCandidates.Count -ne 0) {
            throw 'Linux frozen evidence original and consumed inputs must not coexist'
        }
        Assert-RegularPinnedInput -Path $original `
            -Sha256 $Request.linux_frozen_evidence_sha256 `
            -Name 'Linux frozen evidence original input'
        Assert-OwnerOnlyRegularFile -Path $original -OwnerSid $OwnerSid `
            -Name 'Linux frozen evidence original input'
        return
    }
    if (-not $AllowConsumedEvidence) {
        throw 'Linux frozen evidence original input is absent'
    }
    if ($consumedCandidates.Count -ne 1) {
        throw 'Linux frozen evidence consumed input must be unique'
    }
    $actualConsumed = [IO.Path]::GetFullPath($consumedCandidates[0].FullName)
    if (-not [string]::Equals(
        $actualConsumed, $expectedConsumed, [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Linux frozen evidence consumed input is not the unique fixed path'
    }
    Assert-RegularPinnedInput -Path $expectedConsumed `
        -Sha256 $Request.linux_frozen_evidence_sha256 `
        -Name 'Linux frozen evidence consumed input'
    Assert-OwnerOnlyRegularFile -Path $expectedConsumed -OwnerSid $OwnerSid `
        -Name 'Linux frozen evidence consumed input'
}

function Assert-BootstrapRequest {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$OperationRoot,
        [Parameter(Mandatory = $true)][string]$CurrentUserSid,
        [Parameter(Mandatory = $true)][int]$CurrentSessionId,
        [switch]$RequireFreshOutputs,
        [switch]$RequireCurrentSession,
        [switch]$AllowConsumedLinuxFrozenEvidence
    )
    $names = @(
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
        'rollback_manifest_path', 'rollback_token_path', 'recovery_bundle_path',
        'linux_deactivation_proof_path', 'linux_deactivation_transcript_path',
        'recovery_force_release_receipt_path', 'created_at_utc'
    )
    Assert-ExactPropertySet -Value $Request -Context 'bootstrap request' -Names $names
    Assert-JsonInteger -Value $Request.schema_version -Name 'schema_version' -Minimum 1
    if ($Request.schema_version -ne 1 -or
        $Request.state -cne 'viewflow-windows-bootstrap-requested') {
        throw 'Bootstrap request schema/state is invalid'
    }
    if ($Request.operation_id -isnot [string] -or
        $Request.operation_id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'operation_id must be 32 lowercase hexadecimal characters'
    }
    if ($Request.user_sid -cne $CurrentUserSid -or
        $Request.expected_session_id -ne 1 -or
        ($RequireCurrentSession -and $CurrentSessionId -ne 1) -or
        $Request.expected_peer -cne $expectedPeer -or
        $Request.expected_server_name -cne $expectedServerName -or
        $Request.expected_local_device_id -cne $expectedLocalDeviceId -or
        $Request.expected_device_id -cne $expectedDeviceId -or
        $Request.expected_source_display_id -cne $expectedSourceDisplayId) {
        throw 'Bootstrap request expected identity/topology is invalid'
    }
    Assert-JsonInteger -Value $Request.expected_session_id `
        -Name 'expected_session_id' -Minimum 1
    if ($Request.created_at_utc -isnot [string]) {
        throw 'created_at_utc must be a string'
    }
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
        $Request.created_at_utc,
        'yyyy-MM-ddTHH:mm:ss.fffZ',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsedTimestamp
    )) {
        throw 'created_at_utc must use canonical UTC millisecond form'
    }

    $fixed = Get-FixedOperationPaths -OperationRoot $OperationRoot
    foreach ($entry in $fixed.GetEnumerator()) {
        $actual = Assert-AbsoluteCanonicalPath -Value $Request.($entry.Key) `
            -Name $entry.Key
        $expected = [IO.Path]::GetFullPath($entry.Value)
        if (-not [string]::Equals(
            $actual, $expected, [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "$($entry.Key) is not the fixed operation path"
        }
    }

    foreach ($prefix in @(
        'launcher', 'installer', 'candidate', 'wrapper', 'rollback_script',
        'marker_handoff_receipt'
    )) {
        $pathName = "${prefix}_path"
        $hashName = "${prefix}_sha256"
        Assert-LowerSha256 -Value $Request.$hashName -Name $hashName
        Assert-RegularPinnedInput -Path $Request.$pathName `
            -Sha256 $Request.$hashName -Name $prefix
    }
    Assert-BootstrapLinuxFrozenEvidence -Request $Request `
        -OperationRoot $OperationRoot -OwnerSid $CurrentUserSid `
        -AllowConsumedEvidence:$AllowConsumedLinuxFrozenEvidence

    $outputNames = @(
        'prepared_receipt_path', 'mutation_permit_path',
        'raw_force_release_receipt_path', 'force_release_envelope_path',
        'linux_stage_receipt_path', 'install_success_receipt_path',
        'installer_exit_receipt_path', 'readiness_receipt_path',
        'readiness_lock_path', 'readiness_commit_request_path',
        'rollback_manifest_path', 'rollback_token_path', 'recovery_bundle_path',
        'linux_deactivation_proof_path', 'linux_deactivation_transcript_path',
        'recovery_force_release_receipt_path'
    )
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in $outputNames) {
        if (-not $seen.Add([IO.Path]::GetFullPath($Request.$name))) {
            throw 'Bootstrap output paths must be pairwise distinct'
        }
        if ($RequireFreshOutputs -and (Test-Path -LiteralPath $Request.$name)) {
            throw "$name must not exist before bootstrap"
        }
    }
}

function Assert-FreshOperationDirectory {
    param($Request, [string]$RequestPath, [string]$OperationRoot)
    $expected = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in @(
        $RequestPath, $Request.launcher_path, $Request.installer_path,
        $Request.candidate_path, $Request.wrapper_path,
        $Request.rollback_script_path, $Request.marker_handoff_receipt_path,
        $Request.linux_frozen_evidence_path
    )) {
        [void]$expected.Add([IO.Path]::GetFullPath([string]$path))
    }
    $actual = @(Get-ChildItem -LiteralPath $OperationRoot -Force)
    if ($actual.Count -ne $expected.Count) {
        throw 'Fresh operation root has an unexpected entry count'
    }
    foreach ($item in $actual) {
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not $expected.Contains([IO.Path]::GetFullPath($item.FullName))) {
            throw "Fresh operation root contains an unexpected entry: $($item.Name)"
        }
    }
}

function Get-ProcessStartFileTimeUtc {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    $Process.StartTime.ToUniversalTime().ToFileTimeUtc().ToString(
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-ProcessOwnerSid {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $instance = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
    if ($null -eq $instance) { throw 'Process owner instance is absent' }
    $owner = Invoke-CimMethod -InputObject $instance -MethodName GetOwnerSid
    if ($owner.ReturnValue -ne 0 -or [string]::IsNullOrWhiteSpace($owner.Sid)) {
        throw 'Process owner SID could not be read'
    }
    [string]$owner.Sid
}

function ConvertTo-WindowsCommandLine {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        if ($argument.Contains('"')) {
            throw 'Command argument contains a forbidden quote'
        }
        if ($argument -match '[\s]') { '"' + $argument + '"' } else { $argument }
    }
    $quoted -join ' '
}

function Get-TaskContract {
    param(
        [string]$LauncherPath,
        [string]$RequestPath,
        [string]$OperationRoot,
        [string]$OperationId
    )
    $powershell = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    )
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', [IO.Path]::GetFullPath($LauncherPath),
        '-Mode', 'Worker', '-RequestPath', [IO.Path]::GetFullPath($RequestPath)
    )
    $argumentLine = ConvertTo-WindowsCommandLine -Arguments $arguments
    $taskName = "Viewflow Deployment $OperationId"
    $canonical = @($powershell, $argumentLine, [IO.Path]::GetFullPath($OperationRoot)) `
        -join "`0"
    [pscustomobject]@{
        TaskPath = $deploymentTaskPath
        TaskName = $taskName
        PowerShell = $powershell
        Arguments = $argumentLine
        WorkingDirectory = [IO.Path]::GetFullPath($OperationRoot)
        CommandSha256 = (Get-TextSha256Lower -Text $canonical)
    }
}

function Register-BootstrapTask {
    param($Contract, [string]$UserName)
    $action = New-ScheduledTaskAction -Execute $Contract.PowerShell `
        -Argument $Contract.Arguments -WorkingDirectory $Contract.WorkingDirectory
    $principal = New-ScheduledTaskPrincipal -UserId $UserName `
        -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 0
    Register-ScheduledTask -TaskPath $Contract.TaskPath `
        -TaskName $Contract.TaskName -Action $action -Principal $principal `
        -Settings $settings -Description 'Viewflow deployment one-shot bootstrap' `
        -ErrorAction Stop | Out-Null
}

function Assert-BootstrapTask {
    param($Task, $Contract, [string]$UserSid)
    if ($null -eq $Task) { throw 'Bootstrap scheduled task is absent' }
    $triggers = @($Task.Triggers | Where-Object { $null -ne $_ })
    $actions = @($Task.Actions | Where-Object { $null -ne $_ })
    if ($triggers.Count -ne 0 -or $actions.Count -ne 1) {
        throw 'Bootstrap task must have no triggers and exactly one action'
    }
    $action = $actions[0]
    if (-not [string]::Equals(
        [IO.Path]::GetFullPath($action.Execute), $Contract.PowerShell,
        [StringComparison]::OrdinalIgnoreCase
    ) -or $action.Arguments -cne $Contract.Arguments -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath($action.WorkingDirectory),
            $Contract.WorkingDirectory,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Bootstrap task action is not the canonical command'
    }
    $principalIdentity = if ($Task.Principal.UserId -match '^S-1-') {
        [Security.Principal.SecurityIdentifier]::new($Task.Principal.UserId)
    } else {
        [Security.Principal.NTAccount]::new($Task.Principal.UserId)
    }
    $principalSid = Convert-IdentityReferenceToSid `
        -IdentityReference $principalIdentity
    if ($principalSid -cne $UserSid -or
        [string]$Task.Principal.LogonType -cne 'Interactive' -or
        [string]$Task.Principal.RunLevel -cne 'Limited') {
        throw 'Bootstrap task principal is invalid'
    }
    if ([string]$Task.Settings.MultipleInstances -cne 'IgnoreNew' -or
        [uint32]$Task.Settings.RestartCount -ne 0 -or
        [string]$Task.Settings.ExecutionTimeLimit -cne 'PT0S' -or
        [bool]$Task.Settings.DisallowStartIfOnBatteries -or
        [bool]$Task.Settings.StopIfGoingOnBatteries) {
        throw 'Bootstrap task retry/instance policy is invalid'
    }
}

function Get-TaskXmlSha256 {
    param($Contract)
    $xml = Export-ScheduledTask -TaskPath $Contract.TaskPath `
        -TaskName $Contract.TaskName -ErrorAction Stop
    Get-TextSha256Lower -Text $xml
}

function Get-InstallerContract {
    param($Request, [string]$RequestPath)
    $powershell = [IO.Path]::GetFullPath(
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    )
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Request.installer_path,
        '-BootstrapRequestPath', [IO.Path]::GetFullPath($RequestPath)
    )
    $line = ConvertTo-WindowsCommandLine -Arguments $arguments
    [pscustomobject]@{
        PowerShell = $powershell
        Arguments = $line
        CommandSha256 = (Get-TextSha256Lower -Text (
            @($powershell, $line) -join "`0"
        ))
    }
}

function Read-AndValidateClaim {
    param(
        [string]$ClaimPath, [string]$OperationId, [string]$RequestSha256,
        $TaskContract, [string]$TaskXmlSha256, $InstallerContract,
        [string]$LauncherPath, [string]$LauncherSha256,
        [string]$ExpectedOwnerSid, [int]$ExpectedSessionId
    )
    $claim = (Read-StrictJsonBytes -Path $ClaimPath).Value
    Assert-ExactPropertySet -Value $claim -Context 'launcher claim' -Names @(
        'schema_version', 'state', 'operation_id', 'pid',
        'process_start_filetime_utc', 'owner_sid', 'session_id',
        'worker_executable_path', 'launcher_path', 'launcher_sha256',
        'request_sha256', 'task_name',
        'task_xml_sha256', 'task_command_sha256',
        'installer_command_sha256', 'claimed_at_utc'
    )
    if ($claim.schema_version -ne 1 -or
        $claim.state -cne 'viewflow-windows-bootstrap-claimed' -or
        $claim.operation_id -cne $OperationId -or
        $claim.request_sha256 -cne $RequestSha256 -or
        $claim.task_name -cne $TaskContract.TaskName -or
        (-not [string]::IsNullOrEmpty($TaskXmlSha256) -and
            $claim.task_xml_sha256 -cne $TaskXmlSha256) -or
        $claim.task_command_sha256 -cne $TaskContract.CommandSha256 -or
        $claim.installer_command_sha256 -cne $InstallerContract.CommandSha256 -or
        $claim.launcher_sha256 -cne $LauncherSha256 -or
        $claim.owner_sid -cne $ExpectedOwnerSid -or
        $claim.session_id -ne $ExpectedSessionId -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$claim.worker_executable_path),
            $TaskContract.PowerShell,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $claim.process_start_filetime_utc -isnot [string] -or
        $claim.process_start_filetime_utc -cnotmatch '^[0-9]{10,20}$' -or
        -not [string]::Equals(
            $claim.launcher_path, $LauncherPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Launcher claim binding is invalid'
    }
    Assert-LowerSha256 -Value $claim.task_xml_sha256 -Name 'claim.task_xml_sha256'
    Assert-JsonInteger -Value $claim.schema_version `
        -Name 'claim.schema_version' -Minimum 1
    Assert-JsonInteger -Value $claim.pid -Name 'claim.pid' -Minimum 1
    Assert-JsonInteger -Value $claim.session_id -Name 'claim.session_id' -Minimum 1
    $claim
}

function Test-ClaimProcessLive {
    param($Claim)
    $process = Get-Process -Id ([int]$Claim.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        (Get-ProcessStartFileTimeUtc -Process $process) -ceq
            [string]$Claim.process_start_filetime_utc -and
        [int]$process.SessionId -eq [int]$Claim.session_id -and
        [string]::Equals(
            [IO.Path]::GetFullPath($process.Path),
            [IO.Path]::GetFullPath([string]$Claim.worker_executable_path),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        (Get-ProcessOwnerSid -ProcessId ([int]$Claim.pid)) -ceq
            [string]$Claim.owner_sid
    } catch {
        $false
    }
}

function Get-ExactProcessIdentity {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $instance = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
    if ($null -eq $instance) { throw 'Process CIM identity is absent' }
    [pscustomobject]@{
        ProcessId = [int]$ProcessId
        ParentProcessId = [int]$instance.ParentProcessId
        ProcessStartFileTimeUtc = Get-ProcessStartFileTimeUtc -Process $process
        OwnerSid = Get-ProcessOwnerSid -ProcessId $ProcessId
        SessionId = [int]$process.SessionId
        ExecutablePath = [IO.Path]::GetFullPath($process.Path)
    }
}

function Assert-ExactProcessIdentityCurrent {
    param($Identity, [string]$Name)
    $current = Get-ExactProcessIdentity -ProcessId ([int]$Identity.ProcessId)
    if ($current.ParentProcessId -ne [int]$Identity.ParentProcessId -or
        $current.ProcessStartFileTimeUtc -cne
            [string]$Identity.ProcessStartFileTimeUtc -or
        $current.OwnerSid -cne [string]$Identity.OwnerSid -or
        $current.SessionId -ne [int]$Identity.SessionId -or
        -not [string]::Equals(
            $current.ExecutablePath, [string]$Identity.ExecutablePath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "$Name process identity changed"
    }
    $current
}

function Get-ClaimDescendantProcesses {
    param($Claim, [string[]]$AllowedExecutablePaths)
    $allowed = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $AllowedExecutablePaths) {
        [void]$allowed.Add([IO.Path]::GetFullPath($path))
    }
    $instances = @(Get-CimInstance Win32_Process)
    $parents = [Collections.Generic.HashSet[int]]::new()
    [void]$parents.Add([int]$Claim.pid)
    $result = New-Object 'System.Collections.Generic.List[object]'
    do {
        $added = $false
        foreach ($instance in $instances) {
            $pidValue = [int]$instance.ProcessId
            if ($parents.Contains([int]$instance.ParentProcessId) -and
                -not $parents.Contains($pidValue)) {
                $identity = Get-ExactProcessIdentity -ProcessId $pidValue
                if ($identity.OwnerSid -cne [string]$Claim.owner_sid -or
                    $identity.SessionId -ne [int]$Claim.session_id -or
                    -not $allowed.Contains($identity.ExecutablePath)) {
                    throw 'Claim descendant process identity is outside the fixed tree'
                }
                [void]$parents.Add($pidValue)
                $result.Add($identity)
                $added = $true
            }
        }
    } while ($added)
    $result.ToArray()
}

function Read-InstallerProcessReceipt {
    param(
        [string]$Path, [string]$OperationId, [string]$RequestSha256,
        [string]$ClaimSha256, $InstallerContract, $Claim
    )
    $receipt = (Read-StrictJsonBytes -Path $Path).Value
    Assert-ExactPropertySet -Value $receipt -Context 'installer process receipt' `
        -Names @(
            'schema_version', 'state', 'operation_id', 'pid', 'parent_pid',
            'process_start_filetime_utc', 'owner_sid', 'session_id',
            'executable_path', 'request_sha256', 'claim_sha256',
            'installer_command_sha256', 'started_at_utc'
        )
    if ($receipt.schema_version -ne 1 -or
        $receipt.state -cne 'viewflow-windows-bootstrap-installer-running' -or
        $receipt.operation_id -cne $OperationId -or
        $receipt.parent_pid -ne [int]$Claim.pid -or
        $receipt.owner_sid -cne [string]$Claim.owner_sid -or
        $receipt.session_id -ne [int]$Claim.session_id -or
        $receipt.request_sha256 -cne $RequestSha256 -or
        $receipt.claim_sha256 -cne $ClaimSha256 -or
        $receipt.installer_command_sha256 -cne
            $InstallerContract.CommandSha256 -or
        -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$receipt.executable_path),
            $InstallerContract.PowerShell,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Installer process receipt binding is invalid'
    }
    Assert-JsonInteger $receipt.schema_version 'installer process schema_version' 1
    Assert-JsonInteger $receipt.pid 'installer process pid' 1
    Assert-JsonInteger $receipt.parent_pid 'installer parent pid' 1
    Assert-JsonInteger $receipt.session_id 'installer session id' 1
    $receipt
}

function Read-StopEvidence {
    param(
        [string]$Path, [string]$OperationId, [string]$RequestSha256,
        [string]$ClaimSha256, $Claim
    )
    $evidence = (Read-StrictJsonBytes -Path $Path).Value
    Assert-ExactPropertySet -Value $evidence -Context 'launcher stop evidence' `
        -Names @(
            'schema_version', 'state', 'operation_id', 'request_sha256',
            'claim_sha256', 'task_name', 'task_xml_sha256', 'worker_pid',
            'worker_process_start_filetime_utc', 'installer_process_count',
            'task_state', 'stopped_at_utc'
        )
    if ($evidence.schema_version -ne 1 -or
        $evidence.state -cne 'viewflow-windows-bootstrap-stopped' -or
        $evidence.operation_id -cne $OperationId -or
        $evidence.request_sha256 -cne $RequestSha256 -or
        $evidence.claim_sha256 -cne $ClaimSha256 -or
        $evidence.task_name -cne [string]$Claim.task_name -or
        $evidence.task_xml_sha256 -cne [string]$Claim.task_xml_sha256 -or
        $evidence.worker_pid -ne [int]$Claim.pid -or
        $evidence.worker_process_start_filetime_utc -cne
            [string]$Claim.process_start_filetime_utc -or
        $evidence.installer_process_count -ne 0 -or
        $evidence.task_state -cne 'Disabled') {
        throw 'Launcher stop evidence binding is invalid'
    }
    Assert-JsonInteger $evidence.schema_version 'stop schema_version' 1
    Assert-JsonInteger $evidence.worker_pid 'stop worker_pid' 1
    Assert-JsonInteger $evidence.installer_process_count `
        'stop installer_process_count' 0
    $evidence
}

function Read-TerminalReceipt {
    param(
        [string]$Path, [string]$OperationId, [string]$RequestSha256,
        [string]$ClaimSha256, [string]$InstallerCommandSha256
    )
    $terminal = (Read-StrictJsonBytes -Path $Path).Value
    Assert-ExactPropertySet -Value $terminal -Context 'installer exit receipt' -Names @(
        'schema_version', 'state', 'operation_id', 'exit_code',
        'request_sha256', 'claim_sha256', 'installer_command_sha256',
        'completed_at_utc'
    )
    if ($terminal.schema_version -ne 1 -or
        $terminal.operation_id -cne $OperationId -or
        $terminal.request_sha256 -cne $RequestSha256 -or
        $terminal.claim_sha256 -cne $ClaimSha256 -or
        $terminal.installer_command_sha256 -cne $InstallerCommandSha256 -or
        $terminal.state -cnotin @(
            'viewflow-windows-bootstrap-succeeded',
            'viewflow-windows-bootstrap-failed'
        )) {
        throw 'Installer exit receipt binding is invalid'
    }
    Assert-JsonInteger -Value $terminal.exit_code -Name 'exit_code' -Minimum 0
    if (($terminal.state -ceq 'viewflow-windows-bootstrap-succeeded' -and
            $terminal.exit_code -ne 0) -or
        ($terminal.state -ceq 'viewflow-windows-bootstrap-failed' -and
            $terminal.exit_code -eq 0)) {
        throw 'Installer exit receipt state/exit_code union is invalid'
    }
    $terminal
}

function Invoke-Worker {
    param(
        $Request, [string]$RequestPath, [byte[]]$RequestBytes,
        [string]$OperationRoot, [string]$CurrentSid,
        [int]$CurrentSessionId
    )
    $workerRequestLease = [IO.File]::Open(
        $RequestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
    if ((Get-Sha256Lower -Path $RequestPath) -cne
        (Get-BytesSha256Lower -Bytes $RequestBytes)) {
        throw 'Bootstrap request changed before the worker claim'
    }
    Assert-BootstrapRequest -Request $Request -OperationRoot $OperationRoot `
        -CurrentUserSid $CurrentSid -CurrentSessionId $CurrentSessionId `
        -RequireFreshOutputs -RequireCurrentSession
    $requestSha = Get-BytesSha256Lower -Bytes $RequestBytes
    $taskContract = Get-TaskContract -LauncherPath $Request.launcher_path `
        -RequestPath $RequestPath -OperationRoot $OperationRoot `
        -OperationId $Request.operation_id
    $task = Get-ScheduledTask -TaskPath $taskContract.TaskPath `
        -TaskName $taskContract.TaskName -ErrorAction Stop
    Assert-BootstrapTask -Task $task -Contract $taskContract -UserSid $CurrentSid
    $taskXmlSha = Get-TaskXmlSha256 -Contract $taskContract
    $installerContract = Get-InstallerContract -Request $Request `
        -RequestPath $RequestPath
    $claimPath = Join-Path $OperationRoot 'launcher-claim.json'
    $claim = [ordered]@{
        schema_version = 1
        state = 'viewflow-windows-bootstrap-claimed'
        operation_id = $Request.operation_id
        pid = [int]$PID
        process_start_filetime_utc = Get-ProcessStartFileTimeUtc `
            -Process (Get-Process -Id $PID)
        owner_sid = $CurrentSid
        session_id = $CurrentSessionId
        worker_executable_path = $taskContract.PowerShell
        launcher_path = [IO.Path]::GetFullPath($Request.launcher_path)
        launcher_sha256 = $Request.launcher_sha256
        request_sha256 = $requestSha
        task_name = $taskContract.TaskName
        task_xml_sha256 = $taskXmlSha
        task_command_sha256 = $taskContract.CommandSha256
        installer_command_sha256 = $installerContract.CommandSha256
        claimed_at_utc = [DateTimeOffset]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture
        )
    }
    Write-OwnerSystemCreateOnceJson -Path $claimPath -Value $claim
    $claimSha = Get-Sha256Lower -Path $claimPath

    $stdoutPath = Join-Path $OperationRoot 'installer.stdout.log'
    $stderrPath = Join-Path $OperationRoot 'installer.stderr.log'
    $exitCode = 1
    try {
        # The exclusive claim is the at-most-once boundary. Every
        # installer-owned path is checked again only after that boundary and
        # before the child starts. Any post-claim failure still publishes one
        # terminal failure receipt; it never permits another child attempt.
        Assert-BootstrapRequest -Request $Request -OperationRoot $OperationRoot `
            -CurrentUserSid $CurrentSid -CurrentSessionId $CurrentSessionId `
            -RequireFreshOutputs -RequireCurrentSession
        if ((Test-Path -LiteralPath $stdoutPath) -or
            (Test-Path -LiteralPath $stderrPath)) {
            throw 'Installer log output already exists after the claim'
        }
        $child = Start-Process -FilePath $installerContract.PowerShell `
            -ArgumentList $installerContract.Arguments `
            -WorkingDirectory $OperationRoot -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        try {
            $childIdentity = Get-ExactProcessIdentity -ProcessId ([int]$child.Id)
        } catch {
            try { $child.Kill(); $child.WaitForExit() } catch { }
            throw
        }
        if ($childIdentity.ParentProcessId -ne $PID -or
            $childIdentity.OwnerSid -cne $CurrentSid -or
            $childIdentity.SessionId -ne $CurrentSessionId -or
            -not [string]::Equals(
                $childIdentity.ExecutablePath, $installerContract.PowerShell,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            try { $child.Kill(); $child.WaitForExit() } catch { }
            throw 'Installer child process identity is invalid'
        }
        $processReceiptPath = Join-Path $OperationRoot `
            'launcher-installer-process.json'
        Write-OwnerSystemCreateOnceJson -Path $processReceiptPath -Value `
            ([ordered]@{
                schema_version = 1
                state = 'viewflow-windows-bootstrap-installer-running'
                operation_id = $Request.operation_id
                pid = $childIdentity.ProcessId
                parent_pid = $childIdentity.ParentProcessId
                process_start_filetime_utc =
                    $childIdentity.ProcessStartFileTimeUtc
                owner_sid = $childIdentity.OwnerSid
                session_id = $childIdentity.SessionId
                executable_path = $childIdentity.ExecutablePath
                request_sha256 = $requestSha
                claim_sha256 = $claimSha
                installer_command_sha256 = $installerContract.CommandSha256
                started_at_utc = [DateTimeOffset]::UtcNow.ToString(
                    'yyyy-MM-ddTHH:mm:ss.fffZ',
                    [Globalization.CultureInfo]::InvariantCulture
                )
            })
        $child.WaitForExit()
        $exitCode = [int]$child.ExitCode
        if ($exitCode -eq 0) {
            # Windows PowerShell 5.1 can return process exit code zero for an
            # uncaught terminating error in a -File script. A successful
            # bootstrap installer cannot exit before the daemon-authored W
            # receipt exists, so bind terminal success to that durable output.
            Assert-OwnerOnlyRegularFile `
                -Path $Request.install_success_receipt_path `
                -OwnerSid $CurrentSid -Name 'Windows install-success receipt'
        }
    } catch {
        $exitCode = 1
    }
    $terminal = [ordered]@{
        schema_version = 1
        state = if ($exitCode -eq 0) {
            'viewflow-windows-bootstrap-succeeded'
        } else {
            'viewflow-windows-bootstrap-failed'
        }
        operation_id = $Request.operation_id
        exit_code = $exitCode
        request_sha256 = $requestSha
        claim_sha256 = $claimSha
        installer_command_sha256 = $installerContract.CommandSha256
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture
        )
    }
    Write-OwnerSystemCreateOnceJson -Path $Request.installer_exit_receipt_path `
        -Value $terminal
    exit $exitCode
    } finally {
        $workerRequestLease.Dispose()
    }
}

function Get-LaunchStatus {
    param(
        $Request, [string]$RequestPath, [byte[]]$RequestBytes,
        [string]$OperationRoot, [string]$CurrentSid
    )
    $requestSha = Get-BytesSha256Lower -Bytes $RequestBytes
    $taskContract = Get-TaskContract -LauncherPath $Request.launcher_path `
        -RequestPath $RequestPath -OperationRoot $OperationRoot `
        -OperationId $Request.operation_id
    $installerContract = Get-InstallerContract -Request $Request `
        -RequestPath $RequestPath
    $claimPath = Join-Path $OperationRoot 'launcher-claim.json'
    $task = Get-ScheduledTask -TaskPath $taskContract.TaskPath `
        -TaskName $taskContract.TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task -and -not (Test-Path -LiteralPath $claimPath)) {
        if (Test-Path -LiteralPath $Request.installer_exit_receipt_path) {
            throw 'uncertain: terminal receipt exists without its launcher claim'
        }
        return [pscustomobject]@{ State = 'absent'; TaskContract = $taskContract }
    }
    $taskXmlSha = $null
    if ($null -ne $task) {
        Assert-BootstrapTask -Task $task -Contract $taskContract -UserSid $CurrentSid
        $taskXmlSha = Get-TaskXmlSha256 -Contract $taskContract
    }
    if (-not (Test-Path -LiteralPath $claimPath)) {
        if ([string]$task.State -ceq 'Running') {
            return [pscustomobject]@{
                State = 'starting'; TaskContract = $taskContract
            }
        }
        throw 'uncertain: bootstrap task exists without a claim or terminal receipt'
    }
    Assert-OwnerOnlyRegularFile -Path $claimPath -OwnerSid $CurrentSid `
        -Name 'launcher claim'
    $stopPath = Join-Path $OperationRoot 'launcher-stop-evidence.json'
    if (Test-Path -LiteralPath $stopPath) {
        if ($null -eq $task -or [string]$task.State -cne 'Disabled') {
            throw 'Launcher stop evidence requires the exact Disabled task'
        }
        $stoppedClaim = Read-AndValidateClaim -ClaimPath $claimPath `
            -OperationId $Request.operation_id -RequestSha256 $requestSha `
            -TaskContract $taskContract -TaskXmlSha256 '' `
            -InstallerContract $installerContract `
            -LauncherPath $Request.launcher_path `
            -LauncherSha256 $Request.launcher_sha256 `
            -ExpectedOwnerSid $CurrentSid -ExpectedSessionId 1
        $stoppedClaimSha = Get-Sha256Lower $claimPath
        Assert-OwnerOnlyRegularFile -Path $stopPath -OwnerSid $CurrentSid `
            -Name 'launcher stop evidence'
        $stopEvidence = Read-StopEvidence -Path $stopPath `
            -OperationId $Request.operation_id -RequestSha256 $requestSha `
            -ClaimSha256 $stoppedClaimSha -Claim $stoppedClaim
        return [pscustomobject]@{
            State = 'stopped'; TaskContract = $taskContract
            StopEvidence = $stopEvidence
        }
    }
    $claim = Read-AndValidateClaim -ClaimPath $claimPath `
        -OperationId $Request.operation_id -RequestSha256 $requestSha `
        -TaskContract $taskContract -TaskXmlSha256 $taskXmlSha `
        -InstallerContract $installerContract -LauncherPath $Request.launcher_path `
        -LauncherSha256 $Request.launcher_sha256 `
        -ExpectedOwnerSid $CurrentSid -ExpectedSessionId 1
    $claimSha = Get-Sha256Lower -Path $claimPath
    if (Test-Path -LiteralPath $Request.installer_exit_receipt_path) {
        Assert-OwnerOnlyRegularFile `
            -Path $Request.installer_exit_receipt_path `
            -OwnerSid $CurrentSid -Name 'installer exit receipt'
        $terminal = Read-TerminalReceipt `
            -Path $Request.installer_exit_receipt_path `
            -OperationId $Request.operation_id -RequestSha256 $requestSha `
            -ClaimSha256 $claimSha `
            -InstallerCommandSha256 $installerContract.CommandSha256
        return [pscustomobject]@{
            State = 'terminal'; TaskContract = $taskContract; Terminal = $terminal
        }
    }
    if (Test-ClaimProcessLive -Claim $claim) {
        return [pscustomobject]@{
            State = 'running'; TaskContract = $taskContract; Claim = $claim
        }
    }
    throw 'uncertain: claimed launcher is dead and no terminal receipt exists'
}

function Invoke-StopBootstrap {
    param(
        $Request, [string]$RequestPath, [byte[]]$RequestBytes,
        [string]$OperationRoot, [string]$CurrentSid
    )
    $requestSha = Get-BytesSha256Lower -Bytes $RequestBytes
    $taskContract = Get-TaskContract -LauncherPath $Request.launcher_path `
        -RequestPath $RequestPath -OperationRoot $OperationRoot `
        -OperationId $Request.operation_id
    $installerContract = Get-InstallerContract -Request $Request `
        -RequestPath $RequestPath
    $claimPath = Join-Path $OperationRoot 'launcher-claim.json'
    if (-not (Test-Path -LiteralPath $claimPath)) {
        throw 'uncertain: Stop requires the durable launcher claim'
    }
    Assert-OwnerOnlyRegularFile -Path $claimPath -OwnerSid $CurrentSid `
        -Name 'launcher claim'
    $claim = Read-AndValidateClaim -ClaimPath $claimPath `
        -OperationId $Request.operation_id -RequestSha256 $requestSha `
        -TaskContract $taskContract -TaskXmlSha256 '' `
        -InstallerContract $installerContract -LauncherPath $Request.launcher_path `
        -LauncherSha256 $Request.launcher_sha256 `
        -ExpectedOwnerSid $CurrentSid -ExpectedSessionId 1
    $claimSha = Get-Sha256Lower $claimPath
    $stopPath = Join-Path $OperationRoot 'launcher-stop-evidence.json'
    if (Test-Path -LiteralPath $stopPath) {
        Assert-OwnerOnlyRegularFile -Path $stopPath -OwnerSid $CurrentSid `
            -Name 'launcher stop evidence'
        return Read-StopEvidence -Path $stopPath `
            -OperationId $Request.operation_id -RequestSha256 $requestSha `
            -ClaimSha256 $claimSha -Claim $claim
    }

    $task = Get-ScheduledTask -TaskPath $taskContract.TaskPath `
        -TaskName $taskContract.TaskName -ErrorAction Stop
    Assert-BootstrapTask -Task $task -Contract $taskContract -UserSid $CurrentSid
    $taskXmlSha = Get-TaskXmlSha256 -Contract $taskContract
    if ($taskXmlSha -cne [string]$claim.task_xml_sha256) {
        throw 'uncertain: Stop task XML differs from the claimed task'
    }

    $terminalPresent = Test-Path -LiteralPath $Request.installer_exit_receipt_path
    if (-not $terminalPresent -and -not (Test-ClaimProcessLive -Claim $claim)) {
        throw 'uncertain: claimed launcher is dead without terminal exit'
    }
    if ($terminalPresent) {
        Assert-OwnerOnlyRegularFile -Path $Request.installer_exit_receipt_path `
            -OwnerSid $CurrentSid -Name 'installer exit receipt'
        $null = Read-TerminalReceipt -Path $Request.installer_exit_receipt_path `
            -OperationId $Request.operation_id -RequestSha256 $requestSha `
            -ClaimSha256 $claimSha `
            -InstallerCommandSha256 $installerContract.CommandSha256
    }

    $requestLease = [IO.File]::Open(
        $RequestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    $claimLease = [IO.File]::Open(
        $claimPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ((Get-Sha256Lower $RequestPath) -cne $requestSha -or
            (Get-Sha256Lower $claimPath) -cne $claimSha) {
            throw 'Stop request or claim changed after lease acquisition'
        }
        $allowedExecutables = @(
            $taskContract.PowerShell,
            [IO.Path]::GetFullPath([string]$Request.candidate_path),
            # Redirected Windows PowerShell streams may create conhost.exe.
            # The descendant walker still binds exact PID/start/parent/SID/session.
            [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\conhost.exe'))
        )
        $descendants = @(Get-ClaimDescendantProcesses -Claim $claim `
            -AllowedExecutablePaths $allowedExecutables)
        $processReceiptPath = Join-Path $OperationRoot `
            'launcher-installer-process.json'
        if (Test-Path -LiteralPath $processReceiptPath) {
            Assert-OwnerOnlyRegularFile -Path $processReceiptPath `
                -OwnerSid $CurrentSid -Name 'installer process receipt'
            $processReceipt = Read-InstallerProcessReceipt `
                -Path $processReceiptPath -OperationId $Request.operation_id `
                -RequestSha256 $requestSha -ClaimSha256 $claimSha `
                -InstallerContract $installerContract -Claim $claim
            $matchingChild = @($descendants | Where-Object {
                $_.ProcessId -eq [int]$processReceipt.pid -and
                $_.ProcessStartFileTimeUtc -ceq
                    [string]$processReceipt.process_start_filetime_utc
            })
            if ($matchingChild.Count -eq 0 -and
                (Get-Process -Id ([int]$processReceipt.pid) `
                    -ErrorAction SilentlyContinue)) {
                throw 'uncertain: installer receipt names a non-descendant process'
            }
        }

        $taskWasRunning = [string]$task.State -ceq 'Running'
        Disable-ScheduledTask -TaskPath $taskContract.TaskPath `
            -TaskName $taskContract.TaskName -ErrorAction Stop | Out-Null
        if ($taskWasRunning) {
            Stop-ScheduledTask -TaskPath $taskContract.TaskPath `
                -TaskName $taskContract.TaskName -ErrorAction Stop
        }

        $afterStopDescendants = @(Get-ClaimDescendantProcesses -Claim $claim `
            -AllowedExecutablePaths $allowedExecutables)
        $allDescendants = @($descendants + $afterStopDescendants)
        for ($index = $allDescendants.Count - 1; $index -ge 0; $index--) {
            $candidate = $allDescendants[$index]
            if (Get-Process -Id ([int]$candidate.ProcessId) `
                -ErrorAction SilentlyContinue) {
                $null = Assert-ExactProcessIdentityCurrent -Identity $candidate `
                    -Name 'installer descendant'
                Stop-Process -Id ([int]$candidate.ProcessId) -Force `
                    -ErrorAction Stop
            }
        }
        if (Test-ClaimProcessLive -Claim $claim) {
            $workerIdentity = Get-ExactProcessIdentity -ProcessId ([int]$claim.pid)
            if ($workerIdentity.ProcessStartFileTimeUtc -cne
                    [string]$claim.process_start_filetime_utc -or
                $workerIdentity.OwnerSid -cne [string]$claim.owner_sid -or
                $workerIdentity.SessionId -ne [int]$claim.session_id -or
                -not [string]::Equals(
                    $workerIdentity.ExecutablePath,
                    [string]$claim.worker_executable_path,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw 'uncertain: worker identity changed before termination'
            }
            Stop-Process -Id ([int]$claim.pid) -Force -ErrorAction Stop
        }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        do {
            $workerLive = Test-ClaimProcessLive -Claim $claim
            $remaining = @(Get-ClaimDescendantProcesses -Claim $claim `
                -AllowedExecutablePaths $allowedExecutables)
            if (-not $workerLive -and $remaining.Count -eq 0) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        if ($workerLive -or $remaining.Count -ne 0) {
            throw 'uncertain: exact bootstrap process tree did not stop'
        }
        $finalTask = Get-ScheduledTask -TaskPath $taskContract.TaskPath `
            -TaskName $taskContract.TaskName -ErrorAction Stop
        if ([string]$finalTask.State -cne 'Disabled') {
            throw 'uncertain: bootstrap task is not Disabled after Stop'
        }
        $evidence = [ordered]@{
            schema_version = 1
            state = 'viewflow-windows-bootstrap-stopped'
            operation_id = $Request.operation_id
            request_sha256 = $requestSha
            claim_sha256 = $claimSha
            task_name = $taskContract.TaskName
            task_xml_sha256 = [string]$claim.task_xml_sha256
            worker_pid = [int]$claim.pid
            worker_process_start_filetime_utc =
                [string]$claim.process_start_filetime_utc
            installer_process_count = 0
            task_state = 'Disabled'
            stopped_at_utc = [DateTimeOffset]::UtcNow.ToString(
                'yyyy-MM-ddTHH:mm:ss.fffZ',
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
        Write-OwnerSystemCreateOnceJson -Path $stopPath -Value $evidence
        Read-StopEvidence -Path $stopPath -OperationId $Request.operation_id `
            -RequestSha256 $requestSha -ClaimSha256 $claimSha -Claim $claim
    } finally {
        $claimLease.Dispose()
        $requestLease.Dispose()
    }
}

$requestCanonical = Assert-AbsoluteCanonicalPath -Value $RequestPath `
    -Name 'RequestPath'
$deploymentRoot = [IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA 'Viewflow\Deployments')
)
$operationRoot = [IO.Path]::GetFullPath(
    [IO.Path]::GetDirectoryName($requestCanonical)
)
$operationId = [IO.Path]::GetFileName($operationRoot)
if ($operationId -cnotmatch '^[0-9a-f]{32}$') {
    throw 'request operation directory name is unsafe'
}
$expectedOperationRoot = [IO.Path]::GetFullPath(
    (Join-Path $deploymentRoot $operationId)
)
$expectedRequestPath = [IO.Path]::GetFullPath((Join-Path $operationRoot 'request.json'))
if (-not [string]::Equals(
    $operationRoot, $expectedOperationRoot, [StringComparison]::OrdinalIgnoreCase
) -or -not [string]::Equals(
    $requestCanonical, $expectedRequestPath, [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'RequestPath is not the fixed operation request.json path'
}
Assert-NoReparsePath -Path $operationRoot -Name 'operation root'
$operationItem = Get-Item -LiteralPath $operationRoot -Force
if (-not $operationItem.PSIsContainer -or
    ($operationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Operation root is not a regular directory'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentSid = $identity.User.Value
$currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($Mode -ceq 'Start') {
    Set-AndAssert-OperationAcl -Path $operationRoot -OwnerSid $currentSid
} else {
    Assert-OperationAcl -Path $operationRoot -OwnerSid $currentSid
}
$requestItem = Get-Item -LiteralPath $requestCanonical -Force
if ($requestItem.PSIsContainer -or
    ($requestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'RequestPath must be a regular non-reparse file'
}
Assert-OwnerOnlyFileSecurity -Path $requestCanonical -OwnerSid $currentSid `
    -Name 'request.json'
$requestRead = Read-StrictJsonBytes -Path $requestCanonical
Assert-BootstrapRequest -Request $requestRead.Value `
    -OperationRoot $operationRoot -CurrentUserSid $currentSid `
    -CurrentSessionId $currentSession `
    -AllowConsumedLinuxFrozenEvidence:($Mode -cin @('Status', 'Stop'))
foreach ($inputField in @(
    'launcher_path', 'installer_path', 'candidate_path', 'wrapper_path',
    'rollback_script_path', 'marker_handoff_receipt_path'
)) {
    Assert-OwnerOnlyFileSecurity -Path $requestRead.Value.$inputField `
        -OwnerSid $currentSid -Name $inputField
}
if (-not [string]::Equals(
    [IO.Path]::GetFullPath($PSCommandPath),
    [IO.Path]::GetFullPath($requestRead.Value.launcher_path),
    [StringComparison]::OrdinalIgnoreCase
) -or (Get-Sha256Lower -Path $PSCommandPath) -cne
        $requestRead.Value.launcher_sha256) {
    throw 'Executing launcher path/hash differs from the request'
}

if ($Mode -ceq 'Worker') {
    Invoke-Worker -Request $requestRead.Value -RequestPath $requestCanonical `
        -RequestBytes $requestRead.Bytes -OperationRoot $operationRoot `
        -CurrentSid $currentSid -CurrentSessionId $currentSession
}
if ($Mode -ceq 'Stop') {
    Invoke-StopBootstrap -Request $requestRead.Value `
        -RequestPath $requestCanonical -RequestBytes $requestRead.Bytes `
        -OperationRoot $operationRoot -CurrentSid $currentSid |
        ConvertTo-Json -Compress
    exit 0
}

$status = Get-LaunchStatus -Request $requestRead.Value `
    -RequestPath $requestCanonical -RequestBytes $requestRead.Bytes `
    -OperationRoot $operationRoot -CurrentSid $currentSid
if ($Mode -ceq 'Start' -and $status.State -ceq 'absent') {
    $requestLease = [IO.File]::Open(
        $requestCanonical, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        if ((Get-Sha256Lower -Path $requestCanonical) -cne
            (Get-BytesSha256Lower -Bytes $requestRead.Bytes)) {
            throw 'Bootstrap request changed before task registration'
        }
        Assert-BootstrapRequest -Request $requestRead.Value `
            -OperationRoot $operationRoot -CurrentUserSid $currentSid `
            -CurrentSessionId $currentSession -RequireFreshOutputs
        Assert-FreshOperationDirectory -Request $requestRead.Value `
            -RequestPath $requestCanonical -OperationRoot $operationRoot
        Register-BootstrapTask -Contract $status.TaskContract `
            -UserName $identity.Name
        $registered = Get-ScheduledTask -TaskPath $status.TaskContract.TaskPath `
            -TaskName $status.TaskContract.TaskName -ErrorAction Stop
        Assert-BootstrapTask -Task $registered -Contract $status.TaskContract `
            -UserSid $currentSid
        Start-ScheduledTask -TaskPath $status.TaskContract.TaskPath `
            -TaskName $status.TaskContract.TaskName
        $claimDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        $claimPath = Join-Path $operationRoot 'launcher-claim.json'
        while (-not (Test-Path -LiteralPath $claimPath) -and
            [DateTimeOffset]::UtcNow -lt $claimDeadline) {
            Start-Sleep -Milliseconds 50
        }
        if (-not (Test-Path -LiteralPath $claimPath)) {
            throw 'uncertain: scheduled bootstrap did not publish its claim'
        }
        $startedStatus = Get-LaunchStatus -Request $requestRead.Value `
            -RequestPath $requestCanonical -RequestBytes $requestRead.Bytes `
            -OperationRoot $operationRoot -CurrentSid $currentSid
        if ($startedStatus.State -ceq 'terminal') {
            $startedStatus.Terminal | ConvertTo-Json -Compress
        } else {
            [pscustomobject]@{
                schema_version = 1
                state = "viewflow-windows-bootstrap-$($startedStatus.State)"
                operation_id = $operationId
                request_sha256 = Get-BytesSha256Lower -Bytes $requestRead.Bytes
                task_name = $status.TaskContract.TaskName
            } | ConvertTo-Json -Compress
        }
    } finally {
        $requestLease.Dispose()
    }
    exit 0
}
if ($Mode -ceq 'Start' -and $status.State -ne 'absent') {
    # Repeated Start is deliberately monitor-only. It never calls Start-ScheduledTask.
    $Mode = 'Status'
}
if ($status.State -ceq 'terminal') {
    $status.Terminal | ConvertTo-Json -Compress
} elseif ($status.State -ceq 'stopped') {
    $status.StopEvidence | ConvertTo-Json -Compress
} else {
    [pscustomobject]@{
        schema_version = 1
        state = "viewflow-windows-bootstrap-$($status.State)"
        operation_id = $operationId
        request_sha256 = Get-BytesSha256Lower -Bytes $requestRead.Bytes
        task_name = $status.TaskContract.TaskName
    } | ConvertTo-Json -Compress
}
