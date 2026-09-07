# Deployment quarantine marker v1

This contract defines the deployment-owned marker that suppresses Viewflow
route admission while a cross-host update is in progress. It is not Deskflow's
runtime route-recovery marker.

## Namespace separation

| Purpose | Environment variable | Linux path | Magic | Size | Owner |
|---|---|---|---|---:|---|
| Deployment transaction | `DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER` | `/home/wilf/.local/state/viewflow/deployment-quarantine.v1` | `VFDQT001` | 256 | cross-host coordinator |
| Runtime uncertain-route recovery | `DESKFLOW_VIEWFLOW_QUARANTINE_MARKER` | `/home/wilf/.local/state/viewflow/deskflow-quarantine.v2` | `VFQST002` | 152 | Deskflow sidecar client |

Neither path, environment variable, magic, encoder, decoder, nor lifecycle
owner may be shared. In particular, the coordinator must never publish bytes at
the runtime path, and the Deskflow runtime recovery code must never remove the
deployment marker.

## Binary layout

All integers are unsigned little-endian. All unused and padding bytes must be
zero. A reader rejects a file whose size is not exactly 256 bytes.

| Offset | Length | Field | Required value |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `VFDQT001` |
| 8 | 1 | schema version | `1` |
| 9 | 1 | state | `1` (`active`) |
| 10 | 1 | protocol major | `2` |
| 11 | 1 | protocol minor | `1` |
| 12 | 1 | lifecycle owner | `1` (`cross-host coordinator`) |
| 13 | 1 | operation ID length | 16 through 128 |
| 14 | 2 | reserved | zero |
| 16 | 128 | operation ID | ASCII `[A-Za-z0-9_-]`, then zero padding |
| 144 | 16 | source display | non-zero binary ID |
| 160 | 16 | target device | non-zero binary ID |
| 176 | 16 | coordinator instance | non-zero binary ID |
| 192 | 8 | creation time | non-zero Unix milliseconds; audit/freshness only |
| 200 | 8 | generation | non-zero transaction marker generation |
| 208 | 48 | reserved | zero |

Cross-host wall-clock time is not an authorization input. Authorization is the
exact tuple `(operation ID, coordinator instance, generation, SHA-256 of all
256 bytes)`.

## Producer and release rules

The coordinator is the only producer and releaser.

1. The parent is an absolute, real directory owned by the expected uid with
   exact mode `0700`.
2. Publication writes an owner-only `0600` temporary regular file, syncs the
   file, atomically renames it with no-replace semantics, then syncs the parent.
   Any existing destination, including a dangling symlink, aborts publication.
3. The published file must be a regular non-symlink file owned by the expected
   uid, with exact mode `0600`, link count 1, and exact size 256.
4. Recovery and rollback never emit a protocol-2.1 release. A failed
   one-time v1.3 bootstrap may instead use the separately authorized abort
   transaction below after the exact old v1.3 baseline is authenticated on
   both hosts.
5. All production publishers, releasers, recovery processes, and Deskflow
   admission readers coordinate through the fixed lock
   `/home/wilf/.local/state/viewflow/.deployment-quarantine.v1.lock`. It is an
   owner-uid, mode `0600`, regular non-symlink file with link count 1 and no
   POSIX access ACL. Writers hold `LOCK_EX`; Deskflow holds `LOCK_SH` across
   checking both quarantine names and completing the sidecar activation
   handshake. A replaced, linked, re-permissioned, or ACL-bearing lock is
   unsafe storage and fails closed.
6. The only release claim name is
   `/home/wilf/.local/state/viewflow/deployment-quarantine.v1.release-claim`.
   It contains the exact original 256 `VFDQT001` bytes and has the same owner,
   `0600`, regular-file, non-symlink, single-link, and no-access-ACL contract as
   the active marker. The release authorization is still the exact operation,
   coordinator instance, generation, and marker SHA-256 tuple.
7. Release atomically renames active to claim with no-replace semantics and
   syncs the parent. It then create-once commits and syncs the durable binary
   receipt described below. Only after re-opening and revalidating the claim
   does it unlink the claim and sync the parent. That final unlink plus parent
   sync is the application release point. A committed receipt while claim is
   still present is not release and must continue to block admission.
8. A crash is recovered by invoking `release` again with the identical tuple.
   An exact claim is resumed; an exact committed receipt is replayed. Any
   different tuple, unsafe file, mutation, or name swap is rejected and the
   claim is retained. Active absent plus claim absent is never called released
   without an exact committed receipt.

The release and abort claims are mutually exclusive. Publication requires
both names absent. A release refuses an abort claim, and an abort refuses a
release claim; neither transaction may reinterpret or delete the other
transaction's claim or receipt.

## Durable release receipt v1

The content-addressed receipt path is
`.deployment-quarantine.v1.release-receipt.<marker-sha256>.v1` in the marker
parent. It is create-once, owner-only mode `0600`, regular, non-symlink,
single-link, has no POSIX access ACL, and is exactly 352 bytes. Content
addressing permits later deployment generations without overwriting earlier
proof. All unused bytes are zero.

| Offset | Length | Field | Required value |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `VFDQR001` |
| 8 | 1 | schema | `1` |
| 9 | 1 | state | `1` (`committed`) |
| 10 | 1 | protocol major | `2` |
| 11 | 1 | protocol minor | `1` |
| 12 | 1 | lifecycle owner | `1` (`cross-host coordinator`) |
| 13 | 3 | reserved | zero |
| 16 | 256 | original marker | complete validated `VFDQT001` bytes |
| 272 | 32 | marker hash | SHA-256 of bytes 16 through 271 |
| 304 | 8 | commit time | non-zero Unix milliseconds, little-endian |
| 312 | 8 | reserved | zero |
| 320 | 32 | receipt hash | SHA-256 of bytes 0 through 319 |

## Failed-v1.3 deployment abort contract

`abort` terminalizes only a failed one-time v1.3 bootstrap after the exact old
Linux and Windows baseline has been restored and a new authenticated v1.3 peer
observation has been frozen. It is not a successful deployment release, does
not assert protocol 2.1, and does not assert HID cleanup. Its JSON state is
exactly `deployment-quarantine-aborted`, with `protocol_version="1.3"`,
`protocol_2_1=false`, and `deployment_release_claimed=false`.

The abort authorization is a fixed absolute owner-only path passed together
with the SHA-256 of its complete strict JSON bytes. The file must be an
owner-uid, mode `0600`, regular non-symlink, single-link file with no POSIX
access ACL and no unknown or duplicate keys. Its exact schema is:

- `schema_version=1`
- `state="viewflow-deployment-quarantine-abort-authorized"`
- exact `operation_id`, canonical `coordinator_instance_id`, decimal-string
  `marker_generation`, lowercase `marker_sha256`, and the exact
  `authorization_receipt_path`
- lowercase SHA-256 fields `marker_handoff_receipt_sha256`,
  `deployment_publish_receipt_sha256`, `linux_frozen_evidence_sha256`,
  `windows_force_envelope_sha256`, `windows_migration_receipt_sha256`,
  `windows_claim_resolution_sha256`, `old_linux_viewflowd_sha256`,
  `old_linux_deskflow_sha256`, `old_linux_deskflow_core_sha256`,
  `old_windows_viewflowd_sha256`, `old_windows_wrapper_sha256`,
  `linux_v13_started_receipt_sha256`,
  `windows_v13_started_receipt_sha256`, and
  `authenticated_v13_peer_receipt_sha256`
- `initial_force_release_executed=true`,
  `second_force_release_executed=false`, `rollback_token_consumed=false`, and
  `protocol_2_1=false`

A distinct schema-2 authorization is used only for the failed-installer branch
whose immutable coordinator state records `mutation_possible=false` and no
accepted force-release transaction. It has state
`viewflow-deployment-quarantine-failed-pre-mutation-installer-baseline-restored-abort-authorized`, preserves the
same marker/coordinator identity and old Linux/Windows artifact hashes, and
replaces the force/migration/claim hashes with exact lowercase SHA-256 fields
for the failed installer-exit receipt, launcher stop evidence, pre-mutation
retry proof, and a freshly captured read-only Windows live proof. The live
proof includes byte hashes for the remote launcher claim, installer-process
receipt, stdout, and stderr; the raw remote stop and exit receipts must be
byte-identical to their committed local copies. It also binds the old Windows
task XML and installed rollback-script hashes. Its remaining proof hashes bind the Linux
frozen evidence, both newly started v1.3 receipts, and the fresh authenticated
v1.3 peer receipt.  It requires
`initial_force_release_executed=false`, `rollback_performed=false`,
`windows_rollback_receipt_sha256=null`, and `protocol_2_1=false`.  Unknown,
missing, mixed-schema, or duplicate fields are rejected.  Schema 1 remains the
only authorization for a bootstrap that actually entered rollback.

“Baseline restored” is deliberately a current-state claim.  An installer was
dispatched and returned exit 1 without a reason field, so this schema does not
claim that no historical write occurred.  It authorizes abort only because the
immutable coordinator state records `mutation_possible=false` and a fresh
read-only proof shows that the complete old task/process/artifact tuple is
currently exact.

The schema-2 JSON abort receipt is likewise distinct: it reports
`schema_version=2`, `initial_force_release_executed=false`,
`rollback_performed=false`, and `windows_rollback_receipt_sha256=null`.  The
VFDQA001 binary format and content-addressed receipt naming are unchanged; the
authorization SHA already commits to which authorization schema was used.

A mutually exclusive schema-3 authorization is reserved for the earlier
no-worker branch: coordinator schema 2 is already `LINUX_RECOVERED`, its
`failure_phase` is null, `mutation_possible=false`, and its committed map is
exactly H, B, the generation-1 publish receipt, bootstrap request, and
`viewflow-windows-bootstrap-no-worker-stopped` evidence.  The authorization
state is
`viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized`.
It binds the complete coordinator-state SHA, those five artifact SHAs, the
old Linux Viewflow/Deskflow/deskflow-core bytes, old Windows executable,
wrapper, task XML and rollback bytes, fresh Linux and Windows v1.3 started
proofs, a fresh authenticated peer probe, and the reviewed Windows live proof.
All evidence hashes must be nonzero; the sole all-zero sentinel remains the
`status_sha256` inside no-worker stop evidence.

Schema 3 also encodes the semantic branch as
`coordinator_failure_phase=null` and `coordinator_mutation_possible=false`.
It requires zero Windows bootstrap workers and installer processes, absent new
operation root and task, no mutation permit, no initial/ordinary force release,
no rollback or rollback receipt, no Deskflow start or input producer, and
`protocol_2_1=false`. Unknown, duplicate, missing, or mixed-schema fields fail
closed. The schema-3 JSON receipt repeats the state hash, five committed proof
hashes, three fresh v1.3 proof hashes, and every fixed null/false/zero claim so
the selected branch is visible without interpreting the binary receipt. The
VFDQA001 binary layout remains unchanged and commits to the schema-3 bytes via
its authorization hash.

The fixed abort claim is
`deployment-quarantine.v1.abort-claim`. Abort atomically renames the active
marker to that claim with no-replace semantics and syncs the parent, commits a
content-addressed binary receipt with no-replace semantics and syncs it, then
reopens and revalidates the exact claim before unlinking it and syncing the
parent. The final claim unlink plus parent sync is the abort point. A crash is
recovered by repeating `abort` with the identical marker and authorization
tuples. A committed receipt while the claim remains is
`deployment-quarantine-abort-committed-pending-abort` and remains
quarantined.

The binary receipt path is
`.deployment-quarantine.v1.abort-receipt.<marker-sha256>.<authorization-sha256>.v1`.
It has the same owner/mode/type/link/ACL contract as the release receipt and is
exactly 384 bytes:

| Offset | Length | Field | Required value |
|---:|---:|---|---|
| 0 | 8 | magic | ASCII `VFDQA001` |
| 8 | 1 | schema | `1` |
| 9 | 1 | state | `1` (`committed`) |
| 10 | 1 | protocol major | `1` |
| 11 | 1 | protocol minor | `3` |
| 12 | 1 | lifecycle owner | `1` (`cross-host coordinator`) |
| 13 | 3 | reserved | zero |
| 16 | 256 | original marker | complete validated `VFDQT001` bytes |
| 272 | 32 | marker hash | SHA-256 of bytes 16 through 271 |
| 304 | 32 | authorization hash | SHA-256 of strict authorization JSON |
| 336 | 8 | commit time | non-zero Unix milliseconds, little-endian |
| 344 | 8 | reserved | zero |
| 352 | 32 | receipt hash | SHA-256 of bytes 0 through 351 |

## Deskflow C++ consumer rules

The consumer reads only the deployment environment variable and format above.
The shipped drop-in should bind that variable exactly once to the fixed path.

- Missing active marker and missing release claim: deployment quarantine is
  inactive only after the shared-lock observation. A receipt is proof for
  release replay, not a quarantine name.
- Either a valid active marker or valid release claim: deployment quarantine
  is active.
- Valid marker matching the configured source display and target device:
  refuse Viewflow route admission and suppress ordinary Deskflow fallback for
  that route.
- Present but unsafe, malformed, unsupported, or route-mismatched marker:
  fail closed and refuse all Viewflow route admission. Log the reason without
  logging marker bytes.
- The reader must open the parent, fixed lock, active marker, and claim with
  no-follow semantics and apply the owner/mode/link-count/size/ACL checks above
  before decoding.
- The reader must recheck immediately before every route admission. Directory
  notifications may reduce polling, but are never the sole correctness gate.
  Therefore a coordinator deletion can release quarantine without restarting
  Deskflow, while a malformed replacement cannot silently release it.
- The reader never repairs, overwrites, or removes this marker. It reports the
  observed operation, coordinator instance, generation, and content SHA-256 to
  the readiness verifier; only the coordinator performs release.

The Rust golden tests in `crates/viewflow-deployment-marker/tests` freeze the
wire offsets and storage semantics for the C++ implementation. The canonical
test vector uses operation `deploy-20260829-0001`, source bytes `0x11`, target
bytes `0x22`, coordinator bytes `0x33`, creation bytes
`08 07 06 05 04 03 02 01`, and generation bytes
`18 17 16 15 14 13 12 11`; its complete 256-byte SHA-256 is
`f06d30a845877b3400882f7ab3749eb9c8d9d5f7eeaaebe260d946edecb6b4a8`.

## Coordinator CLI

The production binary is installed transactionally at
`/home/wilf/.local/lib/viewflow/viewflow-deployment-marker`. The installer
requires a reviewed release-built candidate and exact SHA-256, verifies uid
1000/mode `0755`/link count 1, backs up and restores it during rollback, and
requires that no process is executing the installed path while it is replaced.
The installer and deactivator never invoke `publish` or `release`, and
`viewflow-peer.service` never references the binary; it is coordinator-only.
The binary has no path override and always uses the fixed marker path above
with the effective uid as the expected owner. All UUIDs are canonical
lowercase, hyphenated, and non-zero.
All generation and Unix-millisecond values in receipts are decimal strings so
that JSON consumers cannot lose `u64` precision.

Publication:

```text
viewflow-deployment-marker publish \
  --operation-id OPERATION \
  --source-display-id UUID \
  --target-device-id UUID \
  --coordinator-instance-id UUID \
  --marker-generation DECIMAL_U64
```

For the one-time v1.3 bootstrap, do not invoke `publish` ad hoc. Protocol 1.3
does not recognize this marker, so first stop legacy Deskflow externally. Then
run `deploy/prepare-v13-marker-handoff.sh` before any collector or Windows
installer. The helper requires the Deskflow unit inactive with `MainPID=0`,
both exact Deskflow/core process counts zero, TCP 24800 listener count zero,
and legacy `VFQST002` absent. It freezes and verifies the reviewed release
candidate, atomically installs only the marker CLI at the fixed path, proves no
process is executing it, then invokes that installed path exactly once for
generation 1. It publishes the JSON receipt with a same-directory create-once
hard link, mode `0600`, and durable file/directory updates. Both the marker and
receipt are owner-1000, non-symlink, single-link regular files. A second
create-once H receipt binds the publish receipt hash, marker/CLI identities,
legacy executable hashes, and every frozen-boundary observation. A later
coordinator consumes both prepublished receipts; it must not republish
generation 1. Recovery uses a separately authorized generation 2 publication.

The tool obtains creation time from its own system clock. A successful publish
writes exactly one compact JSON object plus one newline to stdout, with exactly
these keys: `schema_version=1`,
`state="deployment-quarantine-published"`, `protocol_version="2.1"`,
`operation_id`, `source_display_id`, `target_device_id`,
`coordinator_instance_id`, `marker_generation`, `marker_path`,
`marker_sha256`, `created_at_unix_ms`, and `created_at_utc`.

Release:

```text
viewflow-deployment-marker release \
  --operation-id OPERATION \
  --coordinator-instance-id UUID \
  --marker-generation DECIMAL_U64 \
  --marker-sha256 LOWERCASE_HEX
```

Read-only exact-tuple state query uses the same options with `query` instead of
`release`. It returns one of `deployment-quarantine-active`,
`deployment-quarantine-release-claimed`,
`deployment-quarantine-release-committed-pending-release`, or
`deployment-quarantine-released`. The pending state is explicitly still
quarantined. A released response requires claim absence and a valid committed
receipt.

Failed-v1.3 abort:

```text
viewflow-deployment-marker abort \
  --operation-id OPERATION \
  --coordinator-instance-id UUID \
  --marker-generation DECIMAL_U64 \
  --marker-sha256 LOWERCASE_HEX \
  --abort-authorization-path ABSOLUTE_OWNER_ONLY_PATH \
  --abort-authorization-sha256 LOWERCASE_HEX
```

Abort query uses `query` with that complete abort option set. Its union is
`deployment-quarantine-active`, `deployment-quarantine-abort-claimed`,
`deployment-quarantine-abort-committed-pending-abort`, or
`deployment-quarantine-aborted`. The authorization path and hash remain
mandatory for query and replay; an abort receipt is never accepted through the
release query union.

A successful release writes exactly one compact JSON object plus one newline to
stdout. Schema 2 has exactly these keys: `schema_version=2`,
`state="deployment-quarantine-released"`, `protocol_version="2.1"`,
`operation_id`, `source_display_id`, `target_device_id`,
`coordinator_instance_id`, `marker_generation`, `marker_path`,
`release_claim_path`, `release_receipt_path`, `released_marker_sha256`,
`marker_created_at_unix_ms`, `release_committed_at_unix_ms`,
`release_committed_at_utc`,
`release_point="release-claim-unlink-and-parent-directory-fsync"`, and
`replayed`. Commit time is audit data and intentionally precedes the release
point; no unsupported exact wall-clock release time is claimed. Diagnostics go
only to stderr.

The stable exit classes are: `0` success, `64` invalid CLI data, `65` invalid
marker data, `66` marker missing, `70` clock/internal failure, `73` destination
already exists, `74` storage/output I/O failure, `77` authorization mismatch,
and `78` unsafe storage configuration. No non-zero exit may be interpreted as
publication, release, or abort success.
