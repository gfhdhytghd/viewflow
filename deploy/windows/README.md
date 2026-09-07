# Windows build and in-place update gates

## Source package for the native build

There is one reviewed source-package entry point. Run it from the Linux
checkout after the workspace validation gate passes; the output must be outside
the source tree:

```bash
deploy/scripts/check-package-windows-source.sh
deploy/scripts/tests/package-windows-source-test.sh
deploy/scripts/package-windows-source.sh \
  --source /tmp/viewflow-windows-source-stage \
  /tmp/viewflow-windows-source.tar.gz
```

The packager excludes `.agents` and `.codex`, but fails closed on every file or
directory named `.git` or `target` at any depth. Package from a clean allowlisted
staging tree, not directly from a Git worktree or a Cargo build tree. The strict
top-level source allowlist rejects unknown root files or directories instead of
archiving or silently ignoring them. It rejects symlinks and special files,
reserved `SOURCE-MANIFEST.sha256` names anywhere in the source tree, deprecated
duplicate packager entry points, paths containing backslashes or line breaks,
other paths that Windows cannot represent, and case-insensitive path collisions.
Source file modes are normalized to
`0644`; ordering, ownership, timestamps, and the gzip header are normalized as
well. Each copied file and every source directory are checked against their
original identities to fail closed on a source change during packaging. The
generated archive is extracted and its full path set and manifest are verified
before publication. The packager writes an internal and external per-file
manifest and an archive checksum sidecar, backs up any prior three-file set,
and finally publishes the archive as the commit point. A normal publication
failure or published-artifact verification failure restores the entire prior
set.

Copy all three adjacent outputs to Windows. Verify the archive, extract into a
new unique directory, verify every extracted source file, and only then build.
The sequence below also rejects a checksum sidecar naming another archive,
unsafe or case-colliding archive paths, reparse points, duplicate manifest
paths, and any archive or extracted file not covered by the strict manifest.
The reviewed native build is intentionally locked and offline; dependency
acquisition is a separate preparation step:

```powershell
$ErrorActionPreference = 'Stop'
$archive = (Resolve-Path .\viewflow-windows-source.tar.gz).Path
$manifest = "$archive.manifest.sha256"
$archiveChecksum = "$archive.sha256"
foreach ($artifact in @($archive, $manifest, $archiveChecksum)) {
    $artifactItem = Get-Item -LiteralPath $artifact -Force
    if ($artifactItem.PSIsContainer -or
        ($artifactItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Source package artifact is not a regular file: $artifact"
    }
}

$checksumLine = (Get-Content -LiteralPath "$archive.sha256" -Raw).Trim()
if ($checksumLine -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
    throw 'Invalid archive checksum sidecar'
}
$expectedArchiveHash = $Matches[1].ToLowerInvariant()
$checksumArchiveName = $Matches[2]
$archiveName = [IO.Path]::GetFileName($archive)
if (-not [String]::Equals(
    $checksumArchiveName,
    $archiveName,
    [StringComparison]::Ordinal
)) {
    throw 'Archive checksum sidecar names a different file'
}
$actualArchiveHash = (
    Get-FileHash -LiteralPath $archive -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($actualArchiveHash -ne $expectedArchiveHash) {
    throw 'Source archive SHA-256 mismatch'
}

$pathComparer = [StringComparer]::OrdinalIgnoreCase
function Assert-WindowsSafeArchivePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Path.Contains('\') -or
        $Path.Contains('//') -or
        $Path.StartsWith('/') -or
        $Path -match '(^|/)\.\.?(/|$)') {
        throw "Unsafe ${Description}: $Path"
    }
    foreach ($component in $Path.Split('/')) {
        if ([String]::IsNullOrEmpty($component) -or
            $component -match '[\x00-\x1f\x7f<>:"|?*]' -or
            $component.EndsWith('.') -or
            $component.EndsWith(' ')) {
            throw "Windows-invalid ${Description}: $Path"
        }
        $deviceStem = $component.Split('.')[0].TrimEnd(
            [char[]]@(' ', '.')
        )
        if ($deviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            throw "Reserved Windows device name in ${Description}: $Path"
        }
    }
}

$archivePaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
$archiveFilePaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
$archiveEntries = @(& tar.exe -tzf $archive)
if ($LASTEXITCODE -ne 0) {
    throw "Source archive listing failed with exit code $LASTEXITCODE"
}
if ($archiveEntries.Count -eq 0) {
    throw 'Source archive is empty'
}
foreach ($rawArchiveEntry in $archiveEntries) {
    $isDirectoryEntry = $rawArchiveEntry.EndsWith('/')
    $archiveEntry = $rawArchiveEntry.TrimEnd('/')
    if ([String]::IsNullOrEmpty($archiveEntry) -or
        $archiveEntry -notmatch '^viewflow-source(?:/.*)?$') {
        throw "Unsafe source archive path: $rawArchiveEntry"
    }
    Assert-WindowsSafeArchivePath $archiveEntry 'source archive path'
    if (-not $archivePaths.Add($archiveEntry)) {
        throw "Duplicate or case-colliding source archive path: $archiveEntry"
    }
    if (-not $isDirectoryEntry) {
        [void]$archiveFilePaths.Add($archiveEntry)
    }
}
if (-not $archivePaths.Contains('viewflow-source/SOURCE-MANIFEST.sha256')) {
    throw 'Internal source manifest is absent from archive'
}
$postListingArchiveHash = (
    Get-FileHash -LiteralPath $archive -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($postListingArchiveHash -ne $expectedArchiveHash) {
    throw 'Source archive changed while being listed'
}

$extractRoot = Join-Path $PWD (
    'viewflow-build-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $extractRoot | Out-Null
& tar.exe -xzf $archive -C $extractRoot
if ($LASTEXITCODE -ne 0) {
    throw "Source archive extraction failed with exit code $LASTEXITCODE"
}
$postExtractionArchiveHash = (
    Get-FileHash -LiteralPath $archive -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($postExtractionArchiveHash -ne $expectedArchiveHash) {
    throw 'Source archive changed while being extracted'
}

$internalManifest = Join-Path $extractRoot 'viewflow-source\SOURCE-MANIFEST.sha256'
$sourceRoot = [IO.Path]::GetFullPath(
    (Join-Path $extractRoot 'viewflow-source')
)
$sourceRootItem = Get-Item -LiteralPath $sourceRoot -Force
if (-not $sourceRootItem.PSIsContainer -or
    ($sourceRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Extracted source root is not a regular directory'
}
foreach ($extractedItem in @(
    Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse
)) {
    if ($extractedItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Extracted source contains a reparse point: $($extractedItem.FullName)"
    }
}
$internalManifestItem = Get-Item -LiteralPath $internalManifest -Force
if ($internalManifestItem.PSIsContainer -or
    ($internalManifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Internal source manifest is not a regular file'
}
$externalManifestHash = (
    Get-FileHash -LiteralPath $manifest -Algorithm SHA256
).Hash.ToLowerInvariant()
$internalManifestHash = (
    Get-FileHash -LiteralPath $internalManifest -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($externalManifestHash -ne $internalManifestHash) {
    throw 'External and internal source manifests differ'
}
$manifestLines = @(Get-Content -LiteralPath $internalManifest)
if ($manifestLines.Count -eq 0) {
    throw 'Source manifest is empty'
}
$requiredSourcePaths = @(
    'viewflow-source/Cargo.toml',
    'viewflow-source/Cargo.lock',
    'viewflow-source/protocol/viewflow/v1/control.proto'
)
$verifiedSourcePaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
$sourcePrefix = $sourceRoot.TrimEnd('\') + '\'
foreach ($line in $manifestLines) {
    if ($line -notmatch '^([0-9a-fA-F]{64})  (viewflow-source/.+)$') {
        throw "Invalid source manifest line: $line"
    }
    $expectedFileHash = $Matches[1].ToLowerInvariant()
    $manifestPath = $Matches[2]
    Assert-WindowsSafeArchivePath $manifestPath 'source manifest path'
    if ([String]::Equals(
            $manifestPath,
            'viewflow-source/SOURCE-MANIFEST.sha256',
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Unsafe source manifest path: $manifestPath"
    }
    $relativeFile = $manifestPath.Substring('viewflow-source/'.Length) `
        -replace '/', [IO.Path]::DirectorySeparatorChar
    $fullFilePath = [IO.Path]::GetFullPath(
        (Join-Path $sourceRoot $relativeFile)
    )
    if (-not $fullFilePath.StartsWith(
        $sourcePrefix,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Source manifest path escapes the source root: $relativeFile"
    }
    if (-not $verifiedSourcePaths.Add($manifestPath)) {
        throw "Duplicate or case-colliding source manifest path: $manifestPath"
    }
    $sourceFileItem = Get-Item -LiteralPath $fullFilePath -Force
    if ($sourceFileItem.PSIsContainer -or
        ($sourceFileItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Manifest source path is not a regular file: $manifestPath"
    }
    $actualFileHash = (
        Get-FileHash -LiteralPath $fullFilePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($actualFileHash -ne $expectedFileHash) {
        throw "Source file SHA-256 mismatch: $manifestPath"
    }
}
foreach ($requiredSourcePath in $requiredSourcePaths) {
    if (-not $verifiedSourcePaths.Contains($requiredSourcePath)) {
        throw "Required source path is absent from manifest: $requiredSourcePath"
    }
}

$expectedArchiveFilePaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
foreach ($verifiedSourcePath in $verifiedSourcePaths) {
    [void]$expectedArchiveFilePaths.Add($verifiedSourcePath)
}
[void]$expectedArchiveFilePaths.Add(
    'viewflow-source/SOURCE-MANIFEST.sha256'
)
if ($archiveFilePaths.Count -ne $expectedArchiveFilePaths.Count) {
    throw 'Archive file set does not match the source manifest'
}
foreach ($expectedArchiveFilePath in $expectedArchiveFilePaths) {
    if (-not $archiveFilePaths.Contains($expectedArchiveFilePath)) {
        throw "Archive file is absent: $expectedArchiveFilePath"
    }
}

$extractedSourceFiles = [Collections.Generic.HashSet[string]]::new($pathComparer)
foreach ($sourceFile in @(
    Get-ChildItem -LiteralPath $sourceRoot -Force -Recurse -File
)) {
    if ([String]::Equals(
        $sourceFile.FullName,
        $internalManifest,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        continue
    }
    $relativeNativePath = $sourceFile.FullName.Substring($sourcePrefix.Length)
    $extractedManifestPath = 'viewflow-source/' + (
        $relativeNativePath -replace '\\', '/'
    )
    [void]$extractedSourceFiles.Add($extractedManifestPath)
}
if ($extractedSourceFiles.Count -ne $verifiedSourcePaths.Count) {
    throw 'Extracted source file set does not match the source manifest'
}
foreach ($verifiedSourcePath in $verifiedSourcePaths) {
    if (-not $extractedSourceFiles.Contains($verifiedSourcePath)) {
        throw "Manifest source file is absent after extraction: $verifiedSourcePath"
    }
}

Set-Location $sourceRoot
& cargo build --release -p viewflowd --locked --offline
if ($LASTEXITCODE -ne 0) {
    throw "Viewflow Windows build failed with exit code $LASTEXITCODE"
}
```

Packaging and verification do not stop, install, or restart either Viewflow
peer. Building a candidate still does not authorize deployment.

## In-place update gate

`install-viewflow.ps1` updates an already-running Viewflow peer. It must not be
used as the mechanism that quiesces input: stopping the scheduled task is a
hard process boundary and cannot release held keys or buttons by itself.

Before invoking the installer, the external Linux deployment controller and
the reviewed Windows marker producer must:

1. Publish and verify the owner-only, operation-bound durable Deskflow
   quarantine marker before the first mutation, then prove the loaded Deskflow
   instance refuses Viewflow route admission.
2. Ask the active route to clean up and observe the Windows `Applied` ACK for
   `ReleaseAll`, followed by the exact `Applied` `RevokedAck` for the lease
   revoke on the same authenticated peer epoch.
3. Arm and trigger the Linux daemon's one-shot quiescence path. The daemon must
   write its schema-4 receipt and exit.
4. Capture independent Linux evidence that the exact daemon instance, unit,
   UDP listener, and sidecar socket are gone.
5. Run `new-viewflow-quiesced-marker.ps1` on Windows. It strictly validates and
   combines the daemon receipt, compact exit evidence, hash-bound raw exit
   observation, candidate, installed artifacts, wrapper, and identity files
   into a fresh single-use schema-4 marker.
6. Keep durable quarantine active and the peer disconnected until the installer
   consumes the marker and stops the scheduled task. Quarantine remains active
   through both host installs and is not released by Windows installer success.

The marker is produced evidence, not an operator assertion. Schema 2 and the
legacy `release_all_applied`, `route_revoked`, and `peer_disconnected` booleans
are rejected. The producer accepts only two daemon-defined cleanup outcomes:
a daemon instance that never activated a route, or an exact receiver `Applied`
ACK followed by an exact receiver `Applied` lease-revoke ACK. Transport
delivery without that ACK, or an activated route without an exact bound peer,
is fail-closed and cannot produce a marker.

```json
{
  "schema_version": 4,
  "state": "viewflow-input-quiesced",
  "operation_id": "<daemon operation id>",
  "task_name": "\\Viewflow Peer",
  "peer": "172.16.105.62:44119",
  "device_id": "00000000000000000000000000000002",
  "protocol_version": "2.1",
  "daemon_instance_id": "<boot-id>-<pid>-<start-ticks>",
  "daemon_pid": 1234,
  "daemon_start_ticks": 123456789,
  "boot_id": "11111111-2222-3333-4444-555555555555",
  "daemon_sha256": "<Linux viewflowd SHA-256>",
  "local_device": "00000000000000000000000000000001",
  "target_device": "00000000000000000000000000000002",
  "cleanup": {
    "route_ever_activated": true,
    "route_was_active": true,
    "source_display": "00000000000000000000000000000003",
    "route_generation": 5,
    "active_lease_generation": 9,
    "last_input_sequence": 20,
    "release_all": {
      "status": "applied",
      "ack": {
        "lease_generation": 9,
        "target_device": "00000000000000000000000000000002",
        "event_sequence": 21,
        "result": "applied"
      }
    },
    "lease_revoke": {
      "status": "applied",
      "generation": 10,
      "ack": {
        "operation_id": "00000000000000040000000000000001",
        "lease_generation": 10,
        "owner_device": "00000000000000000000000000000001",
        "target_device": "00000000000000000000000000000002",
        "state": "revoked",
        "result": "applied"
      }
    },
    "bound_peer_epoch": 4,
    "bound_peer_socket": "172.16.105.70:49152"
  },
  "route_status": "removed",
  "peer_disconnect_status": "confirmed_by_daemon_exit",
  "daemon_exit_evidence": { "<bound Linux exit evidence>": "..." },
  "artifact_hashes": { "<the frozen ten-artifact hash set>": "..." },
  "completed_at_unix_ms": 1788036000000,
  "created_utc": "2026-08-29T18:00:00.0000000Z"
}
```

Create the marker only from the three evidence files and reviewed candidate:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\new-viewflow-quiesced-marker.ps1 `
    -RuntimeReceiptPath .\linux-quiescence-receipt.json `
    -DaemonExitEvidencePath .\linux-daemon-exit.json `
    -DaemonExitObservationPath .\viewflow-daemon-exit-observation.json `
    -CandidatePath .\viewflowd.exe `
    -ExpectedCandidateSha256 '<candidate SHA-256>' `
    -OutputPath .\viewflow-input-quiesced.json
```

The raw observation basename is part of the signed evidence contract and must
remain exactly `viewflow-daemon-exit-observation.json`. Renaming the file is a
validation failure even when its bytes and SHA-256 are unchanged.

Pass the marker path, candidate hash, and candidate binary together:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-viewflow.ps1 `
    -CandidatePath .\viewflowd.exe `
    -ExpectedSha256 '<candidate SHA-256>' `
    -ExpectedWrapperSha256 '<reviewed viewflow-client.ps1 SHA-256>' `
    -QuiescedMarkerPath .\viewflow-input-quiesced.json
```

The producer and installer independently revalidate the two schema-4 cleanup
branches. A never-active daemon must report both activation booleans as false,
both `not_required_no_active_route` statuses, and null route/ACK/peer fields.
Once activation has ever occurred, both booleans must remain true and the
receipt must carry the exact `ReleaseAll` Applied ACK, the next-generation
lease-revoke Applied ACK, and the bound Windows peer identity. The revoke ACK
must contain exactly `operation_id`, `lease_generation`, `owner_device`,
`target_device`, `state`, and `result`; its generation is active generation + 1,
its identities match the route, its state/result are `revoked`/`applied`, and
the operation identity binds the nonzero authenticated peer epoch. Historical
activation cannot be disguised as a currently inactive route; an activated
route without bound-peer evidence is rejected.

The installer also validates daemon and exit identity, timestamps, exact
ten-artifact set, current installed binary, wrapper, candidate, task, peer,
devices, and identity hashes. Before touching the installed files it also
validates:

- the existing scheduled task to be the running current-user Viewflow task and
  to invoke the installed wrapper with Windows PowerShell 5.1;
- the task principal to resolve to the current installer's user SID, with an
  interactive limited token;
- base64-decodable PEM material at `identity\peer.pem`, `identity\peer.key`, and
  `identity\ca.pem` (certificate blocks are parsed as X.509), plus those exact
  paths on the running daemon command line.

Before the first task mutation, the installer copies the old binary and
wrapper and installs the standalone rollback tool. It then atomically renames
the fresh marker in the same directory to
`<stem>.consumed.<operation_id><extension>`. The consumed file is retained and
its SHA-256 must remain unchanged; the installer revalidates the consumed copy
and its operation ID. Direct deletion is not an authorization boundary and is
forbidden.

After `Stop-ScheduledTask`, both the task and the exact installed daemon must
remain stopped for six continuous seconds before replacement begins. This
window is longer than the wrapper's five-second maximum restart delay, so a
surviving supervisor cannot silently pull the old daemon back up between the
stop check and file replacement. The installer exports and hashes the old task
XML before mutation. A bootstrap then publishes the rollback manifest and
token before force-release or replacement. Registration must leave the new
definition `Ready`; only the later explicit start may make it `Running`. The
normalized task uses the exact
`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` path, the current
user's SID, an interactive limited token, one enabled instance, battery-safe
continuous operation, unlimited execution time, hard-termination support, and
no Task Scheduler restart policy. The foreground wrapper is the sole restart
supervisor.

A successful return proves replacement and process startup only. Authenticated
peer health and the input probe must be verified separately. Startup itself is
not a one-sample PID check: the task must remain `Running`, with exactly one
unchanged Session 1 daemon PID and a valid command line, for six continuous
seconds. The normal update also requires a `protocol 2.1 connecting` line added
to the wrapper log after this start began.

Any failure after authorization consumption restores the old binary, wrapper,
and task definition, then applies the stable stop gate again after task
registration. The required failure state is task `Ready` with zero exact
installed `viewflowd.exe` processes. Neither the installer failure path nor the
standalone rollback tool starts the restored task. This is deliberate: a
failed cross-host transaction must remain inactive until both hosts are
inspected and a new deployment or explicit operator start is authorized.

## Protocol 1.3 to 2.1 bootstrap

The `BOOTSTRAP-v1.3-to-v2.md` path and `viewflow-v2-*` state/file names are
retained for compatibility; they now describe and require protocol 2.1.

Bootstrap is request-only. The reviewed launcher creates a protected operation
directory at
`%LOCALAPPDATA%\Viewflow\Deployments\<32-lowercase-hex-operation-id>`, copies
and verifies all reviewed inputs there, publishes an owner-only create-once
`request.json`, and starts a Session-1 worker. The worker invokes the installer
with exactly one argument:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\start-viewflow-bootstrap.ps1 `
    -Mode Start `
    -RequestPath "$env:LOCALAPPDATA\Viewflow\Deployments\<operation-id>\request.json"
```

Directly supplying `-AllowV13Bootstrap` or a second installer parameter is
forbidden. The installer pins the exact request bytes and the H marker-handoff
receipt for the whole transaction. All input paths and output paths have fixed
basenames in the operation root; inputs are regular, owner-only, hash-bound
files, and outputs must be absent and pairwise distinct.

The bootstrap publication order is:

1. Back up the old binary, wrapper, and task XML; install and hash-check the
   reviewed rollback tool; publish owner-only create-once rollback manifest M
   and token T.
2. Publish P with `state=viewflow-windows-bootstrap-recovery-armed`. P binds
   request/H/B hashes, candidate, wrapper, rollback script, M/T, the old task
   and exact old process identity, plus fixed permit/raw-F/F-envelope/Ls/W/exit
   and rollback paths. No task stop, force release, replacement, or start is
   permitted before P.
3. Wait for and strictly validate the coordinator's owner-only create-once
   mutation permit. It binds request/H/P/B, candidate/wrapper/rollback/M/T and
   the three reviewed Linux candidate hashes. Absence or mismatch of the permit
   leaves the old task untouched.
4. Consume the bootstrap authorization, stable-stop `\Viewflow Peer`, run the
   Session-1 force-release helper, and publish the create-once F envelope. The
   envelope binds request/H/P/permit/B and the raw force-release receipt.
5. Install and start the candidate, then wait for Ls with
   `state=viewflow-linux-bootstrap-staged`. Ls must bind request/H/P/permit/F,
   preserve the inactive Deskflow boundary and absent `VFQST002`, prove a new
   authenticated Windows peer, and make its three staged artifact hashes equal
   the permit's three Linux hashes.
6. Only after valid Ls does the 120-second bootstrap readiness timer begin.
   The daemon-mediated schema-5 commit request and W receipt bind six distinct
   lowercase hashes: raw F, H, P, permit, Ls, and request. Normal-v2 updates
   carry all six fields explicitly as `null` and retain a 30-second commit
   wait. The daemon's create-once W rename is the install commit point.

The launcher writes a create-once `installer-exit.json` after the child exits;
it binds the request and launcher claim and discriminates exit code zero from a
failed exit. Poll launcher status and the fixed P/F/Ls/W/exit paths rather than
starting another installer. After P, any installer failure contains the main
task as stable `Ready` with zero exact processes and retains the reviewed
rollback script plus M/T for external recovery. It does not silently restart
the old or new peer.

## Standalone rollback after a successful bootstrap

The manifest and token remain valid after a successful install so the reviewed
standalone tool can restore the exact v1.3 baseline without calling the
installer. Validate the entire contract without mutation first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\rollback-viewflow.ps1 `
    -ManifestPath $rollbackManifest `
    -TokenPath $rollbackToken `
    -ValidateOnly
```

Then perform the one-shot rollback and create a new completion receipt:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\rollback-viewflow.ps1 `
    -ManifestPath $rollbackManifest `
    -TokenPath $rollbackToken `
    -ReceiptPath 'C:\ViewflowBootstrap\viewflow-rollback-completed.json'
```

The tool requires the exact installed protocol-2.1 task and one valid Session-1 process,
revalidates all manifest/token/path/hash/user/task/XML contracts, and atomically
renames the token to an operation-scoped consumed path before mutation. It
stable-stops the task, restores the binary and wrapper atomically, registers the
verified baseline task XML, and leaves the task `Ready` with zero exact
processes for six continuous seconds. Its optional schema-1
`viewflow-windows-rollback-completed` receipt records that inactive state. A
rollback failure also attempts inactive containment and never starts the task.

Run the static contracts before copying the scripts to Windows:

```bash
deploy/windows/check-viewflow-client.sh
deploy/windows/check-quiesced-marker-producer.sh
```

On Windows PowerShell 5.1, also run the AST and receipt fixtures:

```powershell
.\test-scheduled-task-contract.ps1
.\test-force-release-receipt-contract.ps1
.\test-quiesced-marker-producer.ps1
.\test-rollback-viewflow-static.ps1
.\test-bootstrap-recovery-prepared.ps1
.\test-bootstrap-chain-contract.ps1
.\test-install-success-schema5.ps1
.\test-readiness-disconnect-before-commit.ps1
```
