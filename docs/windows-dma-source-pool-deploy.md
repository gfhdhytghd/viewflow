# Fixed v3 normal-task deployment

`tools/deploy-windows-dma-source-pool.ps1` is prepared locally only. It has not been uploaded or run. Deployment remains the root operator's action after benchmark cleanup.

The script is fixed to `viewflow_windows_reverse.dma-integrated-v3.exe`, SHA256 `D946A703FABCA9C794F4758A9D49A5490E00C678BD01FD0E1A7842B1770D62DB`; a later build of another candidate cannot change its target. It updates the existing peer configuration's backend.native and adds `VIEWFLOW_SHM_D12_SOURCE_POOL=1` to the normal wrapper. The task action and registration stay unchanged.

Before execution, parse the script on Windows without invoking it:

```powershell
$tokens=$null; $errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Deployment script syntax errors'}
```

Run without `-Apply` first for read-only preflight. For the actual switch pass `-Apply -BackupDirectory <new-absolute-directory>`. The directory must not already exist. No configuration contents are printed.

The script saves original wrapper/config bytes and exported task XML before stopping the normal task. It identifies only the wrapper's process tree, pins process handles, compares captured creation time with process StartTime, then waits on those handles after Stop-ScheduledTask. Matching native instances are checked read-only before starting a replacement. There is no global kill or SHM reset.

After verified old-process exit it atomically replaces the two files, starts the same task, and verifies a descendant native at the exact fixed path remains alive for two seconds. Failure after mutation stops and verifies the candidate tree before restoring the exact original bytes and restarting/verifying the old native path. If owned exit or restoration cannot be confirmed, it leaves a blocked result rather than start a second writer. Task XML is retained for review but is never automatically re-registered because the script never changes the task definition.

This is an administrative job stop, not graceful GPU draining. Startup verification proves executable identity and short survival, not source-pool usage, visual correctness, or latency. Windows parser verification and execution are pending root; local preparation did not access Windows or normal services.

Follow-up validation: Windows PowerShell Parser passed for the revised script. Its actual `Replace-Bytes` AST function was extracted without invoking the deployment body and tested only in a unique Windows TEMP directory: exact forward bytes, exact rollback bytes, and no leaked helper temporary/backup files all passed. Replacement now supplies File.Replace a real unique backup path instead of a null string argument. Failure records include sanitized exception type/HResult for both the main error and rollback error, without exception text or configuration contents.

Task startup now emits `candidate-task-started` and writes `start-candidate.json` containing only state/UTC. Root must reconnect the Linux service upon that marker while the Windows script waits up to 30 seconds for native startup. Rollback emits `rollback-task-started` with `start-rollback.json`; restoring an unmodified original emits `original-task-started` with `start-original.json`. Both likewise require root to reconnect Linux. A missing native after 30 seconds explicitly means startup remains unconfirmed and may require peer reconnect; it does not prove the configuration is invalid. The Windows script never controls Linux.
