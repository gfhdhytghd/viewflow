param(
    [string]$ProducerPath = (Join-Path $PSScriptRoot 'new-viewflow-quiesced-marker.ps1'),
    [switch]$KeepTestArtifacts
)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'viewflow-marker-producer-test-{0}' -f [Guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$bootId = '11111111-2222-3333-4444-555555555555'
$daemonPid = 1234
$daemonStartTicks = 987654321
$daemonInstanceId = "$bootId-$daemonPid-$daemonStartTicks"
$operationId = 'operation_1234567890'
$daemonSha256 = 'b' * 64
$journalSha256 = 'c' * 64
$invocationId = '0123456789abcdef0123456789abcdef'
$revokeOperationId = '00000000000000070000000000000001'
$localDeviceId = '00000000000000000000000000000001'
$targetDeviceId = '00000000000000000000000000000002'
$sourceDisplayId = '00000000000000000000000000000101'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$junctions = New-Object Collections.ArrayList

function Get-TestHash {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Set-TestOwnerOnlyAcl {
    param([string]$Path)
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

function Write-TestBytes {
    param([string]$Path, [byte[]]$Bytes, [switch]$OwnerOnly)
    [IO.File]::WriteAllBytes($Path, $Bytes)
    if ($OwnerOnly) { Set-TestOwnerOnlyAcl $Path }
}

function Write-TestText {
    param([string]$Path, [string]$Value, [switch]$OwnerOnly)
    Write-TestBytes $Path $utf8.GetBytes($Value) -OwnerOnly:$OwnerOnly
}

function ConvertTo-TestJson {
    param($Value, [switch]$Compress)
    if ($Compress) { $Value | ConvertTo-Json -Depth 64 -Compress }
    else { $Value | ConvertTo-Json -Depth 64 }
}

function ConvertTo-TestObject {
    param($Value)
    (ConvertTo-TestJson $Value) | ConvertFrom-Json
}

function New-RuntimeReceipt {
    param([long]$CompletedAtUnixMs)
    ConvertTo-TestObject ([ordered]@{
        schema_version = 4
        state = 'viewflow-input-quiesced'
        daemon_instance_id = $daemonInstanceId
        operation_id = $operationId
        daemon_pid = $daemonPid
        daemon_start_ticks = $daemonStartTicks
        boot_id = $bootId
        daemon_sha256 = $daemonSha256
        protocol_version = '2.1'
        local_device = $localDeviceId
        target_device = $targetDeviceId
        cleanup = [ordered]@{
            route_ever_activated = $true
            route_was_active = $true
            source_display = $sourceDisplayId
            route_generation = 5
            active_lease_generation = 9
            last_input_sequence = 41
            release_all = [ordered]@{
                status = 'applied'
                ack = [ordered]@{
                    lease_generation = 9
                    target_device = $targetDeviceId
                    event_sequence = 42
                    result = 'applied'
                }
            }
            lease_revoke = [ordered]@{
                status = 'applied'
                generation = 10
                ack = [ordered]@{
                    operation_id = $revokeOperationId
                    lease_generation = 10
                    owner_device = $localDeviceId
                    target_device = $targetDeviceId
                    state = 'revoked'
                    result = 'applied'
                }
            }
            bound_peer_epoch = 7
            bound_peer_socket = '172.16.105.70:50123'
        }
        route_status = 'removed'
        peer_disconnect_status = 'initiated_before_daemon_exit'
        daemon_exit_required = $true
        sidecar_session_disconnected = $true
        artifact_hashes = [ordered]@{
            linux_viewflowd = $daemonSha256
            linux_peer_certificate = '1' * 64
            linux_peer_private_key = '2' * 64
            linux_certificate_authority = '3' * 64
        }
        completed_at_unix_ms = $CompletedAtUnixMs
    })
}

function New-CommandOutputs {
    param([long]$CompletedAtUnixMs)
    ConvertTo-TestObject ([ordered]@{
        exact_process_pids = ''
        journal_entries = @(
            [ordered]@{
                _BOOT_ID = $bootId.Replace('-', '')
                _PID = [string]$daemonPid
                _SYSTEMD_INVOCATION_ID = $invocationId
                __REALTIME_TIMESTAMP = [string]($CompletedAtUnixMs * 1000)
                MESSAGE = 'viewflowd protocol 2.1 serving mTLS QUIC'
            },
            [ordered]@{
                _BOOT_ID = $bootId.Replace('-', '')
                _PID = [string]$daemonPid
                _SYSTEMD_INVOCATION_ID = $invocationId
                __REALTIME_TIMESTAMP = [string](($CompletedAtUnixMs * 1000) + 20)
                MESSAGE = 'viewflowd deployment quiescence receipt written; daemon exiting'
            }
        )
        journal_json_sha256 = $journalSha256
        journal_selected_invocation_id = $invocationId
        original_daemon_pid_present = 'false'
        sidecar_socket_lstat = 'absent'
        systemctl_invocation_id = $invocationId
        systemctl_is_active = 'inactive'
        systemctl_main_pid = '0'
        udp_listener_output = ''
    })
}

function New-RawObservation {
    param([long]$ObservedAtUnixMs, [string]$ReceiptSha256, $CommandOutputs)
    ConvertTo-TestObject ([ordered]@{
        command_outputs = $CommandOutputs
        daemon_identity = [ordered]@{
            boot_id = $bootId
            daemon_instance_id = $daemonInstanceId
            daemon_pid = $daemonPid
            daemon_sha256 = $daemonSha256
            daemon_start_ticks = $daemonStartTicks
            invocation_id = $invocationId
        }
        journal_query = [ordered]@{
            _BOOT_ID = $bootId.Replace('-', '')
            _PID = [string]$daemonPid
            _SYSTEMD_INVOCATION_ID = $invocationId
        }
        observed_at_unix_ms = $ObservedAtUnixMs
        operation_id = $operationId
        runtime_receipt_sha256 = $ReceiptSha256
        schema_version = 1
        state = 'viewflow-daemon-exit-observation'
    })
}

function New-ExitEvidence {
    param(
        [long]$ObservedAtUnixMs,
        [string]$ReceiptSha256,
        [string]$ObservationSha256,
        [string]$ObservationFileName,
        $CommandOutputs
    )
    ConvertTo-TestObject ([ordered]@{
        active_state = 'inactive'
        boot_id = $bootId
        command_outputs = $CommandOutputs
        daemon_instance_id = $daemonInstanceId
        daemon_pid = $daemonPid
        daemon_sha256 = $daemonSha256
        daemon_start_ticks = $daemonStartTicks
        exact_process_count = 0
        exit_status = [ordered]@{
            exact_process_count = 0
            main_pid_zero = $true
            original_daemon_pid_present = $false
            sidecar_socket_present = $false
            udp_listener_count = 0
            unit_inactive = $true
        }
        invocation_id = $invocationId
        journal = [ordered]@{
            entry_count = 2
            exit_realtime_us = ($ObservedAtUnixMs * 1000) + 10
            first_realtime_us = $ObservedAtUnixMs * 1000
            last_realtime_us = ($ObservedAtUnixMs * 1000) + 20
            query = [ordered]@{
                _BOOT_ID = $bootId.Replace('-', '')
                _PID = [string]$daemonPid
                _SYSTEMD_INVOCATION_ID = $invocationId
            }
            quiescence_exit_count = 1
            slice_sha256 = $journalSha256
            startup_count = 1
        }
        main_pid = 0
        observation_file_name = $ObservationFileName
        observation_sha256 = $ObservationSha256
        observed_at_unix_ms = $ObservedAtUnixMs
        operation_id = $operationId
        protocol_version = '2.1'
        runtime_receipt_sha256 = $ReceiptSha256
        schema_version = 1
        sidecar_socket_present = $false
        state = 'viewflow-daemon-exited'
        udp_listener_count = 0
        unit = 'viewflow-peer.service'
    })
}

function New-TestContext {
    param([string]$Name)
    $root = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $root | Out-Null
    $completedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $receiptPath = Join-Path $root 'runtime-receipt.json'
    $evidencePath = Join-Path $root 'daemon-exit-evidence.json'
    $observationPath = Join-Path $root 'viewflow-daemon-exit-observation.json'
    $candidatePath = Join-Path $root 'viewflowd.exe'
    $outputPath = Join-Path $root 'quiesced-marker.json'
    $receipt = New-RuntimeReceipt $completedAt
    Write-TestText $receiptPath (ConvertTo-TestJson $receipt) -OwnerOnly
    $receiptSha = Get-TestHash $receiptPath
    $commands = New-CommandOutputs $completedAt
    $raw = New-RawObservation $completedAt $receiptSha (ConvertTo-TestObject $commands)
    Write-TestText $observationPath (ConvertTo-TestJson $raw) -OwnerOnly
    $rawSha = Get-TestHash $observationPath
    $evidence = New-ExitEvidence $completedAt $receiptSha $rawSha `
        ([IO.Path]::GetFileName($observationPath)) (ConvertTo-TestObject $commands)
    Write-TestText $evidencePath (ConvertTo-TestJson $evidence) -OwnerOnly
    Write-TestText $candidatePath 'candidate binary fixture'
    [pscustomobject]@{
        Name = $Name; Root = $root; ProducerPath = $ProducerPath
        ReceiptPath = $receiptPath; EvidencePath = $evidencePath
        ObservationPath = $observationPath; CandidatePath = $candidatePath
        OutputPath = $outputPath; Receipt = $receipt; Evidence = $evidence
        Observation = $raw
    }
}

function Sync-TestContext {
    param($Context)
    Write-TestText $Context.ReceiptPath (ConvertTo-TestJson $Context.Receipt) -OwnerOnly
    $receiptSha = Get-TestHash $Context.ReceiptPath
    $Context.Observation.runtime_receipt_sha256 = $receiptSha
    Write-TestText $Context.ObservationPath (ConvertTo-TestJson $Context.Observation) -OwnerOnly
    $Context.Evidence.runtime_receipt_sha256 = $receiptSha
    $Context.Evidence.observation_sha256 = Get-TestHash $Context.ObservationPath
    $Context.Evidence.observation_file_name = [IO.Path]::GetFileName($Context.ObservationPath)
    Write-TestText $Context.EvidencePath (ConvertTo-TestJson $Context.Evidence) -OwnerOnly
}

function Write-LiteralReceipt {
    param($Context, [byte[]]$Bytes)
    Write-TestBytes $Context.ReceiptPath $Bytes -OwnerOnly
    $receiptSha = Get-TestHash $Context.ReceiptPath
    $Context.Observation.runtime_receipt_sha256 = $receiptSha
    Write-TestText $Context.ObservationPath (ConvertTo-TestJson $Context.Observation) -OwnerOnly
    $Context.Evidence.runtime_receipt_sha256 = $receiptSha
    $Context.Evidence.observation_sha256 = Get-TestHash $Context.ObservationPath
    Write-TestText $Context.EvidencePath (ConvertTo-TestJson $Context.Evidence) -OwnerOnly
}

function Write-LiteralObservation {
    param($Context, [byte[]]$Bytes)
    Write-TestBytes $Context.ObservationPath $Bytes -OwnerOnly
    $Context.Evidence.observation_sha256 = Get-TestHash $Context.ObservationPath
    Write-TestText $Context.EvidencePath (ConvertTo-TestJson $Context.Evidence) -OwnerOnly
}

function Remove-TestProperty {
    param($Value, [string]$Name)
    $Value.PSObject.Properties.Remove($Name)
}

function Add-TestProperty {
    param($Value, [string]$Name, $PropertyValue)
    $Value | Add-Member -NotePropertyName $Name -NotePropertyValue $PropertyValue
}

function Assert-MarkerOwnerOnly {
    param([string]$Path)
    $security = Get-Acl -LiteralPath $Path
    if (-not $security.AreAccessRulesProtected) { throw 'Marker ACL inheritance is enabled' }
    $rules = @($security.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -ne 1 -or
        $rules[0].IdentityReference.Value -cne
            [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw 'Marker ACL is not owner-only'
    }
}

function Invoke-ProducerCase {
    param(
        [string]$Name,
        [scriptblock]$Mutator,
        [string]$ExpectedError,
        [switch]$Valid
    )
    $context = New-TestContext $Name
    if ($null -ne $Mutator) { & $Mutator $context }
    $passed = $true
    $failure = $null
    try {
        & $context.ProducerPath `
            -RuntimeReceiptPath $context.ReceiptPath `
            -DaemonExitEvidencePath $context.EvidencePath `
            -DaemonExitObservationPath $context.ObservationPath `
            -CandidatePath $context.CandidatePath `
            -ExpectedCandidateSha256 (Get-TestHash $context.CandidatePath) `
            -OutputPath $context.OutputPath | Out-Null
    } catch { $passed = $false; $failure = $_.Exception.Message }

    if ($Valid) {
        if (-not $passed) { throw "Producer case '$Name' unexpectedly failed: $failure" }
        $marker = Get-Content -LiteralPath $context.OutputPath -Raw | ConvertFrom-Json
        if ($marker.schema_version -ne 4 -or $marker.protocol_version -cne '2.1' -or
            $marker.cleanup.lease_revoke.status -cne 'applied' -or
            $marker.cleanup.lease_revoke.ack.result -cne 'applied' -or
            @($marker.daemon_exit_evidence.PSObject.Properties).Count -ne 23 -or
            $null -ne $marker.PSObject.Properties['daemon_exit_observation']) {
            throw "Producer case '$Name' changed the schema-4 marker contract"
        }
        Assert-MarkerOwnerOnly $context.OutputPath
    } else {
        if ($passed) { throw "Producer case '$Name' unexpectedly succeeded" }
        if ([string]::IsNullOrEmpty($ExpectedError) -or
            $failure.IndexOf($ExpectedError, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Producer case '$Name' failed through wrong branch: $failure"
        }
        if (Test-Path -LiteralPath $context.OutputPath) {
            throw "Producer case '$Name' published a marker after validation failure"
        }
    }
    [pscustomobject]@{ Case = $Name; PassedExpectation = $true; ValidationError = $failure }
}

function New-Junction {
    param([string]$Path, [string]$Target)
    try {
        New-Item -ItemType Junction -Path $Path -Target ([IO.Path]::GetFullPath($Target)) `
            -ErrorAction Stop | Out-Null
    } catch { throw "Junction fixture prerequisite failed: $($_.Exception.Message)" }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw 'Junction fixture did not create a reparse point'
    }
    $null = $junctions.Add($Path)
}

function Remove-Junction {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        & $env:ComSpec /d /c ('rmdir "{0}"' -f $Path) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not remove fixture junction: $Path" }
    }
}

function Configure-JunctionSwapCase {
    param($Context)
    $a = Join-Path $Context.Root 'raw-a'
    $b = Join-Path $Context.Root 'raw-b'
    $current = Join-Path $Context.Root 'raw-current'
    New-Item -ItemType Directory -Path $a, $b | Out-Null
    $name = [IO.Path]::GetFileName($Context.ObservationPath)
    $aPath = Join-Path $a $name
    $bPath = Join-Path $b $name
    Move-Item -LiteralPath $Context.ObservationPath -Destination $aPath
    Write-TestText $bPath (ConvertTo-TestJson $Context.Observation -Compress) -OwnerOnly
    if ((Get-TestHash $aPath) -ceq (Get-TestHash $bPath)) {
        throw 'Junction swap fixture needs byte-distinct observations'
    }
    New-Junction $current $a
    $Context.ObservationPath = Join-Path $current $name
    $Context.Evidence.observation_sha256 = Get-TestHash $aPath
    $Context.Evidence.observation_file_name = $name
    Write-TestText $Context.EvidencePath (ConvertTo-TestJson $Context.Evidence) -OwnerOnly

    $copy = Join-Path $Context.Root 'junction-swap-producer.ps1'
    $source = [IO.File]::ReadAllText($ProducerPath)
    $sourceNewline = if ($source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $openPattern = ('(?m)^    Assert-RegularNonReparseFile -Path \$Path -Name \$Name' +
        '\r?\n    Assert-OwnerOnlyFileSecurity -Path \$Path -Name \$Name\r?\n?')
    if ([regex]::Matches($source, $openPattern).Count -ne 1) {
        throw 'Pinned raw reparse test hook is not unique'
    }
    $relaxed = @'
    if ($Name -ceq 'Raw daemon-exit observation') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "$Name does not exist: $Path"
        }
        $rawItem = Get-Item -LiteralPath $Path -Force
        if (($rawItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Name must be a regular non-reparse file: $Path"
        }
    } else {
        Assert-RegularNonReparseFile -Path $Path -Name $Name
    }
    Assert-OwnerOnlyFileSecurity -Path $Path -Name $Name
'@
    $relaxed = $relaxed.TrimEnd([char[]]"`r`n") + $sourceNewline
    $source = [regex]::Replace(
        $source,
        $openPattern,
        [Text.RegularExpressions.MatchEvaluator]{ param($match) $relaxed },
        1)
    $hashNeedle = '    $currentObservationSha256 = Get-Sha256Lower $exitObservationFullPath'
    if ([regex]::Matches($source, [regex]::Escape($hashNeedle)).Count -ne 1) {
        throw 'Final raw pathname hash hook is not unique'
    }
    $junctionLiteral = $current.Replace("'", "''")
    $targetLiteral = $b.Replace("'", "''")
    $swap = @"
    & `$env:ComSpec /d /c ('rmdir "{0}"' -f '$junctionLiteral') | Out-Null
    if (`$LASTEXITCODE -ne 0) { throw 'Fixture could not remove raw junction' }
    New-Item -ItemType Junction -Path '$junctionLiteral' -Target '$targetLiteral' -ErrorAction Stop | Out-Null
"@
    $swap = $swap.TrimEnd([char[]]"`r`n") + $sourceNewline
    $source = $source.Replace($hashNeedle, $swap + $hashNeedle)
    Write-TestText $copy $source
    $Context.ProducerPath = $copy
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $env:LOCALAPPDATA = Join-Path $testRoot 'local-app-data'
    $installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Viewflow'
    $identityRoot = Join-Path $installRoot 'identity'
    New-Item -ItemType Directory -Path $identityRoot -Force | Out-Null
    Write-TestText (Join-Path $installRoot 'viewflowd.exe') 'installed binary fixture'
    Write-TestText (Join-Path $installRoot 'viewflow-client.ps1') 'installed wrapper fixture'
    Write-TestText (Join-Path $identityRoot 'peer.pem') 'peer cert fixture'
    Write-TestText (Join-Path $identityRoot 'peer.key') 'peer key fixture'
    Write-TestText (Join-Path $identityRoot 'ca.pem') 'ca fixture'

    $results = @()
    $results += Invoke-ProducerCase 'valid-schema4-protocol21-active-route' $null $null -Valid

    # Top-level and nested exact-property sets, including case-only misspellings.
    $results += Invoke-ProducerCase 'receipt-top-missing' { param($c)
        Remove-TestProperty $c.Receipt 'target_device'; Sync-TestContext $c
    } 'Runtime receipt has an unexpected field set'
    $results += Invoke-ProducerCase 'receipt-top-extra' { param($c)
        Add-TestProperty $c.Receipt 'extra' 1; Sync-TestContext $c
    } 'Runtime receipt has an unexpected field set'
    $results += Invoke-ProducerCase 'receipt-top-case' { param($c)
        Remove-TestProperty $c.Receipt 'state'; Add-TestProperty $c.Receipt 'State' 'viewflow-input-quiesced'
        Sync-TestContext $c
    } 'Runtime receipt has an unexpected field set'
    $results += Invoke-ProducerCase 'compact-top-missing' { param($c)
        Remove-TestProperty $c.Evidence 'unit'; Sync-TestContext $c
    } 'Daemon-exit compact evidence has an unexpected field set'
    $results += Invoke-ProducerCase 'compact-top-extra' { param($c)
        Add-TestProperty $c.Evidence 'extra' 1; Sync-TestContext $c
    } 'Daemon-exit compact evidence has an unexpected field set'
    $results += Invoke-ProducerCase 'compact-top-case' { param($c)
        Remove-TestProperty $c.Evidence 'unit'; Add-TestProperty $c.Evidence 'Unit' 'viewflow-peer.service'
        Sync-TestContext $c
    } 'Daemon-exit compact evidence has an unexpected field set'
    $results += Invoke-ProducerCase 'raw-top-missing' { param($c)
        Remove-TestProperty $c.Observation 'state'; Sync-TestContext $c
    } 'Raw daemon-exit observation has an unexpected field set'
    $results += Invoke-ProducerCase 'raw-top-extra' { param($c)
        Add-TestProperty $c.Observation 'extra' 1; Sync-TestContext $c
    } 'Raw daemon-exit observation has an unexpected field set'
    $results += Invoke-ProducerCase 'raw-top-case' { param($c)
        Remove-TestProperty $c.Observation 'state'
        Add-TestProperty $c.Observation 'State' 'viewflow-daemon-exit-observation'; Sync-TestContext $c
    } 'Raw daemon-exit observation has an unexpected field set'
    $results += Invoke-ProducerCase 'cleanup-nested-missing' { param($c)
        Remove-TestProperty $c.Receipt.cleanup 'bound_peer_epoch'; Sync-TestContext $c
    } 'Runtime cleanup has an unexpected field set'
    $results += Invoke-ProducerCase 'cleanup-source-display-wrong' { param($c)
        $c.Receipt.cleanup.source_display = $targetDeviceId; Sync-TestContext $c
    } 'Active-route cleanup evidence is inconsistent'
    $results += Invoke-ProducerCase 'cleanup-route-generation-zero' { param($c)
        $c.Receipt.cleanup.route_generation = 0; Sync-TestContext $c
    } 'Runtime route_generation must be a valid JSON uint53'
    $results += Invoke-ProducerCase 'cleanup-active-lease-generation-not-integer' { param($c)
        $json = ConvertTo-TestJson $c.Receipt -Compress
        Write-LiteralReceipt $c $utf8.GetBytes(
            $json.Replace('"active_lease_generation":9', '"active_lease_generation":9e0'))
    } 'Runtime active_lease_generation must be a valid JSON uint53'
    $results += Invoke-ProducerCase 'cleanup-last-input-sequence-not-integer' { param($c)
        $json = ConvertTo-TestJson $c.Receipt -Compress
        Write-LiteralReceipt $c $utf8.GetBytes(
            $json.Replace('"last_input_sequence":41', '"last_input_sequence":41e0'))
    } 'Runtime last_input_sequence must be a valid JSON uint53'
    $results += Invoke-ProducerCase 'cleanup-bound-peer-epoch-not-integer' { param($c)
        $json = ConvertTo-TestJson $c.Receipt -Compress
        Write-LiteralReceipt $c $utf8.GetBytes(
            $json.Replace('"bound_peer_epoch":7', '"bound_peer_epoch":7e0'))
    } 'Runtime bound_peer_epoch must be a valid JSON uint53'
    $results += Invoke-ProducerCase 'release-ack-nested-extra' { param($c)
        Add-TestProperty $c.Receipt.cleanup.release_all.ack 'extra' 1; Sync-TestContext $c
    } 'Runtime Applied ACK has an unexpected field set'
    $results += Invoke-ProducerCase 'revoke-ack-nested-missing' { param($c)
        Remove-TestProperty $c.Receipt.cleanup.lease_revoke.ack 'result'; Sync-TestContext $c
    } 'Runtime LeaseRevoke Applied ACK has an unexpected field set'
    $results += Invoke-ProducerCase 'revoke-ack-peer-epoch-mismatch' { param($c)
        $c.Receipt.cleanup.lease_revoke.ack.operation_id =
            '00000000000000080000000000000001'; Sync-TestContext $c
    } 'Active-route cleanup evidence is inconsistent'
    $results += Invoke-ProducerCase 'revoke-ack-operation-low64-zero' { param($c)
        $c.Receipt.cleanup.lease_revoke.ack.operation_id =
            '00000000000000070000000000000000'; Sync-TestContext $c
    } 'Active-route cleanup evidence is inconsistent'
    $results += Invoke-ProducerCase 'compact-journal-nested-extra' { param($c)
        Add-TestProperty $c.Evidence.journal 'extra' 1; Sync-TestContext $c
    } 'Daemon-exit journal has an unexpected field set'
    $results += Invoke-ProducerCase 'compact-query-nested-missing' { param($c)
        Remove-TestProperty $c.Evidence.journal.query '_PID'; Sync-TestContext $c
    } 'Daemon-exit journal query has an unexpected field set'
    $results += Invoke-ProducerCase 'compact-status-nested-extra' { param($c)
        Add-TestProperty $c.Evidence.exit_status 'extra' $false; Sync-TestContext $c
    } 'Daemon-exit status has an unexpected field set'
    $results += Invoke-ProducerCase 'compact-commands-nested-missing' { param($c)
        Remove-TestProperty $c.Evidence.command_outputs 'udp_listener_output'; Sync-TestContext $c
    } 'Daemon-exit command outputs has an unexpected field set'
    $results += Invoke-ProducerCase 'raw-identity-nested-extra' { param($c)
        Add-TestProperty $c.Observation.daemon_identity 'extra' 1; Sync-TestContext $c
    } 'Raw daemon identity has an unexpected field set'
    $results += Invoke-ProducerCase 'raw-query-nested-missing' { param($c)
        Remove-TestProperty $c.Observation.journal_query '_BOOT_ID'; Sync-TestContext $c
    } 'Raw journal query has an unexpected field set'
    $results += Invoke-ProducerCase 'raw-commands-nested-extra' { param($c)
        Add-TestProperty $c.Observation.command_outputs 'extra' 1; Sync-TestContext $c
    } 'Raw command outputs has an unexpected field set'

    # Explicitly fail closed on every legacy contract form.
    $results += Invoke-ProducerCase 'legacy-receipt-schema3' { param($c)
        $c.Receipt.schema_version = 3; Sync-TestContext $c
    } 'Runtime receipt schema or state is invalid'
    $results += Invoke-ProducerCase 'legacy-protocol20' { param($c)
        $c.Receipt.protocol_version = '2.0'; $c.Evidence.protocol_version = '2.0'; Sync-TestContext $c
    } 'Runtime receipt daemon, protocol, or endpoint binding is invalid'
    $results += Invoke-ProducerCase 'legacy-transport-confirmed-revoke' { param($c)
        $c.Receipt.cleanup.lease_revoke.status = 'transport_confirmed'; Sync-TestContext $c
    } 'Active-route cleanup evidence is inconsistent'

    # Strict JSON scanner: all three documents, nested objects and arrays.
    $results += Invoke-ProducerCase 'receipt-duplicate-top' { param($c)
        $json = ConvertTo-TestJson $c.Receipt -Compress
        Write-LiteralReceipt $c $utf8.GetBytes($json.Insert(1, '"schema_version":4,'))
    } 'duplicate object property'
    $results += Invoke-ProducerCase 'compact-duplicate-top' { param($c)
        Write-TestText $c.EvidencePath '{"state":"x","state":"y"}' -OwnerOnly
    } 'duplicate object property'
    $results += Invoke-ProducerCase 'raw-duplicate-top' { param($c)
        Write-LiteralObservation $c $utf8.GetBytes('{"state":"x","state":"y"}')
    } 'duplicate object property'
    $results += Invoke-ProducerCase 'receipt-duplicate-nested' { param($c)
        Write-LiteralReceipt $c $utf8.GetBytes('{"cleanup":{"status":1,"status":2}}')
    } 'duplicate object property'
    $results += Invoke-ProducerCase 'raw-duplicate-object-in-array' { param($c)
        Write-LiteralObservation $c $utf8.GetBytes('{"x":[{"key":1,"key":2}]}')
    } 'duplicate object property'
    $results += Invoke-ProducerCase 'receipt-escaped-equivalent-key' { param($c)
        Write-LiteralReceipt $c $utf8.GetBytes('{"a":1,"\u0061":2}')
    } 'duplicate object property'
    $results += Invoke-ProducerCase 'raw-case-collision-key' { param($c)
        Write-LiteralObservation $c $utf8.GetBytes('{"state":1,"STATE":2}')
    } 'case-colliding object property'
    $results += Invoke-ProducerCase 'receipt-multiple-documents' { param($c)
        Write-LiteralReceipt $c $utf8.GetBytes('{}{}')
    } 'trailing content'
    $results += Invoke-ProducerCase 'receipt-top-array' { param($c)
        Write-LiteralReceipt $c $utf8.GetBytes('[]')
    } 'top-level JSON value must be an object'
    $results += Invoke-ProducerCase 'receipt-bom' { param($c)
        Write-LiteralReceipt $c ([byte[]](@(0xef, 0xbb, 0xbf) + $utf8.GetBytes('{}')))
    } 'UTF-8 BOM is not allowed'
    $results += Invoke-ProducerCase 'raw-invalid-utf8' { param($c)
        Write-LiteralObservation $c ([byte[]](0x7b, 0x22, 0x78, 0x22, 0x3a, 0x22, 0xc3, 0x28, 0x22, 0x7d))
    } 'not a strict UTF-8 JSON object'
    $results += Invoke-ProducerCase 'compact-comment' { param($c)
        Write-TestText $c.EvidencePath '{"x":1/*no*/}' -OwnerOnly
    } 'not a strict UTF-8 JSON object'
    $results += Invoke-ProducerCase 'compact-trailing-comma' { param($c)
        Write-TestText $c.EvidencePath '{"x":1,}' -OwnerOnly
    } 'object property name must be a string'
    $results += Invoke-ProducerCase 'receipt-invalid-number' { param($c)
        Write-LiteralReceipt $c $utf8.GetBytes('{"x":01}')
    } 'leading zero in JSON number'
    $results += Invoke-ProducerCase 'receipt-invalid-escape' { param($c)
        Write-LiteralReceipt $c $utf8.GetBytes('{"x":"\q"}')
    } 'invalid JSON escape'
    $results += Invoke-ProducerCase 'receipt-lone-surrogate' { param($c)
        Write-LiteralReceipt $c $utf8.GetBytes('{"x":"\ud800"}')
    } 'high surrogate must be followed'
    $results += Invoke-ProducerCase 'receipt-depth-limit' { param($c)
        $open = -join (@('[') * 130); $close = -join (@(']') * 130)
        Write-LiteralReceipt $c $utf8.GetBytes('{"x":' + $open + '0' + $close + '}')
    } 'JSON nesting exceeds 128 levels'

    # Hash, basename, identity, query, command-output, journal and time bindings.
    $results += Invoke-ProducerCase 'receipt-sha-mismatch' { param($c)
        $c.Observation.runtime_receipt_sha256 = '0' * 64
        Write-TestText $c.ObservationPath (ConvertTo-TestJson $c.Observation) -OwnerOnly
        $c.Evidence.observation_sha256 = Get-TestHash $c.ObservationPath
        Write-TestText $c.EvidencePath (ConvertTo-TestJson $c.Evidence) -OwnerOnly
    } 'evidence, raw observation, and runtime receipt are inconsistent'
    $results += Invoke-ProducerCase 'raw-sha-mismatch' { param($c)
        $c.Evidence.observation_sha256 = '0' * 64
        Write-TestText $c.EvidencePath (ConvertTo-TestJson $c.Evidence) -OwnerOnly
    } 'evidence, raw observation, and runtime receipt are inconsistent'
    $results += Invoke-ProducerCase 'observation-basename-mismatch' { param($c)
        $c.Evidence.observation_file_name = 'wrong.json';
        Write-TestText $c.EvidencePath (ConvertTo-TestJson $c.Evidence) -OwnerOnly
    } 'evidence, raw observation, and runtime receipt are inconsistent'
    foreach ($field in @('boot_id', 'daemon_instance_id', 'daemon_pid', 'daemon_sha256',
            'daemon_start_ticks', 'invocation_id')) {
        $fieldCopy = $field
        $results += Invoke-ProducerCase "raw-identity-$fieldCopy-mismatch" { param($c)
            if ($fieldCopy -eq 'daemon_pid') { $c.Observation.daemon_identity.$fieldCopy = 9999 }
            elseif ($fieldCopy -eq 'daemon_start_ticks') { $c.Observation.daemon_identity.$fieldCopy = 9999 }
            elseif ($fieldCopy -eq 'daemon_sha256') { $c.Observation.daemon_identity.$fieldCopy = 'd' * 64 }
            elseif ($fieldCopy -eq 'invocation_id') { $c.Observation.daemon_identity.$fieldCopy = 'e' * 32 }
            elseif ($fieldCopy -eq 'boot_id') { $c.Observation.daemon_identity.$fieldCopy = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
            else { $c.Observation.daemon_identity.$fieldCopy = 'wrong-instance' }
            Sync-TestContext $c
        } 'Raw daemon identity does not match compact evidence'
    }
    $results += Invoke-ProducerCase 'compact-invocation-query-mismatch' { param($c)
        $c.Evidence.journal.query._SYSTEMD_INVOCATION_ID = 'f' * 32; Sync-TestContext $c
    } 'evidence, raw observation, and runtime receipt are inconsistent'
    $results += Invoke-ProducerCase 'raw-query-mismatch' { param($c)
        $c.Observation.journal_query._PID = '9999'; Sync-TestContext $c
    } 'Raw journal query._PID differs'
    $results += Invoke-ProducerCase 'raw-command-output-mismatch' { param($c)
        $c.Observation.command_outputs.systemctl_main_pid = '1'; Sync-TestContext $c
    } 'Raw command outputs.systemctl_main_pid differs'
    $results += Invoke-ProducerCase 'command-fixed-output-mismatch' { param($c)
        $c.Evidence.command_outputs.systemctl_is_active = 'active'
        $c.Observation.command_outputs.systemctl_is_active = 'active'; Sync-TestContext $c
    } 'Daemon-exit command outputs are inconsistent'
    $results += Invoke-ProducerCase 'journal-entry-count-mismatch' { param($c)
        $c.Evidence.journal.entry_count = 3; Sync-TestContext $c
    } 'Daemon-exit command outputs are inconsistent'
    $results += Invoke-ProducerCase 'journal-startup-count-mismatch' { param($c)
        $c.Evidence.journal.startup_count = 2; Sync-TestContext $c
    } 'evidence, raw observation, and runtime receipt are inconsistent'
    $results += Invoke-ProducerCase 'journal-time-order-mismatch' { param($c)
        $c.Evidence.journal.exit_realtime_us = $c.Evidence.journal.last_realtime_us + 1
        Sync-TestContext $c
    } 'evidence, raw observation, and runtime receipt are inconsistent'
    $results += Invoke-ProducerCase 'journal-exit-before-completion' { param($c)
        $c.Evidence.journal.first_realtime_us = 1
        $c.Evidence.journal.exit_realtime_us = 2
        $c.Evidence.journal.last_realtime_us = 3
        Sync-TestContext $c
    } 'evidence, raw observation, and runtime receipt are inconsistent'
    $results += Invoke-ProducerCase 'exit-status-mismatch' { param($c)
        $c.Evidence.exit_status.unit_inactive = $false; Sync-TestContext $c
    } 'Daemon-exit status is not the required fixed quiescence state'

    # Physical aliases and reparse ancestry are independent of lexical paths.
    $results += Invoke-ProducerCase 'hardlink-alias-candidate-raw' { param($c)
        Remove-Item -LiteralPath $c.CandidatePath -Force
        try {
            New-Item -ItemType HardLink -Path $c.CandidatePath -Target $c.ObservationPath `
                -ErrorAction Stop | Out-Null
        } catch { throw "Hardlink fixture prerequisite failed: $($_.Exception.Message)" }
    } 'must have exactly one hard link'
    $results += Invoke-ProducerCase 'raw-parent-junction-rejected' { param($c)
        $real = Join-Path $c.Root 'raw-real'; New-Item -ItemType Directory $real | Out-Null
        $name = [IO.Path]::GetFileName($c.ObservationPath)
        Move-Item $c.ObservationPath (Join-Path $real $name)
        $alias = Join-Path $c.Root 'raw-alias'; New-Junction $alias $real
        $c.ObservationPath = Join-Path $alias $name
    } 'path must not contain a reparse point'
    $results += Invoke-ProducerCase 'candidate-directory-junction-alias' { param($c)
        $real = Join-Path $c.Root 'candidate-real'; New-Item -ItemType Directory $real | Out-Null
        Move-Item $c.CandidatePath (Join-Path $real 'viewflowd.exe')
        $alias = Join-Path $c.Root 'candidate-alias'; New-Junction $alias $real
        $c.CandidatePath = Join-Path $alias 'viewflowd.exe'
    } 'path must not contain a reparse point'
    $results += Invoke-ProducerCase 'raw-junction-parent-swap' { param($c)
        Configure-JunctionSwapCase $c
    } 'Raw daemon-exit observation changed after it was read'

    $results
} finally {
    foreach ($junction in @($junctions)) {
        try { Remove-Junction $junction } catch { Write-Warning $_.Exception.Message }
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    if ($KeepTestArtifacts) { Write-Warning "Preserved marker fixture artifacts: $testRoot" }
    else { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
