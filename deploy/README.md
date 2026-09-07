# Live input deployment

The files in this directory are the reviewed Linux-to-Windows input-routing
configuration. Deskflow remains the Linux Portal InputCapture owner and keeps
handling all non-`WindowsVM` targets. Only events already routed to
`WindowsVM` are offered to the local Viewflow sidecar.

Deployment order matters. Linux replacement must use the quiescence marker and
transaction described in `linux/README.md`; do not stop either service merely
to create that evidence. The fixed durable Deskflow quarantine marker is a
separate fail-closed control. It must be published before the first service or
file mutation and remain active across both host installs. The legacy v1.3
bootstrap is the explicit exception: because v1.3 cannot read `VFDQT001`, the
operator must stop Deskflow before the helper publishes the marker.

For the one-time protocol-1.3 bootstrap, publication is an explicit prerequisite:

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

Protocol 1.3 does not recognize `VFDQT001`: first return the pointer to Linux
and stop Deskflow externally, then run the helper before collecting the frozen
Linux v1.3 boundary or starting the Windows bootstrap installer. The helper
requires `inactive`, `MainPID=0`, exact Deskflow/core process counts zero, TCP
24800 listener count zero, and legacy `VFQST002` absent. It changes only the
fixed marker CLI and the coordinator-owned `VFDQT001`/receipts; it does not
control a service or contact Windows. The create-once H receipt binds those
freeze observations and the exact raw publish-receipt bytes. The later
two-stage coordinator consumes the exact
prepublished receipt: bootstrap-stage preserves frozen Deskflow while providing
the quarantined Linux protocol-2.1 transport needed by the concurrent Windows
installer, while finalize consumes the daemon-authored Windows install receipt
before replacing the remaining Linux/Deskflow artifacts. It must not publish generation
1 again. Generation 2 is reserved for recovery requarantine. See
`BOOTSTRAP-v1.3-to-v2.md` for the complete binding and failure contract.

For this bootstrap only, the coordinator requires the local
`--linux-deactivation-transcript` output to have the exact basename
`linux-deactivation-transcript.json`. The proof records that basename and the
Windows rollback manifest pins the same operation-root leaf; a `.transcript`
or any other basename is rejected before the coordinator adopts durable inputs,
creates state, contacts Windows, or publishes an artifact.

The Linux Deskflow binaries also require the source/artifact provenance gate in
`linux/README.md`. Do not generate or retain the final persistent provenance
manifest until the pending P0 protocol 2.1/C++ changes have been rebuilt and
passed their normal tests; an earlier manifest binds the wrong ELF artifacts.
This manifest proves inspected state and integrity, not that the existing ELF
files were caused by that source. Build causality requires an isolated/fresh
rebuild with matching output hashes or a trusted build attestation.

The cross-host order is:

1. externally stop legacy Deskflow and prove inactive/MainPID/process/listener
   zero plus `VFQST002` absent; then install/verify the fixed coordinator marker CLI and publish the owner-only,
   operation-bound generation-1 durable quarantine marker plus create-once
   publish/H receipts with no-clobber semantics and durable parent-directory metadata;
2. for an already-protocol-2.1 update, prove the running Deskflow loaded the
   fixed marker path and refuses Viewflow route admission. For the v1.3
   bootstrap, retain and recheck the stopped-boundary H receipt instead. Then
   arm cross-host recovery before the first replace/start mutation;
3. quiesce the route. For an activated protocol-2.1 route, require `ReleaseAll`
   `Applied` followed by the exact lease-revoke `Applied` `RevokedAck`, then
   prove the old Linux daemon exited;
4. keep quarantine active while updating the Windows Viewflow peer and while
   transactionally updating Linux Viewflow and the patched Deskflow pair;
5. prove both expected Viewflow hashes are connected to each other over the
   authenticated protocol-2.1 session. Separately prove the Linux process,
   UDP listener, per-invocation log, owner-only sidecar socket, Deskflow
   process pair, route environment, listener, and quarantine refusal;
6. authorize the reviewed quarantine owner to durably remove the marker only
   after that two-ended gate, then verify route admission and entry/return;
7. verify held inputs and every disconnect path. Only after the post-release
   checks pass may the coordinator enter `SUCCESS_DISARMED` and clear recovery
   traps.

Every failure after quarantine publication leaves the marker present and both
old runtimes inactive. Recovery must never remove the marker, and Windows
rollback remains ordered after confirmed Linux inactivity.

## Deployment quiescence

For protocol 2.1 and later, configure both `--quiesce-proof` and
`--quiesce-arm-file` on the Linux serving peer. An update controller must arm a
unique operation against the exact daemon PID, stop Deskflow, call
`trigger-quiesce` against the sidecar socket, and wait for both the receipt and
the exact daemon instance to exit. Calling `trigger-quiesce` covers the case
where Deskflow was already disconnected when the operation was armed.

The daemon-produced normal receipt and Windows-consumed marker are schema 4.
For an activated route, transport delivery alone is never cleanup proof: the
receipt must include the exact `ReleaseAll` Applied ACK and the exact
`RevokedAck` with `operation_id`, next `lease_generation`, `owner_device`,
`target_device`, `state=revoked`, and `result=applied`, bound to the active
generation and authenticated peer epoch.

An unarmed sidecar disconnect performs normal route cleanup but cannot write a
deployment receipt or stop the daemon. The receipt reports peer disconnect as
`initiated_before_daemon_exit`; only the Windows marker producer may promote it
to `confirmed_by_daemon_exit`, after validating command-derived evidence for
`MainPID=0`, no exact process, no UDP listener, and no sidecar socket.

The installed protocol-1.3 peers cannot produce this receipt. See
`BOOTSTRAP-v1.3-to-v2.md`; the filename is retained for historical tooling,
but the current target is protocol 2.1. The first upgrade additionally requires
an unconditional Windows Session 1 stateless force-release after the old task
has remained stopped. Linux zero-route evidence freezes the upgrade boundary
but does not replace that Windows release step.

## Reproducible Windows source snapshot

Build the Windows source bundle from Linux only after the workspace validation
gate has passed. The packager rejects a missing root `Cargo.toml`, `Cargo.lock`,
or `protocol/viewflow/v1/control.proto`; rejects source symlinks and special
files; excludes `.agents` and `.codex`; and rejects every file or directory
named `.git` or `target` at any depth. Package from a clean allowlisted staging
tree, not directly from a Git worktree or a Cargo build tree. Its top-level
allowlist contains only `.gitignore`,
`Cargo.toml`, `Cargo.lock`, `LICENSE`, `README.md`, `crates`, `deploy`, `docs`,
`platform`, and `protocol`. Any other top-level path fails packaging so editor
logs, local credentials, and other temporary artifacts cannot silently enter a
Windows source bundle. Any case variant of `SOURCE-MANIFEST.sha256` anywhere in
the source tree is reserved and rejected, as are deprecated duplicate packager
entry points and paths containing backslashes, line breaks, or other names that
Windows cannot represent. The packager freezes source file and directory
identities across the copy, normalizes every archived file to mode `0644` and
every directory to `0755`, then extracts the generated archive into a second
private directory and verifies its complete path set and strict manifest before
publication.

The output must be outside the source tree so a previous artifact cannot enter
the next snapshot:

```bash
deploy/scripts/package-windows-source.sh \
  --source /tmp/viewflow-windows-source-stage \
  /tmp/viewflow-windows-source.tar.gz
```

The command writes the archive, an adjacent per-file
`viewflow-windows-source.tar.gz.manifest.sha256`, and an archive checksum file
`viewflow-windows-source.tar.gz.sha256`. The same manifest is stored inside the
archive as `viewflow-source/SOURCE-MANIFEST.sha256`. It also prints both the
archive and manifest SHA-256 values. Preserve that output with the deployment
record and verify the manifest after extraction before invoking Cargo on
Windows. Publication backs up any prior three-file set and restores all three
files if a normal publication step or signal fails. Consumers must still treat
the archive plus both sidecars as one unit and verify them before extraction.
The Windows verification order is: reject non-regular artifacts; verify the
archive checksum and its exact filename; preflight every archive entry; extract
into a new directory; recheck the archive hash; reject reparse points; compare
the external and internal manifests; verify every listed file; reject extra
archive or extracted files; confirm required paths; and only then run Cargo.

Run the focused packager test with:

```bash
deploy/scripts/check-package-windows-source.sh
deploy/scripts/tests/package-windows-source-test.sh
```

The source-display identifier is a stable non-zero local routing identifier.
It is not a security identity. Device identities must match the daemon command
lines on both hosts.
