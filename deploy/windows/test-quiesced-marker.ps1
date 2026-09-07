param(
    [string]$InstallerPath = (Join-Path $PSScriptRoot 'install-viewflow.ps1')
)

$ErrorActionPreference = 'Stop'
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
$installerFunctionSources = foreach ($name in @(
        'Assert-ExactPropertySet',
        'Assert-V13BootstrapEvidence',
        'Assert-QuiescedMarker'
    )) {
    $functionAst = $ast.Find(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $Node.Name -ceq $name
        },
        $true
    )
    if ($null -eq $functionAst) {
        throw "$name was not found in the installer"
    }
    $functionAst.Extent.Text
}
Invoke-Expression ($installerFunctionSources -join [Environment]::NewLine)

$expectedTaskName = '\Viewflow Peer'
$expectedPeer = '172.16.105.62:44119'
$expectedLocalDeviceId = '00000000000000000000000000000001'
$expectedDeviceId = '00000000000000000000000000000002'
$expectedSourceDisplayId = '00000000000000000000000000000101'
$QuiescedMarkerMaxAgeSeconds = 300
$maximumJsonInteger = 9007199254740991L
$installedSha256 = 'a' * 64
$candidateSha256 = 'c' * 64
$installedWrapperSha256 = 'd' * 64
$bootId = '11111111-2222-3333-4444-555555555555'
$daemonPid = 1234
$daemonStartTicks = 987654321
$operationId = 'operation_1234567890'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    'viewflow-marker-test-{0}' -f [Guid]::NewGuid().ToString('N')
)
$expectedCert = Join-Path $testRoot 'peer.pem'
$expectedKey = Join-Path $testRoot 'peer.key'
$expectedCa = Join-Path $testRoot 'ca.pem'

function Get-TestHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-OwnerOnlyUtf8JsonSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $value = $utf8.GetString($bytes) | ConvertFrom-Json
    } catch {
        throw "$Name is not strict UTF-8 JSON"
    }
    [pscustomobject]@{
        Value = $value
        Sha256 = Get-TestHash -Path $Path
    }
}

function New-TestCleanup {
    param(
        [ValidateSet('inactive', 'active')]
        [string]$Kind = 'active'
    )
    switch ($Kind) {
        'inactive' {
            [ordered]@{
                route_ever_activated = $false
                route_was_active = $false
                source_display = $null
                route_generation = $null
                active_lease_generation = $null
                last_input_sequence = $null
                release_all = [ordered]@{
                    status = 'not_required_no_active_route'
                    ack = $null
                }
                lease_revoke = [ordered]@{
                    status = 'not_required_no_active_route'
                    generation = $null
                    ack = $null
                }
                bound_peer_epoch = $null
                bound_peer_socket = $null
            }
        }
        'active' {
            [ordered]@{
                route_ever_activated = $true
                route_was_active = $true
                source_display = $expectedSourceDisplayId
                route_generation = 5
                active_lease_generation = 9
                last_input_sequence = 20
                release_all = [ordered]@{
                    status = 'applied'
                    ack = [ordered]@{
                        lease_generation = 9
                        target_device = $expectedDeviceId
                        event_sequence = 21
                        result = 'applied'
                    }
                }
                lease_revoke = [ordered]@{
                    status = 'applied'
                    generation = 10
                    ack = [ordered]@{
                        operation_id = '00000000000000040000000000000001'
                        lease_generation = 10
                        owner_device = $expectedLocalDeviceId
                        target_device = $expectedDeviceId
                        state = 'revoked'
                        result = 'applied'
                    }
                }
                bound_peer_epoch = 4
                bound_peer_socket = '172.16.105.70:49152'
            }
        }
    }
}

function New-ValidMarker {
    param(
        [ValidateSet('inactive', 'active')]
        [string]$CleanupKind = 'active'
    )
    $completedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [ordered]@{
        schema_version = 4
        state = 'viewflow-input-quiesced'
        operation_id = $operationId
        task_name = $expectedTaskName
        peer = $expectedPeer
        device_id = $expectedDeviceId
        protocol_version = '2.1'
        daemon_instance_id = "$bootId-$daemonPid-$daemonStartTicks"
        daemon_pid = $daemonPid
        daemon_start_ticks = $daemonStartTicks
        boot_id = $bootId
        daemon_sha256 = 'b' * 64
        local_device = $expectedLocalDeviceId
        target_device = $expectedDeviceId
        cleanup = New-TestCleanup -Kind $CleanupKind
        route_status = 'removed'
        peer_disconnect_status = 'confirmed_by_daemon_exit'
        completed_at_unix_ms = $completedAt
        daemon_exit_evidence = [ordered]@{
            schema_version = 1
            state = 'viewflow-daemon-exited'
            operation_id = $operationId
            daemon_pid = $daemonPid
            daemon_start_ticks = $daemonStartTicks
            boot_id = $bootId
            unit = 'viewflow-peer.service'
            active_state = 'inactive'
            main_pid = 0
            exact_process_count = 0
            udp_listener_count = 0
            sidecar_socket_present = $false
            observation_sha256 = 'f' * 64
            observed_at_unix_ms = $completedAt
        }
        artifact_hashes = [ordered]@{
            linux_viewflowd = 'b' * 64
            linux_peer_certificate = '1' * 64
            linux_peer_private_key = '2' * 64
            linux_certificate_authority = '3' * 64
            windows_installed_viewflowd = $installedSha256
            windows_candidate_viewflowd = $candidateSha256
            windows_client_wrapper = $installedWrapperSha256
            windows_peer_certificate = Get-TestHash -Path $expectedCert
            windows_peer_private_key = Get-TestHash -Path $expectedKey
            windows_certificate_authority = Get-TestHash -Path $expectedCa
        }
        created_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Assert-RawMarkerCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Json,
        [Parameter(Mandatory = $true)][bool]$ShouldPass,
        [switch]$AllowBootstrap,
        [string]$ExpectedErrorPattern
    )
    $path = Join-Path $testRoot "$Name.json"
    [System.IO.File]::WriteAllText(
        $path,
        $Json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    $passed = $true
    $failureMessage = $null
    try {
        Assert-QuiescedMarker -Path $path `
            -InstalledSha256 $installedSha256 `
            -InstalledWrapperSha256 $installedWrapperSha256 `
            -CandidateSha256 $candidateSha256 `
            -AllowBootstrap:$AllowBootstrap
    } catch {
        $passed = $false
        $failureMessage = $_.Exception.Message
    }
    if ($passed -ne $ShouldPass) {
        throw "Marker case '$Name' expected pass=$ShouldPass, got pass=$passed; $failureMessage"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedErrorPattern) -and
        $failureMessage -notmatch $ExpectedErrorPattern) {
        throw "Marker case '$Name' returned unexpected error: $failureMessage"
    }
    [pscustomobject]@{
        Case = $Name
        ExpectedPass = $ShouldPass
        PassedExpectation = $true
        ValidationError = $failureMessage
    }
}

function Assert-MarkerCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Marker,
        [Parameter(Mandatory = $true)][bool]$ShouldPass,
        [switch]$AllowBootstrap,
        [string]$ExpectedErrorPattern
    )
    $json = $Marker | ConvertTo-Json -Depth 12
    Assert-RawMarkerCase -Name $Name -Json $json -ShouldPass $ShouldPass `
        -AllowBootstrap:$AllowBootstrap -ExpectedErrorPattern $ExpectedErrorPattern
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Set-Content -LiteralPath $expectedCert -Value 'test peer certificate' -Encoding ASCII
    Set-Content -LiteralPath $expectedKey -Value 'test peer private key' -Encoding ASCII
    Set-Content -LiteralPath $expectedCa -Value 'test certificate authority' -Encoding ASCII

    $results = @()
    foreach ($kind in @('inactive', 'active')) {
        $results += Assert-MarkerCase -Name "valid-$kind" `
            -Marker (New-ValidMarker -CleanupKind $kind) -ShouldPass $true
    }

    $marker = New-ValidMarker
    $marker.schema_version = 3
    $results += Assert-MarkerCase -Name 'schema-3-transport-era' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.schema_version = '4'
    $results += Assert-MarkerCase -Name 'schema-string' -Marker $marker -ShouldPass $false
    $json = (New-ValidMarker | ConvertTo-Json -Depth 12)
    $schemaPattern = [regex]::new('"schema_version"\s*:\s*4(?=\s*,)')
    $json = $schemaPattern.Replace($json, '"schema_version": 4.0', 1)
    $results += Assert-RawMarkerCase -Name 'schema-double' -Json $json -ShouldPass $false

    $marker = New-ValidMarker
    $marker.release_all_applied = $true
    $results += Assert-MarkerCase -Name 'legacy-operator-boolean' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.Remove('state')
    $marker.Add('State', 'viewflow-input-quiesced')
    $results += Assert-MarkerCase -Name 'top-state-case-only' `
        -Marker $marker -ShouldPass $false `
        -ExpectedErrorPattern 'unexpected property set'
    $marker = New-ValidMarker
    $marker.cleanup.route_was_active = 'true'
    $results += Assert-MarkerCase -Name 'cleanup-boolean-string' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.route_ever_activated = 'true'
    $results += Assert-MarkerCase -Name 'cleanup-history-boolean-string' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.Remove('route_ever_activated')
    $results += Assert-MarkerCase -Name 'cleanup-history-missing' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.source_display = $expectedDeviceId
    $results += Assert-MarkerCase -Name 'source-display-mismatch' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.source_display = $null
    $results += Assert-MarkerCase -Name 'source-display-null-active' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.route_generation = 0
    $results += Assert-MarkerCase -Name 'route-generation-zero' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.route_generation = $null
    $results += Assert-MarkerCase -Name 'route-generation-null-active' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.route_generation = '5'
    $results += Assert-MarkerCase -Name 'route-generation-string' `
        -Marker $marker -ShouldPass $false
    $json = New-ValidMarker | ConvertTo-Json -Depth 12
    $generationPattern = [regex]::new('"route_generation"\s*:\s*5(?=\s*,)')
    $json = $generationPattern.Replace($json, '"route_generation": 5.0', 1)
    $results += Assert-RawMarkerCase -Name 'route-generation-double' `
        -Json $json -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.route_generation = [long]9007199254740992
    $results += Assert-MarkerCase -Name 'route-generation-over-uint53' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.Remove('source_display')
    $results += Assert-MarkerCase -Name 'source-display-missing' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.Remove('source_display')
    $marker.cleanup.Add('Source_display', $expectedSourceDisplayId)
    $results += Assert-MarkerCase -Name 'source-display-case-only' `
        -Marker $marker -ShouldPass $false `
        -ExpectedErrorPattern 'unexpected property set'
    $marker = New-ValidMarker
    $marker.cleanup.Remove('route_generation')
    $results += Assert-MarkerCase -Name 'route-generation-missing' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.Remove('route_generation')
    $marker.cleanup.Add('Route_generation', 5)
    $results += Assert-MarkerCase -Name 'route-generation-case-only' `
        -Marker $marker -ShouldPass $false `
        -ExpectedErrorPattern 'unexpected property set'
    $marker = New-ValidMarker -CleanupKind inactive
    $marker.cleanup.source_display = $expectedSourceDisplayId
    $results += Assert-MarkerCase -Name 'inactive-source-display-pollution' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker -CleanupKind inactive
    $marker.cleanup.route_generation = 1
    $results += Assert-MarkerCase -Name 'inactive-route-generation-pollution' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.release_all.ack.event_sequence = 22
    $results += Assert-MarkerCase -Name 'ack-sequence-mismatch' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.lease_revoke.generation = 11
    $results += Assert-MarkerCase -Name 'revoke-generation-mismatch' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.lease_revoke.status = 'transport_confirmed'
    $results += Assert-MarkerCase -Name 'transport-only-revoke-rejected' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.lease_revoke.Remove('ack')
    $results += Assert-MarkerCase -Name 'revoke-ack-missing' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.lease_revoke.ack = $null
    $results += Assert-MarkerCase -Name 'revoke-ack-null' -Marker $marker -ShouldPass $false
    foreach ($case in @(
            @('revoke-ack-operation', 'operation_id', '00000000000000000000000000000000'),
            @('revoke-ack-peer-epoch', 'operation_id', '00000000000000050000000000000001'),
            @('revoke-ack-generation', 'lease_generation', 11),
            @('revoke-ack-owner', 'owner_device', $expectedDeviceId),
            @('revoke-ack-target', 'target_device', $expectedLocalDeviceId),
            @('revoke-ack-state', 'state', 'active'),
            @('revoke-ack-result', 'result', 'transport_confirmed')
        )) {
        $marker = New-ValidMarker
        $marker.cleanup.lease_revoke.ack[$case[1]] = $case[2]
        $results += Assert-MarkerCase -Name $case[0] -Marker $marker -ShouldPass $false
    }
    $marker = New-ValidMarker
    $marker.cleanup.bound_peer_socket = '172.16.105.71:49152'
    $results += Assert-MarkerCase -Name 'wrong-bound-peer' -Marker $marker -ShouldPass $false

    $marker = New-ValidMarker -CleanupKind inactive
    $marker.cleanup.release_all.ack = [ordered]@{ result = 'applied' }
    $results += Assert-MarkerCase -Name 'inactive-route-ack-pollution' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker -CleanupKind inactive
    $marker.cleanup.route_ever_activated = $true
    $results += Assert-MarkerCase -Name 'activated-history-disguised-as-inactive' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.route_ever_activated = $false
    $results += Assert-MarkerCase -Name 'never-activated-disguised-as-active' `
        -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.cleanup.release_all.status = 'not_required_no_bound_peer'
    $marker.cleanup.release_all.ack = $null
    $marker.cleanup.lease_revoke.status = 'not_required_no_bound_peer'
    $marker.cleanup.lease_revoke.generation = $null
    $marker.cleanup.lease_revoke.ack = $null
    $marker.cleanup.bound_peer_epoch = $null
    $marker.cleanup.bound_peer_socket = $null
    $results += Assert-MarkerCase -Name 'activated-unbound-route-rejected' `
        -Marker $marker -ShouldPass $false

    $marker = New-ValidMarker
    $marker.daemon_exit_evidence.sidecar_socket_present = 'false'
    $results += Assert-MarkerCase -Name 'exit-boolean-string' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.daemon_exit_evidence.daemon_pid = $daemonPid + 1
    $results += Assert-MarkerCase -Name 'exit-instance-mismatch' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.local_device = $expectedDeviceId
    $results += Assert-MarkerCase -Name 'local-device-mismatch' -Marker $marker -ShouldPass $false

    $marker = New-ValidMarker
    $marker.artifact_hashes.windows_candidate_viewflowd = '9' * 64
    $results += Assert-MarkerCase -Name 'candidate-hash-mismatch' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.artifact_hashes.extra = '9' * 64
    $results += Assert-MarkerCase -Name 'extra-artifact-hash' -Marker $marker -ShouldPass $false
    $marker = New-ValidMarker
    $marker.completed_at_unix_ms = (
        [DateTimeOffset]::UtcNow.AddMinutes(-10).ToUnixTimeMilliseconds()
    )
    $results += Assert-MarkerCase -Name 'stale-completion' -Marker $marker -ShouldPass $false

    $bootstrap = [ordered]@{
        schema_version = 1
        state = 'viewflow-v13-bootstrap-quiesced'
    }
    $results += Assert-MarkerCase -Name 'bootstrap-without-flag' `
        -Marker $bootstrap -ShouldPass $false
    $results += Assert-MarkerCase -Name 'bootstrap-incomplete-evidence' `
        -Marker $bootstrap -ShouldPass $false -AllowBootstrap `
        -ExpectedErrorPattern 'unexpected property set'
    $results += Assert-MarkerCase -Name 'schema4-not-bootstrap' `
        -Marker (New-ValidMarker) -ShouldPass $false -AllowBootstrap `
        -ExpectedErrorPattern 'unexpected property set'

    $results
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
