# Windows post-mTLS readiness evidence

This contract is the deployment gate for a Windows `viewflowd connect` process.
Process existence, Scheduled Task state, and the pre-handshake `connecting` log
are not authenticated readiness.

## Daemon command line

The wrapper must invoke the installed daemon with all of the following options:

```text
viewflowd connect <normal transport and identity options> \
  --input-backend native \
  --device-id <32 lowercase hexadecimal digits> \
  --readiness-receipt <absolute receipt path> \
  --readiness-lock <different absolute lock path> \
  --readiness-commit-request <absolute request path> \
  --install-success-receipt <absolute success path> \
  --operation-id <deployment operation ID>
```

The three readiness options are an all-or-none group. Readiness requires the
native input backend and a local device ID. Evidence publication is supported
only on Windows and only from Session 1.

The two commit paths are a second all-or-none group and are valid only with the
readiness group. All four artifact paths must be different. The request and
result paths come only from the command line; request JSON cannot redirect the
daemon to another output path.

## Publication point and latency qualification

The daemon publishes evidence only after all of these events have happened for
the same connection generation:

1. the QUIC mutual-TLS handshake completed;
2. the control writer started;
3. the native input receiver was constructed;
4. the client receiver processed a clock reply; and
5. a clock probe measured RTT at most `33333334` ns and uncertainty at most
   `4000000` ns.

Both files use an owner-only DACL and create-once semantics. The receipt is
written to an owner-only temporary file, flushed, and moved into place without
replacement. The lock is created with `CREATE_NEW`, flushed, and held open by
the daemon with read/write access and `FILE_SHARE_READ`.

## Exact receipt schema

The receipt is UTF-8 JSON with `schema_version = 1`, no missing fields, and no
unknown fields. Its exact property set is:

```text
schema_version
state
validity
operation_id
daemon_executable_sha256
daemon_pid
daemon_process_start_filetime
daemon_session_id
daemon_user_sid
connection_generation
input_backend
local_device_id
peer_address
server_name
protocol_major
protocol_minor
probe_round_trip_ns
probe_max_round_trip_ns
probe_uncertainty_ns
probe_max_uncertainty_ns
readiness_lock_path
readiness_lock_sha256
established_at_utc
```

Fixed values are:

```text
schema_version = 1
state = "viewflow-post-mtls-readiness-established"
validity = "while-readiness-lock-is-held"
daemon_session_id = 1
input_backend = "native"
protocol_major = 2
protocol_minor = 1
probe_max_round_trip_ns = 33333334
probe_max_uncertainty_ns = 4000000
```

`daemon_process_start_filetime` is a canonical decimal string, not a JSON
number. Both SHA-256 values are exactly 64 lowercase hexadecimal digits.
`local_device_id` is exactly 32 lowercase hexadecimal digits.
`established_at_utc` is UTC with millisecond precision.

## Exact live-lock schema

The lock is UTF-8 JSON with no unknown fields and this exact property set:

```text
schema_version
state
operation_id
daemon_pid
daemon_process_start_filetime
connection_generation
```

Its fixed values are:

```text
schema_version = 1
state = "viewflow-post-mtls-readiness-lock"
```

The receipt's `readiness_lock_sha256` must hash the exact lock-file bytes,
including the final newline.

## Lease lifetime and reconnects

The receipt is valid only while the matching lock is held. On disconnect the
daemon removes the receipt before closing the lock handle, then deletes the
lock. It continues its normal reconnect loop and increments
`connection_generation`. A later generation must complete a new mTLS handshake
and qualifying clock probe before it creates new evidence.

If a verifier briefly pins a file and revocation cannot remove both files, the
next generation may reclaim only a strict old-generation orphan belonging to
the same operation ID, PID, and process-start FILETIME. The daemon claims each
artifact with an exclusive, non-reparse-point handle, limits it to 64 KiB,
strictly parses it, verifies an exact receipt-to-lock hash when both exist, and
deletes by those same handles. Generation zero, current/future generations,
other process identities, other operations, malformed JSON, unknown fields,
semantic mismatches, reparse points, and a lock that is still held all fail
closed. Crash residue from a previous process instance is never reclaimed.

## Installer validation and commit boundary

The installer must perform the following sequence against the expected
operation ID, installed binary hash, task identity, device ID, server name,
peer, receipt path, and lock path:

1. Open and pin the receipt for read with `FileShare.Read`.
2. Open and pin the lock for read with `FileShare.ReadWrite`. The daemon holds
   the lock with write access, so `FileShare.Read` alone is incompatible.
3. Read receipt bytes/hash A and lock bytes/hash L from the pinned handles.
4. Strictly parse both exact schemas and validate every expected value.
5. Verify the exact daemon PID exists and its process-start FILETIME, Session 1,
   user SID, executable path/hash, task principal, and wrapper command line all
   match the evidence and deployment inputs.
6. Require the receipt lock path to equal the configured path and the receipt
   lock hash to equal L.
7. Attempt a second lock open for write with compatible sharing. Only Windows
   `ERROR_SHARING_VIOLATION` (32) proves that a live holder rejected the write.
   `NOT_FOUND`, `ACCESS_DENIED`, and every other error fail closed. A successful
   write open means the lock is not live and also fails.
8. Rewind the pinned handles and read receipt bytes/hash B and lock bytes/hash
   L2. Require A equals B and L equals L2.
9. Repeat the process identity checks and the live-lock write probe immediately
   before the irreversible commit boundary. Require both files still exist and
   remain pinned throughout validation.

The timestamp is only a freshness bound. The causal binding is the operation
ID, PID plus process-start FILETIME, connection generation, exact executable
hash, and live lock.

During a `1.3 -> 2.1` bootstrap, Windows may be installed before a Linux v2.1
peer is available. That state must be reported only as installed, never as
authenticated-ready. The coordinator completes the two-ended readiness gate
after Linux v2.1 is running.

## Daemon-mediated install commit

The installer does not publish the final install-success receipt. After it has
validated and pinned the live readiness receipt and lock, it atomically creates
the configured commit-request file. The daemon polls for that path only after
it holds the matching `ReadinessGuard`.

The request is UTF-8 JSON with `schema_version = 5`, no missing or unknown
fields, and this exact property set:

```text
schema_version
state
mode
operation_id
commit_nonce
daemon_pid
daemon_process_start_filetime
connection_generation
readiness_receipt_sha256
readiness_lock_sha256
linux_frozen_evidence_sha256
force_release_receipt_sha256
marker_handoff_receipt_sha256
windows_prepared_receipt_sha256
mutation_permit_sha256
linux_stage_receipt_sha256
bootstrap_request_sha256
old_viewflow_executable_sha256
new_viewflow_executable_sha256
installed_wrapper_sha256
scheduled_task_xml_sha256
requested_at_utc
```

Fixed values and mode rules are:

```text
schema_version = 5
state = "viewflow-install-commit-request"
mode = "normal-v2" | "bootstrap-v1.3"
commit_nonce = 32 lowercase hexadecimal digits
force_release_receipt_sha256 = null                  (normal-v2 only)
force_release_receipt_sha256 = 64 lowercase hex      (bootstrap-v1.3 only)
marker_handoff_receipt_sha256 = null                 (normal-v2 only)
windows_prepared_receipt_sha256 = null               (normal-v2 only)
mutation_permit_sha256 = null                        (normal-v2 only)
linux_stage_receipt_sha256 = null                    (normal-v2 only)
bootstrap_request_sha256 = null                      (normal-v2 only)
marker_handoff_receipt_sha256 = 64 lowercase hex     (bootstrap-v1.3 only)
windows_prepared_receipt_sha256 = 64 lowercase hex   (bootstrap-v1.3 only)
mutation_permit_sha256 = 64 lowercase hex            (bootstrap-v1.3 only)
linux_stage_receipt_sha256 = 64 lowercase hex        (bootstrap-v1.3 only)
bootstrap_request_sha256 = 64 lowercase hex          (bootstrap-v1.3 only)
```

All six bootstrap-only fields must be explicitly present. They may not be
omitted: normal mode encodes each as JSON `null`, while bootstrap mode encodes
six distinct 64-character lowercase hashes so one evidence binding cannot be
substituted for another. Every other SHA-256 field is exactly 64 lowercase
hexadecimal digits.
`requested_at_utc` uses canonical UTC millisecond form. The operation ID,
daemon PID plus process-start FILETIME, generation, and both readiness hashes
must exactly equal the live guard binding.

The connection-termination branch has priority over commit polling. Once a
request is observed, request pinning, strict parsing, guard validation,
success serialization, flush, and publication are synchronous: there is no
`await` while the daemon authorizes the commit. Immediately before publication
the daemon verifies that the guard still owns its lock and
`Connection::close_reason()` is still empty.

The daemon creates the final owner-only success receipt without replacement.
It flushes an owner-only temporary file and performs a same-directory,
write-through `MoveFileExW` without a replace flag. That move is the commit
linearization point. A disconnect before it prevents publication; a disconnect
after it cannot revoke an already committed install transaction.

The daemon-authored success receipt uses the exact schema-5 install fields and
adds the commit binding. Its exact property set is:

```text
schema_version
state
operation_id
commit_nonce
commit_request_sha256
commit_mode
committed_by_daemon
linux_frozen_evidence_sha256
force_release_receipt_sha256
marker_handoff_receipt_sha256
windows_prepared_receipt_sha256
mutation_permit_sha256
linux_stage_receipt_sha256
bootstrap_request_sha256
readiness_receipt_sha256
readiness_lock_sha256
readiness_connection_generation
readiness_established_at_utc
old_viewflow_executable_sha256
new_viewflow_executable_sha256
installed_wrapper_sha256
scheduled_task_xml_sha256
new_process_pid
new_process_start_filetime
new_process_session_id
new_process_user_sid
protocol_version
peer
device_id
completed_at_utc
committed_at_utc
```

Fixed values are `schema_version = 5`,
`state = "viewflow-v2-windows-installed"`, `protocol_version = "2.1"`, and
`committed_by_daemon = true`. `commit_request_sha256` hashes the exact pinned
request bytes. The six bootstrap-only bindings are copied exactly from that
strict request: all are explicit `null` for `normal-v2`, and all are distinct
64-character lowercase hashes for `bootstrap-v1.3`. Process, peer, device,
readiness generation, and readiness timestamps are copied from the live guard,
not accepted from installer JSON.
