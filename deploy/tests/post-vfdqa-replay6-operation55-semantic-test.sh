#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077
source_script=${1:-/home/wilf/data/viewflow/deploy/reconcile-post-vfdqa-replay6-operation55.sh}
manifest=/home/wilf/data/viewflow/deploy/post-abort-replay6-operation55-manifest.json
root=$(mktemp -d /tmp/viewflow-post-vfdqa-fixture.XXXXXX)
trap 'rm -rf -- "$root"' EXIT
runtime=$root/runtime.json; windows=$root/windows.json
jq -cS --arg op 55d06e8f96aa4adc9010e53612979374 '
 {state:"CURRENT_RUNTIME_REATTESTED",operation_id:$op,observed_at_utc:"2026-08-31T15:26:28.161Z",boot_id:"11111111-2222-3333-4444-555555555555",
  units:{viewflow:(.linux_runtime.viewflow|del(.start_ticks,.exe_sha256)),deskflow:((.linux_runtime.deskflow|del(.processes)) + {main_pid:.linux_runtime.deskflow.processes[0].pid})},
  cgroup_pid_sets:{viewflow:[3202576],deskflow:[60344,60366,60411]},
  processes:{viewflow:[{role:"viewflow",pid:.linux_runtime.viewflow.main_pid,parent_pid:null,start_ticks:.linux_runtime.viewflow.start_ticks,exe_sha256:.linux_runtime.viewflow.exe_sha256,control_group:.linux_runtime.viewflow.control_group}],
             deskflow:[.linux_runtime.deskflow.processes[] + {control_group:.linux_runtime.deskflow.control_group}]}}
' "$manifest" >"$runtime"
jq -cnS --slurpfile m "$manifest" '
  $m[0] as $x |
  {schema_version:1,state:"viewflow-post-vfdqa-windows-census",operation_id:$x.operation_id,
   observed_at_utc:"2026-08-31T15:26:28.161Z",transport:"stdin-base64-single-scriptblock-stop-on-error-v1",
   operation_root:{path:$x.windows.operation_root,reparse:false,acl:{owner_sid:$x.windows.user_sid,protected:true,rules:[
       {sid:$x.windows.user_sid,type:"Allow",rights:"FullControl",inherited:false,inheritance:"ContainerInherit, ObjectInherit",propagation:"None"},
       {sid:"S-1-5-18",type:"Allow",rights:"FullControl",inherited:false,inheritance:"ContainerInherit, ObjectInherit",propagation:"None"}]},
     members:($x.windows.expected_members|to_entries|map({name:.key,directory:false,reparse:false,length:1,sha256:.value,acl:{owner_sid:$x.windows.user_sid,protected:(.key!="installer.stdout.log" and .key!="installer.stderr.log"),rules:[]}}))},
   deployment_task:{state:"Disabled",task_xml_sha256:$x.windows.observed_deployment_task_xml_sha256,action_execute:"powershell.exe",action_arguments:"-File start-viewflow-bootstrap.ps1",working_directory:$x.windows.operation_root},
   installed:($x.windows.installed_baseline|to_entries|map({name:.key,sha256:.value,acl:{owner_sid:$x.windows.user_sid,protected:false,rules:[]}})),
   peer:{task_state:"Running",task_xml_sha256:$x.windows.peer_task_xml_sha256,pid:$x.windows.peer_process.pid,parent_pid:$x.windows.peer_process.parent_pid,creation_date:$x.windows.peer_process.creation_date,session_id:1,owner_sid:$x.windows.user_sid,exe_sha256:$x.windows.peer_process.exe_sha256,command_line:"exact-old-command"},
   classification:{physical_abort:"VFDQA_COMMITTED",authorization_provenance:"AUTHZ_PROVENANCE_INVALID",prior_normal_terminal:"TERMINAL_ABSENT",current_runtime:"CURRENT_RUNTIME_REATTESTED",windows_baseline:"WINDOWS_BASELINE_TAINTED_NEEDS_REMEDIATION",normal_release_ready:false,fresh_bridge_ready:false}}
' >"$windows"
chmod 0600 "$runtime" "$windows"
"$source_script" --fixture --fixture-root "$root" --fixture-runtime-proof "$runtime" --fixture-windows-proof "$windows"
inventory=$root/post-abort-windows-inventory.replay6.schema2.json
runtime_out=$root/post-abort-linux-runtime-inventory.replay6.schema2.json
incident=$root/post-abort-incident-terminal.replay6.schema2.json
terminal=$root/failed-pre-mutation-abort-terminal.replay6.schema2.json
for f in "$inventory" "$runtime_out" "$incident" "$terminal"; do [[ -f $f && ! -L $f && $(stat -c '%u:%a:%h' "$f") == 1000:600:1 ]] || { echo "bad output metadata: $f" >&2; exit 1; }; done
jq -e --arg runtime "$(sha256sum "$runtime_out" | awk '{print $1}')" '.state=="viewflow-post-vfdqa-incident-terminal-reconciliation-required" and .incident_classification==["VFDQA_COMMITTED","AUTHZ_PROVENANCE_INVALID","TERMINAL_ABSENT"] and .current_runtime_classification=="CURRENT_RUNTIME_REATTESTED" and .normal_success_terminal==false and .normal_deployment_release==false and .rollback_performed==false and .fresh_bridge_ready==false and .old_authorization_retroactively_validated==false and .old_peer_kept_running==true and .linux_runtime_inventory_sha256==$runtime' "$incident" >/dev/null
jq -e '.state=="INVALID_AUTHZ_PROVENANCE_TOMBSTONE" and .fresh_bridge_ready==false and .normal_success_terminal==false and .old_authorization_retroactively_validated==false' "$terminal" >/dev/null
before=$(sha256sum "$inventory" "$runtime_out" "$incident" "$terminal")
"$source_script" --fixture --fixture-root "$root" --fixture-runtime-proof "$runtime" --fixture-windows-proof "$windows" >/dev/null
[[ $(sha256sum "$inventory" "$runtime_out" "$incident" "$terminal") == "$before" ]] || { echo 'crash replay changed outputs' >&2; exit 1; }
runtime_drift=$root/runtime-drift.json; jq '.boot_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"' "$runtime" >"$runtime_drift"; chmod 0600 "$runtime_drift"
if "$source_script" --fixture --fixture-root "$root" --fixture-runtime-proof "$runtime_drift" --fixture-windows-proof "$windows" >/dev/null 2>&1; then echo 'fresh Linux drift escaped durable-equivalence gate' >&2; exit 1; fi
windows_drift=$root/windows-drift.json; jq '.operation_root.members[0].acl.owner_sid="S-1-5-32-544"' "$windows" >"$windows_drift"; chmod 0600 "$windows_drift"
if "$source_script" --fixture --fixture-root "$root" --fixture-runtime-proof "$runtime" --fixture-windows-proof "$windows_drift" >/dev/null 2>&1; then echo 'fresh Windows drift escaped durable-equivalence gate' >&2; exit 1; fi
race=$(mktemp -d /tmp/viewflow-post-vfdqa-race.XXXXXX); printf 'occupied\n' >"$race/failed-pre-mutation-abort-terminal.replay6.schema2.json"; chmod 0600 "$race/failed-pre-mutation-abort-terminal.replay6.schema2.json"
if "$source_script" --fixture --fixture-root "$race" --fixture-runtime-proof "$runtime" --fixture-windows-proof "$windows" >/dev/null 2>&1; then echo 'occupied terminal was overwritten' >&2; exit 1; fi
[[ $(cat "$race/failed-pre-mutation-abort-terminal.replay6.schema2.json") == occupied ]] || { echo 'occupied terminal bytes changed' >&2; exit 1; }
rm -rf -- "$race"
poison_source=$root/reconcile-poison-check.sh; sed 's/ost.st_nlink==2/ost.st_nlink==99/' "$source_script" >"$poison_source"; chmod 0700 "$poison_source"
poison_root=$(mktemp -d /tmp/viewflow-post-vfdqa-poison.XXXXXX)
if "$poison_source" --fixture --fixture-root "$poison_root" --fixture-runtime-proof "$runtime" --fixture-windows-proof "$windows" >/dev/null 2>&1; then echo 'forced post-link verification failure unexpectedly passed' >&2; exit 1; fi
[[ ! -e $poison_root/post-abort-windows-inventory.replay6.schema2.json && ! -L $poison_root/post-abort-windows-inventory.replay6.schema2.json ]] || { echo 'failed created output was not cleaned' >&2; exit 1; }
rm -rf -- "$poison_root"
crash_root=$(mktemp -d /tmp/viewflow-post-vfdqa-link-crash.XXXXXX)
crash_orphan=$crash_root/.viewflow-inventory-copy.crash; crash_dst=$crash_root/post-abort-windows-inventory.replay6.schema2.json
cp -- "$windows" "$crash_orphan"; chmod 0600 "$crash_orphan"; ln -- "$crash_orphan" "$crash_dst"
[[ $(stat -c '%h' "$crash_dst") == 2 ]] || { echo 'failed to construct link-before-unlink crash fixture' >&2; exit 1; }
"$source_script" --fixture --fixture-root "$crash_root" --fixture-runtime-proof "$runtime" --fixture-windows-proof "$windows" >/dev/null
[[ ! -e $crash_orphan && ! -L $crash_orphan && $(stat -c '%u:%a:%h' "$crash_dst") == 1000:600:1 ]] || { echo 'link-before-unlink crash was not recovered' >&2; exit 1; }
rm -rf -- "$crash_root"
bridge=/home/wilf/data/viewflow/deploy/linux/bridge-abort-terminal-to-fresh-v21.sh
authorization=$(jq -r '.adopted_artifacts.invalid_provenance_authorization.path' "$manifest")
abort_binary=$(jq -r '.vfdqa_binary.path' "$manifest")
linux_started=$(jq -r '.adopted_artifacts.linux_started.path' "$manifest")
bridge_rejects() {
  local candidate rejection
  candidate=$1; rejection=$root/bridge-rejection.$(basename "$1").log
  if env -i HOME=/home/wilf PATH=/usr/bin:/bin "$bridge" --validate-inputs-only \
    --old-operation-id 55d06e8f96aa4adc9010e53612979374 \
    --abort-terminal "$candidate" --abort-terminal-sha256 "$(sha256sum "$candidate" | awk '{print $1}')" \
    --abort-authorization "$authorization" --abort-authorization-sha256 3a1ee0c9aadaf1674f7068ddaea864ab159ceaf75a2e0fe4884b6fd132df64f0 \
    --abort-binary-receipt "$abort_binary" --abort-binary-receipt-sha256 b78b35edd7769cdbb42db5724a6b9bd6eaccb5a34c83879505ebeb7e56888bdb \
    --linux-v13-started-receipt "$linux_started" --linux-v13-started-receipt-sha256 506281bd59fe982d9d8bdb7e6da6d4322b9b6aff9dfe61f2cbf0804abe728a9f \
    --bubblewrap-sha256 7c44fa8e7326e62e81ab3f70ff682bfc0eb3b447b39cf9fbb779a31948364762 \
    --installed-viewflow-sha256 d142fbbc65e311fa17b3307c252689afbb3963dda3e265cedc3bca7887daf96d \
    --installed-viewflow-unit-sha256 2a9595405c449fc36c45c6cf82c4906321ca15e18c2f4ee92f42313a845487ec \
    --deployment-marker-candidate /home/wilf/data/viewflow/target-premutation-abort-v21/release/viewflow-deployment-marker \
    --deployment-marker-sha256 e791a290aa112a1484bdfcce1de439a82e181ee5c1b3621f3b142d68e4e40b66 \
    --prepare-script /home/wilf/data/viewflow/deploy/prepare-v13-marker-handoff.sh \
    --prepare-script-sha256 6b1a2458d16ecfa8268bc334146637e163a7bf978e983f9d80bf90f3224f865b \
    --collector-script /home/wilf/data/viewflow/deploy/linux/collect-viewflow-v13-bootstrap-evidence.sh \
    --collector-script-sha256 be5c3b7be5fea3fab9f0ff772187d6d4ee7be885af8843b0999685265a60d8a9 \
    --bridge-root /home/wilf/.local/state/viewflow/bridges/55d06e8f96aa4adc9010e53612979374 >"$rejection" 2>&1; then
    return 1
  fi
  grep -F 'schema-2 abort terminal is invalid' "$rejection" >/dev/null
}
bridge_rejects "$incident" || { echo 'bridge accepted incident receipt' >&2; exit 1; }
bridge_rejects "$terminal" || { echo 'bridge accepted authz tombstone' >&2; exit 1; }
printf 'post-VFDQA replay6 semantic/crash/no-clobber fixture passed\n'
