# One-time protocol 1.3 to 2.1 bootstrap

The filename retains `v2` for compatibility with existing review and tooling;
the only currently authorized destination is protocol 2.1.

The currently installed Linux and Windows peers predate the deployment
quiescence receipt. They advertise protocol 1.3 and cannot truthfully produce a
schema-4 receipt. The normal protocol-2.1 installer must never reinterpret
journal text, an operator boolean, or a receipt from a different process as
proof about those running v1.3 processes.

The dedicated Linux schema-1 evidence producer proves only the frozen upgrade
boundary: it inventories the exact old Linux invocation, freezes admission by
requiring Deskflow stopped, and proves that old daemon has exited. It does not
prove that Windows has no
OS-level key or button state left by an earlier connection or invocation.
Therefore every first upgrade, including a zero-activity current invocation,
must run an independent stateless force-release in Windows Session 1 after the
old Windows task has remained stopped.

Required one-time sequence:

1. Move the pointer back to Linux and stop Deskflow externally. Confirm its unit
   is inactive with `MainPID=0`, both exact executable process counts are zero,
   TCP 24800 has no listener, and legacy `VFQST002` is absent. Protocol 1.3
   does not understand `VFDQT001`, so publishing the deployment marker before
   this freeze would not close route admission.
2. Before running the Linux evidence collector or invoking the Windows
   installer, run `prepare-v13-marker-handoff.sh`. It independently rechecks
   the complete frozen boundary, installs and verifies only the reviewed marker
   CLI candidate at the fixed coordinator path, then publishes generation 1 of
   the owner-only, operation-bound durable deployment marker with no-clobber
   semantics and durable parent-directory updates. It never stops/starts a
   service or contacts Windows. Keep the marker active through every following
   step and arm cross-host recovery before the first replace/start mutation.
3. Run `linux/collect-viewflow-v13-bootstrap-evidence.sh` with the exact current
   daemon `MainPID`, running-executable SHA-256, a unique operation ID, and a
   new path in an owner-only directory. The producer binds PID, start ticks,
   boot ID, executable hash, and systemd InvocationID. It requires one exact
   protocol-1.3 startup line and captures the journal start/end cursors,
   timestamps, and raw slice hash.
4. The producer records all `lease_offered`, `input_event_sequence`,
   input-sidecar activation, and cleanup/release-error matches without treating
   their values as cleanup proof. It then stops only the old Viewflow unit,
   recaptures the now-terminal invocation, repeats every count, and requires
   `inactive`, `MainPID=0`, exact process count 0, UDP 44119 count 0, the
   original PID gone, and the sidecar socket absent. Those command outputs are
   hashed into the schema-1 record. Keep the old binary and identity files
   unchanged for rollback.
5. Copy the untouched schema-1 record to Windows. The bootstrap consumer must
   recheck its exact field set and hashes, require the same operation ID, and
   reject it unless `-AllowV13Bootstrap` was explicitly supplied. The normal
   schema-4 marker producer rejects protocol 1.3 and is not used for this step.
6. After consuming the Linux evidence, the Windows installer must stop the old
   scheduled task and observe both the task and exact installed daemon absent
   for the full stability interval. It must then invoke the already hash-bound
   candidate's dedicated stateless force-release command in Session 1.
7. The force-release command must send explicit key-up and button-up events for
   every input supported by the Viewflow Windows backend, require the complete
   `SendInput` batch to be accepted, and atomically emit an independent receipt
   bound to the operation ID, candidate executable hash, current user SID, and
   Session 1. Failure or a missing/mismatched receipt aborts before replacement.
   A fresh protocol connection and its empty pressed-state tracker can never
   substitute for this step.
8. With Deskflow still stopped and quarantine active, the coordinator's
   bootstrap stage may bring up only the quarantined Linux protocol-2.1
   transport needed by the concurrent Windows installer. After the
   daemon-authored Windows install/readiness receipt exists, finalize the Linux
   protocol-2.1 transaction and patched Deskflow pair. Do not restore routing
   between those stages.
9. Require the Windows schema-2 install-success receipt and readiness
   receipt/lock, then independently prove the expected Windows and Linux
   executable hashes are mutually authenticated on protocol 2.1. Starting
   both processes is not this two-ended proof.
10. Only after that gate may the controller authorize the reviewed C++ owner to
    durably unlink quarantine. Verify route admission after release, then and
    only then enter `SUCCESS_DISARMED` and clear recovery traps.

The prerequisite command is deliberately separate from the later two-stage
coordinator. Use one operation ID and one set of source, target, and coordinator
UUIDs for the complete transaction:

```bash
deploy/prepare-v13-marker-handoff.sh \
  --deployment-marker-candidate /absolute/path/to/viewflow-deployment-marker \
  --deployment-marker-sha256 '<reviewed release SHA-256>' \
  --operation-id "$operation_id" \
  --source-display-id "$source_display_id" \
  --target-device-id "$target_device_id" \
  --coordinator-instance-id "$coordinator_instance_id" \
  --marker-generation 1 \
  --deployment-publish-receipt /absolute/new/owner-only/deployment-publish.json \
  --bootstrap-handoff-receipt /absolute/new/owner-only/bootstrap-handoff.json
```

The helper refuses an existing marker or receipt. It freezes the candidate
identity while copying, atomically installs the exact candidate at
`/home/wilf/.local/lib/viewflow/viewflow-deployment-marker`, requires that path
to be idle and owner-1000 mode `0755`, invokes only that installed path, and
publishes the receipt create-once as owner-1000 mode `0600`. The receipt binds
the operation, source, target, coordinator, generation, fixed marker path, and
SHA-256 of the exact 256-byte `VFDQT001` file. If anything fails after marker
publication, the marker remains fail-closed; do not delete it or rerun with a
different identity.

The second create-once H receipt additionally binds the exact marker CLI and
legacy Deskflow/core hashes, the raw deployment-publish receipt path/hash, and
the observed freeze facts: `deskflow.service=inactive`, `MainPID=0`, both exact
process counts zero, TCP 24800 listener count zero, and legacy `VFQST002`
absent. The later coordinator must recheck the live freeze and consume both
receipts; H is not permission to restart legacy Deskflow.

The later coordinator must consume this existing receipt and marker as an
input, never republish generation 1. Its bootstrap stage preserves the frozen
Deskflow boundary while providing the quarantined Linux protocol-2.1 transport
that the concurrent Windows installer needs for authenticated readiness. Only
the finalize stage may consume the daemon-authored Windows install receipt and
proceed with the remaining Linux/Deskflow replacement.
Recovery publication is a distinct generation 2 operation. These stage/wait/
finalize boundaries prevent a Linux-readiness/Windows-install-receipt cycle;
neither stage is allowed to weaken the prepublished marker binding.

Validate the prerequisite helper before use:

```bash
deploy/check-prepare-v13-marker-handoff.sh
deploy/tests/prepare-v13-marker-handoff-semantic-test.sh
deploy/tests/prepare-v13-marker-handoff-static-negative-test.sh
```

The Windows force-release receipt and Windows schema-2 install-success receipt
both
carry `linux_frozen_evidence_sha256`, the lowercase SHA-256 of the exact Linux
schema-1 evidence bytes. The install-success receipt also carries
`force_release_receipt_sha256`, the lowercase SHA-256 of the exact force-release
receipt bytes, plus the hashes of its readiness receipt and lock, the
authenticated connection generation, and establishment time. Linux recomputes
these bindings from the consumed files and rejects
missing, uppercase, legacy-named, or mismatched fields. Cross-host wall clocks
are used only for per-host freshness checks; they are not the authorization
chain. The receipt hash chain establishes the causal sequence, while the two
Windows timestamps must still be ordered force-release before install.

Until the Windows stateless force-release command, its independent receipt, and
the bootstrap installer consumer all pass their mutation and native Session 1
tests, the first live 1.3-to-2.1 replacement remains blocked after Linux
evidence collection. This is intentional: a schema-1 record is not a schema-4
receipt, connection teardown alone is not proof that old Windows key/button
state was released, and successful protocol-2.1 no-route quiescence cannot
prove state created by an earlier v1.3 connection.

The producer and its static mutation tests are read-only until the producer is
explicitly invoked:

```bash
deploy/linux/check-v13-bootstrap-collector.sh
deploy/linux/tests/v13-bootstrap-collector-static-negative-test.sh
```

The output has `schema_version: 1` and
`state: "viewflow-v13-bootstrap-frozen"`. It is only frozen-exit evidence,
never a ReleaseAll or quiescence proof, and it is never
accepted by the normal schema-4 transaction.

The Linux finalize transaction consumes all three bootstrap artifacts with the
reviewed Windows hashes and SID supplied explicitly. It runs only after the
two-stage coordinator has obtained the Windows install receipt:

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
  --viewflow-unit-candidate /absolute/path/to/viewflow-peer.service \
  --viewflow-unit-sha256 '<sha256>' \
  --deskflow-dropin-candidate /absolute/path/to/deskflow-viewflow.conf \
  --deskflow-dropin-sha256 '<sha256>' \
  --operation-id "$operation_id" \
  --bootstrap-linux-evidence /absolute/path/viewflow-v13-bootstrap-frozen.json \
  --bootstrap-windows-force-receipt /absolute/path/viewflow-force-release.json \
  --bootstrap-windows-install-receipt /absolute/path/viewflow-v2-windows-installed.json \
  --windows-viewflow-sha256 '<reviewed Windows viewflowd.exe sha256>' \
  --windows-wrapper-sha256 '<reviewed viewflow-client.ps1 sha256>' \
  --windows-task-xml-sha256 '<reviewed scheduled-task XML sha256>' \
  --windows-user-sid '<expected Session-1 user SID>'
```

All three artifacts must be owner-only, unchanged since preflight, and on the
same filesystem as the transaction backup. The installer validates the full
bundle, performs an immediate live stopped-state recheck, moves the three files
exactly once, revalidates their inode/hash/schema relationships from the backup,
and performs a second live stopped-state recheck before replacing any file.

After both peers run protocol 2.1, all later updates use the one-shot arm flow:

```text
durable quarantine -> prove admission refused -> arm recovery -> arm-quiesce ->
stop Deskflow -> trigger-quiesce -> schema-4 daemon receipt ->
exact daemon exit evidence -> Windows schema-4 marker -> both host installers ->
two-ended authenticated 2.1 readiness -> durable quarantine release ->
post-release admission proof -> recovery disarm
```

Rollback is fail-closed. Restore and hash-check the old artifacts, but keep the
durable quarantine marker present and both Viewflow and Deskflow inactive.
Windows rollback remains after confirmed Linux inactivity. Recovery never
removes quarantine; a new reviewed transaction is required to reach the
two-ended release gate.
