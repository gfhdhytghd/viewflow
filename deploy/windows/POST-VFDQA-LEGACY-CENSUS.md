# Post-VFDQA Windows legacy census

This chain records the legacy Windows boundary after the replay6 VFDQA incident.
It is evidence collection only. The old operation root and its deployment task
are preserved and quarantined in place. The chain never enables, starts,
registers, replaces, stops, unregisters, or deletes the old task, root, peer
task, installed peer, or peer process.

The fixed operation remains classified as:

- `VFDQA_COMMITTED`
- `AUTHZ_PROVENANCE_INVALID`
- `TERMINAL_ABSENT`
- `WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION`

The result is not remediation, normal release, or bridge readiness.

## Components

`capture-post-vfdqa-legacy-census.ps1` is the read-only Windows probe. It takes
two snapshots around the census and fails if the disabled deployment task XML
or operation-root census changes. It records all 14 root members with exact
length, SHA-256, regular/non-reparse status, owner and full ACL; all three
installed files with the same metadata; complete action/principal identity for
the deployment and peer tasks; and every system-wide `viewflowd.exe`. The Linux
validator requires exactly one such process at the pinned installed path.

`deploy/capture-post-vfdqa-windows-legacy-census.sh` is the Linux SSH wrapper.
Its bridge root is fixed to
`/home/wilf/.local/state/viewflow/post-vfdqa-bridges/<old-operation-id>`; an
arbitrary output directory or path escape is rejected.
SSH stdout and stderr are redirected to separate raw files, then represented by
lossless Base64, byte length, and SHA-256. The stdin request uses
`ssh-powershell-encodedcommand-exact-length-raw-files-v2`: an ASCII decimal
payload length followed by the JSON package. The PowerShell wrapper reads the
declared number of UTF-8 bytes/chars in a loop and never waits for stdin EOF.
The SSH transport also has `WarnWeakCrypto=no`, `ConnectTimeout=10`,
`ServerAliveInterval=5`,
`ServerAliveCountMax=3`, and a 120-second local killable timeout. The wrapper's
PowerShell script and the probe are SHA-pinned. The decoded stdout must be one strict UTF-8 JSON
object with no duplicate keys. Its separate canonical hash is calculated over
the exact bytes emitted by `jq -cS` (including jq's final LF); it never replaces
the raw-byte hash.

`check-post-vfdqa-legacy-census.sh` validates the frozen schemas and the complete
hash chain through the replay6 reconciliation manifest, prior Windows
inventory, reconciliation incident, and invalid-authorization tombstone. It
publishes only the legacy disposition.

## Frozen files and schemas

The evidence directory is exactly `$BRIDGE_ROOT/evidence`. Both directories are
owner-only mode `0700`, non-symlink directories. The immutable intent and
outputs are exactly:

- `windows-legacy-census-capture-intent.json`
- `windows-ssh-raw-census.json`
- `windows-legacy-disposition.json`
- `windows-legacy-census-transport-upgrade.v1.json` (only for the EOF-deadlock
  recovery path)
- `windows-legacy-census-stderr-classification.v1.json` (only when the raw
  stderr contains the accepted OpenSSH PQ warning plus PowerShell progress)

Each file is a mode `0600`, regular, no-follow, single-link file. Publication is
crash-safe: a content-addressed staging file is created with `O_EXCL`, fsynced,
linked no-replace to the final name, the parent is fsynced, bytes and inode are
read back, then the same-inode staging link is removed and the parent is fsynced
again. A recognized link-before-unlink crash is recoverable. Partial, different,
symlink, unrelated-hardlink, or unexpected staging state hard-stops.

The capture intent binds the old operation, SSH target/options, output paths,
all four reconciliation inputs, and the probe/wrapper/checker identities. It is
published before any SSH capture. `--resume` accepts only the identical intent.
If the pre-fix EOF-sensitive intent (`4170bd4a...`) is present with no raw,
disposition, or staging evidence, it may be retained in place and accompanied
by one create-once transport-upgrade receipt. That receipt binds the old intent
SHA, old/new wrapper and checker SHA-256 values, old/new transport names, and
the fixed output paths; raw v2 records its receipt SHA in
`transport_upgrade_receipt_sha256`.
For the known live EOF-deadlock incident, its `new_*` producer identities are
the historical exact-length observed wrapper/checker (`8e0e056b...`/
`2bf19eeb...`), not a later final wrapper/checker; the classification receipt
binds that observed producer to the current final identities.

Raw state is `viewflow-windows-ssh-raw-census`. Its exact top-level keys are:

```text
schema_version,state,operation_id,observed_at_utc,transport,ssh_target,
ssh_options,probe_script_sha256,wrapper_script_sha256,
transport_upgrade_receipt_sha256,exit_status,stdout,stderr,parsed_census,
incident_boundary
```

The exact `incident_boundary` keys are:

```text
reconciliation_manifest_sha256,incident_sha256,
invalid_authz_tombstone_sha256,prior_windows_inventory_sha256
```

Successful captures normally require empty stderr. If an existing raw capture
has the exact three-line OpenSSH PQ warning followed by `#< CLIXML`, resume may
publish the classification receipt only after strict XML parsing using the
observed CP936 encoding and confirming every top-level `Obj` has `S="progress"`.
The receipt binds both the observed raw producer and the current final
producer/checker; the disposition records its SHA. Error, warning, unknown
records, malformed XML, extra bytes, or an unbound non-empty stderr hard-stop.

Disposition state is `viewflow-post-vfdqa-windows-legacy-disposition`. Its exact
top-level keys are:

```text
schema_version,state,old_operation_id,action,incident_boundary,
raw_census_sha256,stderr_classification_sha256,operation_root,legacy_deployment_task,peer,
legacy_isolation_complete,fresh_bridge_ready
```

The only accepted action is `preserve-and-quarantine-no-mutation`, with
`legacy_isolation_complete=true` and `fresh_bridge_ready=false`.

## Offline use and tests

The wrapper is intentionally not run by the test suite against a real host.
After freezing the three script hashes, its interface is:

```text
capture-post-vfdqa-windows-legacy-census.sh \
  --execute \
  --manifest MANIFEST --windows-inventory INVENTORY \
  --incident INCIDENT --tombstone TOMBSTONE \
  --old-operation-id OPERATION_ID --target SSH_TARGET \
  --bridge-root /home/wilf/.local/state/viewflow/post-vfdqa-bridges/OPERATION_ID \
  --raw-output BRIDGE_ROOT/evidence/windows-ssh-raw-census.json \
  --disposition-output BRIDGE_ROOT/evidence/windows-legacy-disposition.json \
  --probe PROBE --expected-probe-sha256 SHA256 \
  --expected-wrapper-sha256 SHA256 \
  --checker CHECKER --expected-checker-sha256 SHA256
```

Exactly one mode is required:

- `--validate-inputs-only` validates hashes, the canonical operation-bound
  bridge path, the existing state-root metadata, and any existing identical
  intent without creating directories, publishing evidence, or using SSH.
- `--execute` requires a new intent and absent evidence, publishes the intent,
  then performs one capture.
- `--resume` requires the identical intent. A complete raw census is validated
  and reused without SSH; a raw staging/link crash is recovered; a missing
  disposition is continued through the checker; and two complete identical
  outputs return idempotent success. For the known old EOF-sensitive intent,
  resume may proceed only when its exact old wrapper/schema is present and raw,
  disposition, and staging are absent: it then publishes the independent
  `windows-legacy-census-transport-upgrade.v1.json` receipt and preserves the
  old intent unchanged. Only when no raw final or staging evidence exists may
  resume perform capture.

`--print-wrapper-sha256` prints the fixed embedded PowerShell wrapper hash
without contacting Windows. The fixture-only raw-input switches require
`VIEWFLOW_POST_VFDQA_CENSUS_FIXTURE=1` and are used only by the offline test.

For `--execute` and `--resume`, the wrapper first verifies the existing state
root as an owner-only, non-symlink directory owned by the invoking uid. It then
creates only the exact missing chain `post-vfdqa-bridges`, the operation root,
and `evidence`, each as mode `0700`, checking every component with `lstat` and
fsyncing its parent after creation. Existing symlinks, wrong owners, wrong
modes, and non-canonical paths hard-stop. The state root itself is never
created by this wrapper.

Run:

```text
bash -n deploy/capture-post-vfdqa-windows-legacy-census.sh \
  deploy/windows/check-post-vfdqa-legacy-census.sh \
  deploy/windows/tests/post-vfdqa-legacy-census-static-negative-test.sh
shellcheck deploy/capture-post-vfdqa-windows-legacy-census.sh \
  deploy/windows/check-post-vfdqa-legacy-census.sh \
  deploy/windows/tests/post-vfdqa-legacy-census-static-negative-test.sh
deploy/windows/tests/post-vfdqa-legacy-census-static-negative-test.sh
```

On Windows, also run
`post-vfdqa-legacy-census-fixture-test.ps1`. The Linux fixture covers a
completely absent `post-vfdqa-bridges` parent and proves creation of the exact
owner-only chain, while rejecting state-root/parent/operation-root/evidence
symlinks and wrong modes. It also covers malformed
UTF-8, duplicate and extra keys, CRLF raw fidelity, nonzero exit status,
create-once/no-clobber, symlink and hard-link rejection, task-disposition
mutation, deep root/installed/task/peer/process mutations, and offline Linux
wrapper publication. It also covers intent replay/difference, raw and
disposition staging-only crashes, link-before-unlink crashes, partial finals,
partial staging, resume without SSH, and idempotent complete replay.
