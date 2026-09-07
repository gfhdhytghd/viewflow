# Linux transactional update gate

The normal transaction below consumes only daemon-produced schema-4 receipts.
`install-viewflow-deskflow.sh` now rejects every legacy single-stage bootstrap
option before preflight. The installed protocol-1.3 endpoint uses the two
explicit phases below; its schema-1 frozen evidence is never accepted as a
schema-4 quiescence receipt.

## One-time two-phase protocol 1.3 to 2.1 bootstrap

The split removes the Windows-install-receipt/Linux-2.1 readiness cycle. Before
phase 1, the coordinator publishes `VFDQT001`, Windows has stopped the old task
and committed schema-3 force-release receipt `F`, and both old Linux units are
inactive. The legacy `VFQST002` marker must be wholly absent: protocol 1.3 has
no reviewed v2 runtime-marker owner.

Phase 1 runs after the Windows bootstrap request `B`, recovery-prepared receipt
`P`, coordinator mutation permit, and force-release envelope have formed their
create-once hash chain. It installs only `viewflowd`, the deployment-marker CLI, and
`viewflow-peer.service`. It preserves the old Deskflow GUI, core, and drop-in
bytes and keeps Deskflow inactive. It starts Linux protocol 2.1 with both
post-release acceptance options, then waits up to 120 seconds for an exact
`172.16.105.70` authenticated-peer record in that new systemd invocation.
This rendezvous does not read or depend on Windows install receipt `W`.

```bash
deploy/linux/bootstrap-stage-viewflow.sh stage \
  --viewflow-candidate /absolute/path/viewflowd \
  --viewflow-sha256 '<linux viewflowd sha256>' \
  --deployment-marker-candidate /absolute/path/viewflow-deployment-marker \
  --deployment-marker-sha256 '<marker CLI sha256>' \
  --viewflow-unit-candidate /absolute/path/viewflow-peer.service \
  --viewflow-unit-sha256 '<unit sha256>' \
  --operation-id "$operation_id" \
  --source-display-id '<32 lowercase hex>' \
  --target-device-id '<32 lowercase hex>' \
  --coordinator-instance-id '<32 lowercase hex>' \
  --marker-generation 1 \
  --bootstrap-linux-evidence /absolute/path/L.json \
  --bootstrap-handoff-receipt /absolute/path/H.json \
  --windows-bootstrap-request /absolute/path/B.json \
  --windows-prepared-receipt /absolute/path/P.json \
  --windows-mutation-permit /absolute/path/permit.json \
  --windows-force-release-envelope /absolute/path/F-envelope.json \
  --deployment-publish-receipt /absolute/path/VFDQT001-published.json \
  --windows-viewflow-sha256 '<Windows viewflowd.exe sha256>' \
  --windows-user-sid '<Session-1 SID>' \
  --receipt-output /home/wilf/.local/state/viewflow/evidence/linux-bootstrap-staged.json
```

The schema-1 `viewflow-linux-bootstrap-staged` receipt and its adjacent
`.backup` directory are owner-only and create-once. Repeating `stage` with the
exact same inputs or using `query` only revalidates the receipt, candidate
chain, live PID/invocation, authenticated peer, preserved Deskflow bytes, and
unchanged marker. It never repeats installation. `rollback` restores all six
old Linux artifacts and leaves both Linux units inactive with the original
`VFDQT001` identity and hash retained.

The stage receipt binds the exact bytes of `B`, `H`, `L`, `P`, the mutation
permit, the force-release envelope, and the marker publish receipt. The permit
also binds the three Linux stage candidate hashes; they must equal the staged
Viewflow, marker-CLI, and unit hashes serialized in the stage receipt.
The stage/finalize command-line source, target, and coordinator IDs are 32
lowercase hexadecimal characters. Producer-owned `H` and marker-publish
receipts carry the same nonzero IDs as canonical lowercase hyphenated UUIDs;
validation removes hyphens only after enforcing that receipt form.

After the concurrently running Windows installer has daemon-committed schema-5
receipt `W`, phase 2 revalidates `W -> F -> L`, the stage receipt, marker
publish receipt, every candidate, and the Deskflow provenance manifest. Only
this phase moves `L`, the force-release envelope, and `W` into the stage backup.
Before the first move it publishes and fsyncs the owner-only create-once intent
at `<stage-receipt>.backup/consume-intent.json`. Its exact schema records the
operation, stage-receipt SHA, and each artifact's original path, consumed path,
and SHA. `finalize`, `query`, and `rollback` accept every exact
zero/one/two/three-move crash subset; missing, duplicate, substituted, or extra
paths fail closed. Each forward or restore move uses Linux `renameat2` with
`RENAME_NOREPLACE` as its linearization point, then verifies the preserved
inode/hash/uid/mode/link count and fsyncs both affected directories. A target
that appears concurrently is never overwritten. It installs
the patched Deskflow GUI/core/drop-in and starts them under the still-retained
deployment marker; listener/process readiness is required, but route admission
is not claimed while the marker exists.

The two force-release hashes are intentionally different bindings. The Linux
stage/final receipts bind the exact force-release envelope bytes. Windows
schema-5 `W.force_release_receipt_sha256` instead binds the raw force-release
receipt SHA carried by the already strictly validated envelope. Finalize reads
that lowercase hash from the envelope and compares it to `W`; it never compares
`W.force_release_receipt_sha256` to the envelope file SHA.

```bash
deploy/linux/bootstrap-finalize-viewflow-deskflow.sh finalize \
  --viewflow-candidate /absolute/path/viewflowd \
  --viewflow-sha256 '<linux viewflowd sha256>' \
  --deployment-marker-candidate /absolute/path/viewflow-deployment-marker \
  --deployment-marker-sha256 '<marker CLI sha256>' \
  --viewflow-unit-candidate /absolute/path/viewflow-peer.service \
  --viewflow-unit-sha256 '<unit sha256>' \
  --deskflow-candidate /absolute/path/deskflow \
  --deskflow-sha256 '<deskflow sha256>' \
  --deskflow-core-candidate /absolute/path/deskflow-core \
  --deskflow-core-sha256 '<deskflow-core sha256>' \
  --deskflow-dropin-candidate /absolute/path/deskflow-viewflow.conf \
  --deskflow-dropin-sha256 '<drop-in sha256>' \
  --deskflow-provenance-manifest /absolute/path/provenance.json \
  --deskflow-provenance-sha256 '<provenance sha256>' \
  --stage-receipt /home/wilf/.local/state/viewflow/evidence/linux-bootstrap-staged.json \
  --bootstrap-linux-evidence /absolute/path/L.json \
  --bootstrap-handoff-receipt /absolute/path/H.json \
  --windows-bootstrap-request /absolute/path/B.json \
  --windows-prepared-receipt /absolute/path/P.json \
  --windows-mutation-permit /absolute/path/permit.json \
  --windows-force-release-envelope /absolute/path/F-envelope.json \
  --windows-install-receipt /absolute/path/W.json \
  --publish-receipt /absolute/path/VFDQT001-published.json \
  --operation-id "$operation_id" \
  --source-display-id '<32 lowercase hex>' \
  --target-device-id '<32 lowercase hex>' \
  --coordinator-instance-id '<32 lowercase hex>' \
  --marker-generation 1 \
  --windows-viewflow-sha256 '<Windows viewflowd.exe sha256>' \
  --windows-wrapper-sha256 '<wrapper sha256>' \
  --windows-task-xml-sha256 '<task XML sha256>' \
  --windows-user-sid '<Session-1 SID>' \
  --receipt-output /home/wilf/.local/state/viewflow/evidence/linux-bootstrap-finalized.json
```

The final schema-1 state is `viewflow-linux-bootstrap-finalized`. An exact
`query` reads the final receipt after full consumption; with a durable intent
but no final receipt it validates the current subset and returns the unchanged
intent bytes. `rollback` verifies the available chain, requires both Linux
units already inactive, restores
the six stage-before files, and returns the three evidence files without
removing `VFDQT001`. The Linux scripts intentionally make no claim that the
Windows task is inactive; cross-host rollback remains the coordinator's job.

Every finalizer `rollback` requires the five current-marker options
`--active-recovery-marker-publish-receipt`,
`--active-recovery-marker-operation-id`,
`--active-recovery-marker-coordinator-instance-id` (32 lowercase hex),
`--active-recovery-marker-generation`, and
`--active-recovery-marker-sha256`. Before release, generation 1 must reproduce
the original operation, coordinator, marker, and publish-receipt bytes. After
release, generation 2 must use a distinct operation and marker SHA with its
independently validated publish receipt. Historical `H`, publish, and staged
receipt evidence remains bound to generation 1; other combinations fail closed.

Run the two-phase static and mutation gates before live use:

```bash
deploy/linux/check-bootstrap-stage-viewflow.sh
deploy/linux/tests/bootstrap-stage-static-negative-test.sh
deploy/linux/check-bootstrap-finalize-viewflow-deskflow.sh
deploy/linux/tests/bootstrap-finalize-static-negative-test.sh
deploy/linux/tests/bootstrap-handoff-uuid-fixture-test.sh
deploy/linux/tests/bootstrap-two-phase-receipt-fixture-test.sh
deploy/linux/tests/bootstrap-consume-intent-fixture-test.sh
deploy/linux/tests/bootstrap-active-marker-generation-fixture-test.sh
deploy/linux/tests/bootstrap-atomic-move-race-fixture-test.sh
deploy/linux/tests/bootstrap-prepared-nested-schema-fixture-test.sh
```

`install-viewflow-deskflow.sh` replaces three runtime executables, the
coordinator-only deployment marker executable, and two systemd configuration
files:

- `/home/wilf/.local/lib/viewflow/viewflowd`
- `/home/wilf/.local/lib/viewflow/viewflow-deployment-marker`
- `/home/wilf/.local/lib/deskflow-scale-fix/deskflow`
- `/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core`
- `/home/wilf/.config/systemd/user/viewflow-peer.service`
- `/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf`

It is intentionally specific to this host, peer, device IDs, units, sockets,
and ports. Every candidate path and SHA-256 is mandatory. Candidate files must
be separate from the installed files. The Deskflow pair additionally requires
an owner-only provenance manifest that binds the reviewed source state, build
graph/toolchain, and both ELF artifacts.

The deployment marker candidate must be the reviewed Linux release build from
the `viewflow-deployment-marker` crate. It is installed as uid 1000 with exact
mode `0755` and link count 1. The installer binds its candidate and installed
bytes to the caller-supplied SHA-256, requires that no process is executing the
installed path while it is replaced or rolled back, and never invokes it. The
cross-host coordinator invokes `publish` and `release` separately; the
`viewflow-peer.service` unit does not reference or own this tool.

## Durable Deskflow quarantine storage

The installer does not provision or repair durable quarantine storage. Before
running it, the reviewed quarantine owner must create the fixed owner-only
parent as uid 1000 (if it is wholly absent) and then publish the marker. The
explicit parent preparation step is:

```bash
install -d -m 0700 /home/wilf/.local/state/viewflow
```

The installer and deactivation script never create, repair, or change this
directory. It must be a real
non-symlink directory owned by uid 1000 with exact mode `0700`, otherwise they
fail before changing service state or installed files. The Deskflow drop-in
must contain this assignment exactly once, including
on the already-installed configuration that would be restored by rollback:

```ini
Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
```

Before the first service or file mutation, the reviewed quarantine owner must
publish `deskflow-quarantine.v2` through its no-clobber C++ API and durably
commit the parent-directory update. Deployment and deactivation require the
marker, bound to the current operation and endpoint identity, as a regular
non-symlink file owned by uid 1000 with exact mode `0600`, link count 1, and
size 152 bytes. The binary v2 format has magic `VFQST002`; state `1` is active
quarantine and state `2` is uncertain quarantine. The separate deployment
quarantine marker remains `deployment-quarantine.v1` (magic `VFDQT001`, size
256 bytes) and must not be substituted for the Deskflow runtime marker.
Operators and shell scripts must not handcraft either marker's bytes. The C++
runtime owns full content validation and state transitions. A persistent marker
suppresses normal Deskflow admission across daemon, service, and host restarts.

The installer and deactivator require the exact `VFQST002` and `VFDQT001`
magic values in addition to the fixed storage metadata. The installer,
deactivator, and rollback path only validate this storage
contract. They never create, delete, move, consume, truncate, or clear the
marker, and operators must not remove it manually. The installer freezes the
marker's filesystem device/inode identity and SHA-256 during preflight, then
revalidates both before and after every service/configuration boundary and
through rollback. A same-size replacement or same-inode byte rewrite therefore
fails closed with both services left inactive. It is not the normal
single-use quiescence receipt passed with `--quiesced-marker` and must never be
moved into `deploy-backups`. Keep it present through the Windows and Linux
installs and every rollback path. Only the reviewed C++ quarantine owner may
unlink it after both exact endpoint hashes have authenticated to each other on
protocol 2.1, cleanup evidence has reached `CleanupComplete`, the persisted
operation and endpoint identity have been revalidated, and the controller has
explicitly authorized release. The unlink and parent-directory update must be
durable. Route admission must be verified after release before cross-host
recovery is disarmed.

## Post-release acceptance endpoints

The live acceptance servers deliberately use different owner-only runtime
sockets. `viewflow-peer.service` passes
`--acceptance-socket %t/viewflow/post-release-acceptance.sock` and
`--acceptance-state-dir /home/wilf/.local/state/viewflow/post-release-acceptance`
to `viewflowd`. The Deskflow drop-in passes
`DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock`
to the GUI and `deskflow-core`; the paths must never be merged.

The installer creates the state directory only when wholly absent, then requires
an actual non-symlink directory owned by uid 1000 with exact mode `0700` at
preflight, transaction, readiness, and rollback boundaries. It is runtime
evidence storage rather than one of the six install artifacts: it is never
backed up, replaced, consumed, or deleted. Deactivation validates it and waits
for both runtime acceptance sockets to disappear, while preserving every receipt
inside it.

## Standalone fail-closed deactivation

`deactivate-viewflow-deskflow.sh` is the source-controlled stop/verify contract
for taking the installed Linux endpoint offline without installing anything.
It is independent of the update transaction and does not claim quiescence,
remote `ReleaseAll`, or cross-host safety. All six current installed hashes
must be supplied explicitly; the script will not discover an identity and then
silently trust it.

Run its static-only contract and mutation checks first:

```bash
deploy/linux/check-deactivate-viewflow-deskflow.sh
deploy/linux/tests/deactivate-viewflow-deskflow-static-negative-test.sh
deploy/linux/tests/deactivate-viewflow-deskflow-artifact-fixture-test.sh
```

The live command, when separately authorized, has this interface:

```bash
deploy/linux/deactivate-viewflow-deskflow.sh \
  --viewflow-sha256 '<current installed viewflowd sha256>' \
  --deployment-marker-sha256 '<current installed viewflow-deployment-marker sha256>' \
  --deskflow-sha256 '<current installed deskflow sha256>' \
  --deskflow-core-sha256 '<current installed deskflow-core sha256>' \
  --viewflow-unit-sha256 '<current installed viewflow-peer.service sha256>' \
  --deskflow-dropin-sha256 '<current installed viewflow.conf sha256>' \
  --operation-id 'deactivate-20260829-unique' \
  --transcript-output /home/wilf/.local/state/viewflow/evidence/viewflow-linux-deactivated.txt \
  --proof-output /home/wilf/.local/state/viewflow/evidence/viewflow-linux-deactivated.json
```

Before stopping anything it verifies uid `1000`, home `/home/wilf`, the exact
four executable and two systemd-file paths and hashes, plus systemd's loaded
`FragmentPath` and `DropInPaths`, the fixed quarantine drop-in assignment, and
the durable storage metadata above. It then uses only graceful user-service stops,
in the order Deskflow then Viewflow. Each stop must converge to unit state
`inactive`, `MainPID=0`, zero processes whose executable resolves to any of the
three service-runtime paths, no process executing the fixed deployment marker
tool path, no TCP 24800 or UDP 44119 listener, and no sidecar
socket. It then performs `daemon-reload`, revalidates the loaded paths and all
six hashes, and repeats both the stopped-state and quarantine-storage checks at
the proof publication boundary.
It also validates the post-release acceptance state directory and requires both
acceptance sockets to be absent; its proof deliberately does not serialize or
consume runtime acceptance receipts.

The new transcript and proof paths must not already exist, must be different,
and must share an owner-only directory. The exact key/value observation
transcript is persisted first with mode `0600` using a no-clobber hard link.
Its owner, mode, and SHA-256 are then recomputed from the published sidecar. A
schema-3 `viewflow-linux-deactivated` JSON proof is published with mode `0600`
using a second no-clobber hard link. It binds the transcript basename and
recomputed byte hash, operation, boot, six
installed identities, loaded configuration, zero-count runtime observations,
and completion time. The transcript is rehashed again at the proof commit
boundary. Any failure after shutdown begins makes another best-effort graceful
stop, publishes no proof, removes an orphan transcript created by that failed
invocation, and never starts, restarts, or force-kills either service.

Validate a published pair offline, without querying or changing service state:

```bash
deploy/linux/check-deactivate-viewflow-deskflow.sh \
  --proof /home/wilf/.local/state/viewflow/evidence/viewflow-linux-deactivated.json \
  --transcript /home/wilf/.local/state/viewflow/evidence/viewflow-linux-deactivated.txt
```

Artifact mode rejects non-`0600` or non-uid-1000 files, symlinks, different
directories, duplicate JSON keys, multiple JSON documents, invalid UTF-8,
non-exact schema fields, a basename/hash mismatch, and any transcript whose
ordered observations contradict the proof.

## Daemon-produced quiescence receipt

The installer must not be used to quiesce input, and operators must not
synthesize its receipt. The reviewed order is:

1. Generate a unique 16-128 character operation ID.
2. Read the active `viewflow-peer.service` `MainPID` and arm that exact process:

   ```bash
   /home/wilf/.local/lib/viewflow/viewflowd arm-quiesce \
     --arm-file /run/user/1000/viewflow/deploy-quiesce-arm.json \
     --operation-id "$operation_id" \
     --daemon-pid "$viewflow_pid"
   ```

3. Stop Deskflow and wait for its GUI/core processes and TCP listener to exit.
4. Trigger the already-connected sidecar to close. The daemon closes producer
   admission, cleans the exact route, writes the receipt atomically with mode
   `0600`, and exits. This also covers a sidecar that disconnected before the
   trigger was observed.
5. Confirm `viewflow-peer.service` is inactive, `MainPID=0`, the exact daemon
   PID has exited, and both the UDP listener and sidecar socket are gone.
6. Run the evidence collector without starting or stopping either service:

   ```bash
   deploy/linux/collect-viewflow-daemon-exit-evidence.sh \
     --runtime-receipt /absolute/path/to/viewflow-input-quiesced.json \
     --operation-id "$operation_id" \
     --daemon-sha256 '<current installed viewflowd sha256>' \
     --observation-output /absolute/path/to/viewflow-daemon-exit-observation.json \
     --evidence-output /absolute/path/to/viewflow-daemon-exited.json
   ```

7. Keep the route disabled and pass the untouched receipt, compact exit
   evidence, and raw observation sidecar to the installer. The installer
   recomputes both the runtime-receipt hash and raw-observation hash, matches
   the complete daemon identity and recovered journal invocation, then replays
   the exact journal slice and stopped state before and after consuming them.

Schema version 4 is produced directly by `viewflowd`:

```json
{
  "schema_version": 4,
  "state": "viewflow-input-quiesced",
  "daemon_instance_id": "<boot-id>-<pid>-<start-ticks>",
  "operation_id": "deploy-20260829-unique",
  "daemon_pid": 1234,
  "daemon_start_ticks": 123456789,
  "boot_id": "<current Linux boot ID>",
  "daemon_sha256": "<current Linux viewflowd SHA-256>",
  "protocol_version": "2.1",
  "local_device": "00000000000000000000000000000001",
  "target_device": "00000000000000000000000000000002",
  "cleanup": {
    "route_ever_activated": true,
    "route_was_active": true,
    "source_display": "00000000000000000000000000000101",
    "route_generation": 5,
    "active_lease_generation": 10,
    "last_input_sequence": 41,
    "release_all": {
      "status": "applied",
      "ack": {
        "lease_generation": 10,
        "target_device": "00000000000000000000000000000002",
        "event_sequence": 42,
        "result": "applied"
      }
    },
    "lease_revoke": {
      "status": "applied",
      "generation": 11,
      "ack": {
        "operation_id": "00000000000000070000000000000001",
        "lease_generation": 11,
        "owner_device": "00000000000000000000000000000001",
        "target_device": "00000000000000000000000000000002",
        "state": "revoked",
        "result": "applied"
      }
    },
    "bound_peer_epoch": 7,
    "bound_peer_socket": "172.16.105.70:53000"
  },
  "route_status": "removed",
  "peer_disconnect_status": "initiated_before_daemon_exit",
  "daemon_exit_required": true,
  "sidecar_session_disconnected": true,
  "artifact_hashes": {
    "linux_viewflowd": "<same daemon SHA-256>",
    "linux_peer_certificate": "<peer.pem SHA-256>",
    "linux_peer_private_key": "<peer.key SHA-256>",
    "linux_certificate_authority": "<ca.pem SHA-256>"
  },
  "completed_at_unix_ms": 1788036000000
}
```

Only a daemon instance that never activated a route may use
`route_ever_activated=false`, `route_was_active=false`, and the two
`not_required_no_active_route` statuses. Once a route has been activated, the
receipt must retain `route_ever_activated=true`, `route_was_active=true`, the
matching `ReleaseAll` Applied ACK identity, and an exact lease-revoke Applied
ACK. The revoke generation and ACK generation must equal the active generation
plus one; ACK owner/target/state/result must match the route; and the high half
of its nonzero operation ID must bind the same nonzero `bound_peer_epoch`.
An active route that became unbound, or any daemon-lifetime uncertain cleanup,
is rejected rather than treated as clean. The
receipt intentionally says disconnect was *initiated*; only the controller and
installer's exact daemon-exit, inactive-unit, listener, and socket checks turn
that into confirmed disconnect evidence.

The installer validates freshness, owner/mode, process identity, current boot,
the exact protocol `2.1`, safe-integer numeric fields, local/target IDs,
cleanup correlations, and hashes for the
exited daemon plus all TLS identity files. Deskflow and candidate hashes remain
independent explicit inputs, rechecked at the commit boundary. The receipt is
moved into the transaction backup before replacement so it is single-use.

## Deskflow source and artifact provenance

Do not create or preserve the final deployment manifest yet. Pending P0
protocol 2.1/C++ changes must first be completed, rebuilt, and pass their normal
test gates. A manifest generated before that rebuild describes the old ELF
pair and must not be used for installation. Generate the persistent manifest
only after the final P0 source and build artifacts are stable.

This is a state and integrity manifest, not proof of build causality. It proves
that the inspected source state, existing build metadata, tools, and existing
ELF bytes were mutually unchanged while the manifest was produced and can be
reproduced later. It does not prove that those ELF bytes were built from that
source or build graph. Causal proof requires an isolated/fresh rebuild from the
recorded source and configuration followed by hash comparison with both
candidate ELFs, or a trusted build-system attestation that binds equivalent
inputs to those exact output hashes.

The production provenance gate is intentionally narrow. The Deskflow worktree
must be at a detached HEAD exactly equal to the reviewed Deskflow 1.26.0 commit
`760e3b99b00053647a96b405276bf614bd860075`. Do not use
`--expected-upstream-head` in production; that override exists only for
isolated fixture tests. The generator clears inherited `GIT_*` environment
variables, disables replacement objects and system/global Git configuration,
and rejects repository `refs/replace` entries or a non-empty `info/grafts` so
caller-controlled Git indirection cannot redefine HEAD or the patch. The dirty
tracked set must be exactly these eight modified files:

- `src/apps/deskflow-core/deskflow-core.cpp`
- `src/lib/arch/unix/ArchMultithreadPosix.cpp`
- `src/lib/platform/PortalInputCapture.cpp`
- `src/lib/platform/PortalInputCapture.h`
- `src/lib/server/CMakeLists.txt`
- `src/lib/server/Server.cpp`
- `src/lib/server/Server.h`
- `src/unittests/server/CMakeLists.txt`

The untracked source set, excluding the build directory, must be exactly these
four files:

- `src/lib/server/ViewflowSidecarClient.cpp`
- `src/lib/server/ViewflowSidecarClient.h`
- `src/unittests/server/ViewflowSidecarClientTests.cpp`
- `src/unittests/server/ViewflowSidecarClientTests.h`

Any dirty path outside these allowlists is rejected, as is any added, deleted,
or renamed tracked entry in place of the required eight modified entries.
The manifest records exact `protocol_version="2.1"` and
`sidecar_protocol_version=3` claims; both are covered by its SHA-256 along with
the complete binary/full-index tracked patch, hashes and sizes for all 12 source
files, CMake cache and VerifyGlobs identities, both `build.ninja` and
`CMakeFiles/rules.ninja`, compiler/tool identities, and the SHA-256, size, and
GNU build ID of both ELF artifacts. The reviewed Ninja graph closure permits
exactly one include, `include CMakeFiles/rules.ninja`. The artifact paths must
be exactly `<build-directory>/bin/deskflow` and
`<build-directory>/bin/deskflow-core`; copied or renamed inputs are not accepted
as the source artifacts.

The existing `build.live_acceptance` record also binds the compiled-core query
capability: `enabled=true`, `core_query=true`, `socket_kind="af_unix"`,
`peer_auth="so_peercred_same_uid"`, `arm_magic="VFARM001"`,
`receipt_magic="VFRCP001"`, `receipt_size=568`, and the same Viewflow 2.1 /
sidecar v3 versions. Generation checks those exact source constructs in
`ViewflowSidecarClient.cpp` and the early `deskflow-core` query entrypoint.
This proves that the inspected source advertises the owner-only live-query
mechanism; it does **not** claim a live daemon was present or that it had
produced an acceptance receipt. That evidence is obtained only through the
running core's AF_UNIX query during the deployment transaction.

The generator does not build or modify the source. Before and after recording
state it dry-runs both the complete default graph and the explicit
`bin/deskflow bin/deskflow-core` target pair with Ninja explain output. It
rejects source, configuration, or artifact races and any pending compile/link
work in either dry-run. The known `CONFIGURE_DEPENDS` VerifyGlobs/CMake
housekeeping is checked separately without touching the build tree.

After the final P0 rebuild and tests, write the manifest to a new absolute path
in an owner-only directory. The output path must not already exist; publication
is no-clobber and the generated file has mode `0600`:

```bash
deploy/linux/generate-deskflow-provenance.sh \
  --source-dir /home/wilf/.local/src/deskflow-scale-fix \
  --build-dir /home/wilf/.local/src/deskflow-scale-fix/build-local \
  --deskflow /home/wilf/.local/src/deskflow-scale-fix/build-local/bin/deskflow \
  --deskflow-core /home/wilf/.local/src/deskflow-scale-fix/build-local/bin/deskflow-core \
  --output /absolute/owner-only/path/deskflow-provenance.json
```

Record the manifest SHA-256 printed by the generator. Before installation,
perform the offline reproduction check below. It performs no network access,
does not build, and does not change the source tree, but it requires the exact
source tree, CMake/Ninja build metadata, source artifacts referenced by the
manifest, and the supplied candidate copies to remain locally available and
unchanged:

```bash
deploy/linux/check-deskflow-provenance.sh \
  --manifest /absolute/owner-only/path/deskflow-provenance.json \
  --manifest-sha256 '<manifest sha256 printed by the generator>' \
  --deskflow-candidate /absolute/path/to/deskflow \
  --deskflow-sha256 '<deskflow sha256>' \
  --deskflow-core-candidate /absolute/path/to/deskflow-core \
  --deskflow-core-sha256 '<deskflow-core sha256>'
```

The checker rejects duplicate or extra JSON fields, missing or different
protocol claims, schema drift, a different upstream commit or dirty patch,
CMake/Ninja/toolchain drift, pending real build work, non-canonical source
artifact paths, and candidate hash/size/build-ID mismatches. Before parsing, it
copies the manifest and both candidates into a
private mode-`0700` temporary directory as mode-`0400` files, validates only
those staged copies, and rehashes them after regeneration to detect mutation
during the check. Passing this check still establishes state/integrity only;
it does not add build-causality proof.

The installer independently requires the manifest to be a regular non-symlink
file owned safely and set to exact mode `0600`. It checks the caller-supplied
manifest hash and strict schema, requires the embedded Deskflow hashes to equal
the two candidate CLI hashes, checks both candidate sizes and GNU build IDs,
and rechecks the manifest file identity, hash, schema, and artifact bindings at
the transaction commit boundary.

## Transaction

Run the local audit gates first. They do not touch installed paths or services;
the storage fixture mutates only its private temporary directory:

```bash
deploy/linux/check-transactional-deploy.sh
deploy/linux/tests/transactional-installer-static-negative-test.sh
deploy/linux/tests/quarantine-storage-fixture-test.sh
```

After both candidate builds have completed their normal test gates and the
external controller has created and durably verified the quarantine marker,
invoke:

```bash
deploy/linux/install-viewflow-deskflow.sh \
  --viewflow-candidate /absolute/path/to/viewflowd \
  --viewflow-sha256 '<sha256>' \
  --deployment-marker-candidate /absolute/path/to/viewflow-deployment-marker \
  --deployment-marker-sha256 '<sha256>' \
  --deskflow-candidate /absolute/path/to/deskflow \
  --deskflow-sha256 '<sha256>' \
  --deskflow-core-candidate /absolute/path/to/deskflow-core \
  --deskflow-core-sha256 '<sha256>' \
  --deskflow-provenance-manifest /absolute/owner-only/path/deskflow-provenance.json \
  --deskflow-provenance-sha256 '<manifest sha256>' \
  --viewflow-unit-candidate /absolute/path/to/viewflow-peer.service \
  --viewflow-unit-sha256 '<sha256>' \
  --deskflow-dropin-candidate /absolute/path/to/deskflow-viewflow.conf \
  --deskflow-dropin-sha256 '<sha256>' \
  --quiesced-marker /absolute/path/to/viewflow-input-quiesced.json \
  --daemon-exit-evidence /absolute/path/to/viewflow-daemon-exited.json \
  --daemon-exit-observation /absolute/path/to/viewflow-daemon-exit-observation.json \
  --operation-id "$operation_id"
```

The transaction first confirms that quarantine is present and both units and
old listeners are already inactive, verifies the deployment marker tool has no
executing process, then backs up all six installed files and
consumes the receipt. It installs the Viewflow binary, Viewflow unit, and
Deskflow drop-in, verifies
their hashes, and runs `systemctl --user daemon-reload` before starting either
service. The coordinator-only marker tool is installed and rehashed but never
executed by the transaction or either unit. Viewflow readiness requires its
exact process, hash, UDP listener,
owner-only sidecar socket, full command-line identity including both quiescence
paths and both acceptance arguments, owner-only acceptance socket/state
directory, `protocol 2.1` log, authenticated peer, and successful health probe from
that same systemd invocation. Only then does it install and start the patched
Deskflow pair.
The sidecar IPC contract defines kind 12 (`QuarantineRecovery`) and kind 13
(`CleanupComplete`) bodies as exactly 176 and 277 bytes, respectively.
Deskflow readiness requires the expected GUI/core hashes, parent-child
relationship, route environment, TCP listener, loaded fixed quarantine path,
both processes' fixed acceptance-socket environment, its owner-only acceptance
socket, and proof that Viewflow routing remains refused while the marker is present.
Local installer success leaves quarantine active. The cross-host controller
must next prove the expected Windows and Linux hashes are mutually
authenticated on protocol 2.1 before authorizing the reviewed C++ owner to
durably release quarantine and verifying post-release route admission.

Any failure or termination signal stops both candidates, restores and hashes
all four old binaries plus both systemd files, reloads the user manager, and
leaves both units inactive with quarantine still present. It deliberately does
not restart old Viewflow or Deskflow: the Windows peer may already require a
different protocol, and restarting Deskflow could re-enable input routing.
Cross-host compatibility must be confirmed before manual recovery. Backups remain under
`~/.local/state/viewflow/deploy-backups/` after success or rollback.

Passing the transaction does not prove live edge switching or input delivery,
does not authorize quarantine removal, and does not authorize recovery disarm.
Those remain separate affected-client and cross-host acceptance gates.
