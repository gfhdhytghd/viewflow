# Operation 902 deployment checkpoint

Operation: `902bd39e80df420394cfa3ece89e2136`.
Coordinator: `d3ac8fa1-b623-49c4-9e97-513012a1328d`.
Observed on 2026-09-04 around 20:57 UTC; recheck live state before acting.

The recovery bridge completed and the normal pipeline prepared its candidate
and launcher successfully. Live execution then failed in the Windows installer
before mutation, with:

```text
Quiesced marker Bootstrap completed_at_unix_ms is stale or from the future
```

The pipeline was invoked with a 1,800-second publication age allowance. The
Windows installer independently enforces 300 seconds on the Linux bootstrap
completion evidence. Publication freshness alone is insufficient. Do not renew
timestamps, overwrite evidence, or retry this operation as a fresh launch.

Authoritative evidence is under:

```text
/home/wilf/.local/state/viewflow/deployments/902bd39e80df420394cfa3ece89e2136/
```

- `coordinator-state.json`: phase `LINUX_RECOVERED`, recovery failure phase
  `WINDOWS_STARTED`, `mutation_possible: false`.
- `windows-installer-exit.json`: exit 1, completed at
  `2026-09-04T20:56:19.819Z`.
- `first-candidate-commit.json` and `launch-normal-v21.sh` exist and must be
  preserved with their original hashes.
- Windows logs remain under the matching `Viewflow\Deployments` operation
  directory as `installer.stderr.log` and `installer.stdout.log`.

After failure, Linux `viewflow-peer.service` and `deskflow.service` were
inactive with MainPID 0. Windows old `viewflowd.exe` PID 27480 remained running;
the `Viewflow Peer` scheduled task reported Running. This is recovery-state
evidence, not proof of a working 2.1 input deployment.

The deployment marker was not removed by this attempt. Complete its supported
abort lifecycle before creating another operation. The native window capture,
codec, and proxy presentation pipeline remains unfinished.
