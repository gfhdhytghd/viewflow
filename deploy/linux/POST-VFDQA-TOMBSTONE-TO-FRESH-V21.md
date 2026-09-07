# Post-VFDQA incident/tombstone to a fresh Linux v2.1 boundary

`bridge-post-vfdqa-tombstone-to-fresh-v21.sh` is an independent Linux-only
transaction. It accepts the reconciled
`viewflow-post-vfdqa-incident-terminal-reconciliation-required` receipt, the
`INVALID_AUTHZ_PROVENANCE_TOMBSTONE`, the committed 384-byte `VFDQA001`, the
reconciliation manifest, prior Windows census, current Linux runtime inventory,
and the immutable Windows evidence chain. It does not call SSH or
modify Windows.

The historical authorization embedded in VFDQA is consumed only to prove the
bytes whose provenance was invalidated. It is explicitly recorded as
`historical-invalidity-proof-only-never-authority`; it cannot authorize this
transition. `--execute` creates a new operation ID, a new coordinator UUID and
an immutable create-once transition plan. `--resume` must match that plan.
The marker candidate, marker producer and B collector must each be uid 1000,
regular, nlink 1, nofollow, and not group/world writable. Before the plan is
published, their bytes are copied through verified descriptors into an
owner-only 0500 sealed directory. The plan binds each original path,
device/inode/mode/hash and sealed path/hash; resume revalidates both copies,
and execution uses the verified sealed file descriptors rather than reopening
the caller-supplied paths.

The Windows evidence namespace is fixed at:

- `$BRIDGE_ROOT/evidence/windows-ssh-raw-census.json`
- `$BRIDGE_ROOT/evidence/windows-legacy-census-transport-upgrade.v1.json`
- `$BRIDGE_ROOT/evidence/windows-legacy-census-stderr-classification.v1.json`
- `$BRIDGE_ROOT/evidence/windows-legacy-disposition.json`

The evidence directory must be owner-only 0700. Every present evidence file
must be regular, nofollow, 0600 and nlink 1. There are exactly two accepted,
non-mixable variants. A fresh exact-length capture records
`transport_upgrade_receipt_sha256:"none"`, has byte-empty stderr, has no
upgrade or stderr-classification file, and its disposition records
`stderr_classification_sha256:"none"`. The historical EOF-recovery variant
requires all four files: raw binds the create-once transport-upgrade SHA,
upgrade binds the old intent and the fixed old/observed producers, the
classification binds the raw/upgrade plus the exact OpenSSH PQ-warning and
progress-only CP936 CLIXML bytes, and disposition binds the raw and
classification SHA. Upgrade without classification, classification without
upgrade, nonempty unclassified stderr, or an unbound optional file fails
closed.

All four schemas and nested chain objects are exact-key validated and
cross-hash bound to the manifest, incident, tombstone and prior Windows census.
The immutable transition plan and final Linux receipt each bind path and SHA
for raw, upgrade, stderr classification and disposition; absent optional files
retain their fixed paths with SHA `none`. The disposition deliberately remains
`fresh_bridge_ready:false`; this bridge cannot claim Windows remediation or a
normal deployment success.

Before mutation, the recorded boot ID and the exact transient units,
InvocationIDs, cgroups, PID sets,
start ticks and executable hashes are reattested. An active route requires a
normal acknowledged ReleaseAll/lease-revoke cleanup. A no-route path requires
an exact sidecar-3 status with no stale receipt. Deskflow stops before Viewflow;
the zero boundary includes both cgroups, exact processes, TCP 24800, UDP 44119,
the sidecar socket and `VFQST002`.

Five runtime config entries are snapshotted by inode/type/owner/mode/nlink/hash
and moved into an owner-only backup using `renameat2(RENAME_NOREPLACE)`. Exact
`/dev/null` masks are required. Both names, neither name, symlink substitution,
hardlinks and tuple drift fail closed. Receipts and the plan use atomic
no-replace rename, file and parent fsync, nofollow reads and nlink-1 validation,
so a crash is either pre-publication or a complete publication.

The bridge temporarily starts only persistent Viewflow v1.3, invokes the pinned
marker-handoff producer to create fresh generation-1 VFDQT/H, then invokes the
pinned B collector which stops that invocation. Its terminal receipt is a
Linux-only state:
`viewflow-post-vfdqa-linux-fresh-v21-bootstrap-boundary-ready`.

Resume has two explicit post-side-effect recovery paths. If VFDQT is durable
but H is absent, the bridge decodes the exact marker bytes, requires the fresh
operation/coordinator/generation from the immutable plan, reconstructs the
publish receipt from the marker timestamp, proves Deskflow remains quiescent,
and publishes H without invoking the marker producer again. If the collector
intent is durable and its daemon has stopped but B is absent, the bridge
requires the same boot, absent recorded PID, zero unit/listener/socket state,
and a journal slice containing only the recorded PID, boot and InvocationID;
it then reconstructs and validates B. Existing cleanup and final receipts are
not merely adopted: duplicate/unknown keys, nested-hash drift, plan/input hash
drift, or a changed live zero boundary fail resume.

## Modes

- `--validate-inputs-only`: validates every immutable input and cross-hash; no
  runtime mutation.
- `--execute`: creates the transition plan and advances the transaction.
- `--resume`: revalidates the same plan and advances only incomplete steps.

Use `--help` for the complete argument list. The bridge root is fixed to
`/home/wilf/.local/state/viewflow/post-vfdqa-bridges/$OLD_OPERATION`.

## Offline verification

```bash
bash -n deploy/linux/bridge-post-vfdqa-tombstone-to-fresh-v21.sh
bash deploy/linux/check-bridge-post-vfdqa-tombstone-to-fresh-v21.sh
bash deploy/linux/tests/bridge-post-vfdqa-tombstone-input-fixture-test.sh
bash deploy/linux/tests/bridge-post-vfdqa-tombstone-cleanup-fixture-test.sh
bash deploy/linux/tests/bridge-post-vfdqa-tombstone-static-negative-test.sh
shellcheck --severity=error deploy/linux/bridge-post-vfdqa-tombstone-to-fresh-v21.sh \
  deploy/linux/check-bridge-post-vfdqa-tombstone-to-fresh-v21.sh \
  deploy/linux/tests/bridge-post-vfdqa-tombstone-*.sh
```

The input fixture also creates and mutates an offline plan to prove rejection
of reused operation/coordinator identities, writable or replaced sources, and
rewritten sealed snapshots. The static-negative fixture replaces critical
validators with `return 0` while retaining their old anchors in comments, so
the checker must inspect executable function bodies. It also mutates every
Windows-chain schema, union discriminator, cross-hash, plan/final binding and
the current-boot gate. These checks do not
authorize or execute a live transition.
