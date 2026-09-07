# Schema-2 abort terminal to a fresh 2.1 bootstrap

`bridge-abort-terminal-to-fresh-v21.sh` is the Linux-only transaction between
a successful failed-pre-mutation `VFDQA001` abort and the normal
`coordinated-v13-to-v2.sh` entrypoint.  It does not edit or resume the aborted
coordinator state, and it never contacts Windows.

## Safety boundary

The bridge accepts only the exact schema-2 terminal in which force release and
rollback were both false.  It cross-binds the strict authorization JSON, the
content-addressed 384-byte `VFDQA001` receipt, its embedded `VFDQT001`, and the
old Linux Viewflow start receipt.  The old operation ID cannot be reused.

Before stopping either transient unit it reattests both manager `ExecStart`
hashes and every recorded PID, start tick, InvocationID, cgroup and executable
hash.  It then queries the recovered Deskflow core's sidecar-3 acceptance
socket.  An active route must be armed and return a normal acknowledged
`ReleaseAll Applied` plus lease-revoke cleanup receipt.  With no active route,
the exact live acceptance status is retained only when no stale cleanup
receipt is available.  Only either durable
proof permits Deskflow-first, Viewflow-second shutdown.  The final zero gate
covers both transient cgroups, all three exact executables, ports 24800/44119,
the sidecar socket, and `VFQST002`.

The four temporary runtime masks and
`zz-direct-deskflow.conf` are moved with `renameat2(RENAME_NOREPLACE)` into an
owner-only retained backup directory.  Their original inode, type, owner,
mode, link count and content/link-target hash are frozen first.  A restart
continues a same-inode move; both names, neither name, or changed bytes fail
closed.  The bridge does not unlink these recovery artifacts.

After the manager reload, only the installed old Viewflow service is started.
The bridge invokes the reviewed `prepare-v13-marker-handoff.sh` and
`collect-viewflow-v13-bootstrap-evidence.sh` by exact supplied hashes.  It
creates a new 32-hex operation ID and a different canonical coordinator UUID,
publishes generation 1 `VFDQT001` plus H, then freezes that exact persistent
v1.3 invocation into B.  Partial marker publication and a collector crash
after daemon stop are recovered from the immutable plan, marker bytes,
collector intent, and exact invocation journal; a second marker publication or
a second operation is never attempted.

Fresh B is accepted only on the current boot and for 30 minutes, matching the
normal bootstrap consumption window.  Existing cleanup, H, B and final bridge
receipts are strict-schema revalidated on resume; pre-created or altered
create-once outputs fail closed.

The successful terminal receipt is
`$FRESH_ROOT/abort-terminal-to-fresh-v21.json`.  Its sibling
`deployment-publish.json`, `marker-handoff.json`, and `linux-frozen.json` are
the fresh inputs for the normal coordinator.

## Invocation template

Run only after the schema-2 abort gate has successfully published its terminal
and durable binary receipt.  Recompute every hash from the final files; do not
copy the placeholders below.

```bash
OLD=55d06e8f96aa4adc9010e53612979374
OLD_ROOT=/home/wilf/.local/state/viewflow/deployments/$OLD
BRIDGE_ROOT=/home/wilf/.local/state/viewflow/bridges/$OLD

/usr/bin/env -i HOME=/home/wilf PATH=/usr/bin:/bin \
  /usr/bin/bash /home/wilf/data/viewflow/deploy/linux/bridge-abort-terminal-to-fresh-v21.sh \
  --execute \
  --old-operation-id "$OLD" \
  --abort-terminal "$OLD_ROOT/failed-pre-mutation-abort-terminal.replay4.schema2.json" \
  --abort-terminal-sha256 TERMINAL_SHA256 \
  --abort-authorization "$OLD_ROOT/failed-pre-mutation-abort-authorization.replay4.schema2.json" \
  --abort-authorization-sha256 AUTHORIZATION_SHA256 \
  --abort-binary-receipt /home/wilf/.local/state/viewflow/.deployment-quarantine.v1.abort-receipt.MARKER_SHA256.AUTHORIZATION_SHA256.v1 \
  --abort-binary-receipt-sha256 VFDQA_SHA256 \
  --linux-v13-started-receipt "$OLD_ROOT/linux-v13-started.schema2.json" \
  --linux-v13-started-receipt-sha256 LINUX_STARTED_SHA256 \
  --bubblewrap-sha256 BUBBLEWRAP_SHA256 \
  --installed-viewflow-sha256 OLD_VIEWFLOW_SHA256 \
  --installed-viewflow-unit-sha256 OLD_VIEWFLOW_UNIT_SHA256 \
  --deployment-marker-candidate /home/wilf/data/viewflow/target-premutation-abort-v21/release/viewflow-deployment-marker \
  --deployment-marker-sha256 MARKER_CLI_SHA256 \
  --prepare-script /home/wilf/data/viewflow/deploy/prepare-v13-marker-handoff.sh \
  --prepare-script-sha256 PREPARE_SCRIPT_SHA256 \
  --collector-script /home/wilf/data/viewflow/deploy/linux/collect-viewflow-v13-bootstrap-evidence.sh \
  --collector-script-sha256 COLLECTOR_SCRIPT_SHA256 \
  --bridge-root "$BRIDGE_ROOT"
```

After a crash, repeat the exact command with `--resume` instead of `--execute`.
Do not delete the plan, intent, retained config backups, partial H/B outputs, or
marker names before resuming.

## Offline checks

```bash
bash deploy/linux/check-bridge-abort-terminal-to-fresh-v21.sh
bash deploy/linux/tests/bridge-abort-terminal-to-fresh-v21-input-fixture-test.sh
bash deploy/linux/tests/bridge-abort-terminal-to-fresh-v21-cleanup-fixture-test.sh
bash deploy/linux/tests/bridge-abort-terminal-to-fresh-v21-static-negative-test.sh
shellcheck --severity=error \
  deploy/linux/bridge-abort-terminal-to-fresh-v21.sh \
  deploy/linux/check-bridge-abort-terminal-to-fresh-v21.sh \
  deploy/linux/tests/bridge-abort-terminal-to-fresh-v21-*.sh
```

These checks are source/fixture proof only.  They do not authorize or claim a
live transition.
