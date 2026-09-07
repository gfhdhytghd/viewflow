#!/usr/bin/env bash
# shellcheck disable=SC2016
# Static, fail-closed contract checker for the Linux early-abort bridge.
# This checker is intentionally source-only: it never invokes the bridge.
set -Eeuo pipefail

readonly SOURCE=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bridge-early-abort-terminal-to-fresh-v21.sh}
fail() { printf 'error: early-abort bridge checker: %s\n' "$*" >&2; exit 1; }

[[ -f $SOURCE && ! -L $SOURCE ]] || fail 'source must be a regular non-symlink file'
bash -n "$SOURCE" || fail 'source is not valid bash'

# Ignore comments so a deleted executable guard cannot be satisfied by prose.
fixed() {
    local token=$1 label=${2:-$1}
    awk -v token="$token" '!/^[[:space:]]*#/ && index($0,token){found=1} END{exit !found}' "$SOURCE" || fail "missing $label"
}
count_is_one() {
    local token=$1 label=${2:-$1} count
    count=$(awk -v token="$token" '!/^[[:space:]]*#/ {n+=index($0,token)>0} END{print n+0}' "$SOURCE")
    [[ $count == 1 ]] || fail "$label must have one executable anchor (found $count)"
}
line_of() { awk -v token="$1" '!/^[[:space:]]*#/&&index($0,token){line=NR} END{print line+0}' "$SOURCE"; }
function_line() { awk -v fn="$1" '$0 ~ "^" fn "\\(\\)" {print NR; exit}' "$SOURCE"; }

# Invocation boundary and immutable input handling.
fixed 'if [[ ${BASH_SOURCE[0]} != "$0" ]]; then' 'execute-not-source guard'
fixed 'LD_PRELOAD' 'loader environment rejection'
fixed 'PYTHONPATH' 'Python startup environment rejection'
fixed 'readonly PATH=/usr/bin:/bin' 'fixed PATH'
fixed 'umask 077' 'owner-only umask'
fixed 'readonly XDG_RUNTIME_DIR=/run/user/1000' 'explicit runtime directory'
fixed 'readonly DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' 'explicit user bus'
fixed 'export PATH XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS' 'exported explicit user bus'
fixed 'env -i PATH=/usr/bin:/bin /usr/bin/python3 -I' 'clean pinned Python execution'
fixed 'object_pairs_hook=pairs' 'duplicate JSON key rejection'
fixed 'parse_float=reject_float' 'floating-point JSON rejection'
fixed 'type(value) is not int' 'strict Python integer type gate'
fixed "re.fullmatch(r'[1-9][0-9]*',value)" 'canonical decimal lexical gate'
fixed 'validate_input_scalar_contract' 'strict input scalar contract invocation'
fixed 'text[end:].strip()' 'trailing JSON rejection'
fixed 'exact_file()' 'exact input file validator'
fixed '(expected_size and before.st_size!=int(expected_size))' 'stable-open exact-size validation'
fixed 'ident(before)!=ident(after)' 'stable-open identity gate'
fixed 'identity(before)!=identity(after)' 'snapshot source stable-open identity gate'
fixed 'snapshot_inputs()' 'execute immutable snapshot boundary'
fixed 'immutable-inputs' 'owner-only snapshot namespace'
fixed 'snapshot source identity/hash differs' 'snapshot source hash gate'
fixed 'sealed snapshot differs' 'snapshot replay byte gate'
fixed 'snapshot_one terminal early-gate-terminal.json "$terminal_sha" 400' 'read-only JSON snapshot mode'
fixed 'snapshot_one prepare_script prepare-v13-marker-handoff.sh "$prepare_script_sha" 555' 'read-only script snapshot mode'
fixed 'os.fchmod(fd,mode)' 'snapshot exact mode after umask'
fixed 'published snapshot identity/hash/mode differs' 'snapshot post-publication reopen gate'
fixed 'chmod 0500 "$directory"' 'sealed snapshot directory mode'
fixed 'snapshot_one terminal early-gate-terminal.json' 'terminal snapshot'
fixed 'snapshot_one prepare_script prepare-v13-marker-handoff.sh' 'prepare script snapshot'
fixed 'snapshot_one collector_script collect-viewflow-v13-bootstrap-evidence.sh' 'collector script snapshot'
fixed 'ensure_roots; snapshot_inputs; validate_inputs; make_plan' 'snapshot revalidation before durable plan'

# Old terminal, schema-3 authorization, and stable pre-abort snapshots.
fixed 'keys==["abort_claim_absent","abort_receipt_sha256"' 'schema-1 exact terminal keys'
fixed '.schema_version==1 and .state=="viewflow-early-bootstrap-gate-abort-terminal"' 'schema-1 early terminal state'
fixed '.deskflow_unit_state=="inactive" and .deskflow_process_count==0' 'schema-1 Deskflow zero proof'
fixed 'keys==["authenticated_v13_peer_receipt_sha256","authorization_receipt_path"' 'schema-3 exact authorization keys'
fixed '.schema_version==3 and .state=="viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized"' 'schema-3 authorization state'
fixed 'coordinator_mutation_possible==false' 'no-mutation authorization gate'
fixed 'windows_bootstrap_worker_created==false' 'no Windows worker gate'
fixed 'windows_new_operation_root_present==false' 'no fresh Windows root gate'
fixed 'windows_new_task_present==false' 'no fresh Windows task gate'
fixed 'all([.marker_handoff_receipt_sha256,.deployment_publish_receipt_sha256' 'authorization hash fields'
fixed 'for key in coordinator_terminal_state_sha256' 'authorization/abort cross-binding loop'
fixed 'jq -cS --arg key "$key" '\''.[$key]'\'' "$abort_receipt"' 'canonical cross-binding comparison'
fixed 'keys==["abort_authorization_path","abort_authorization_sha256","abort_claim_path"' 'schema-3 abort receipt exact keys'
fixed 'VFDQA001' 'VFDQA magic'
fixed "b[8:13]!=bytes((1,1,1,3,1))" 'VFDQA schema/protocol bytes'
fixed "m[:13]!=b'VFDQT001" 'embedded marker header'
fixed 'hashlib.sha256(m).hexdigest()!=marker_sha' 'embedded marker hash binding'
fixed 'm[16:16+len(raw)]!=raw' 'embedded operation binding'
fixed "uuid.UUID('00000000-0000-0000-0000-000000000101').bytes" 'VFDQA source binding'
fixed "uuid.UUID('00000000-0000-0000-0000-000000000002').bytes" 'VFDQA target binding'
fixed 'uuid.UUID(coord).bytes' 'VFDQA coordinator binding'
fixed 'm[176:192]!=uuid.UUID(coord).bytes' 'VFDQA embedded coordinator binding'
fixed 'b[272:304].hex()!=marker_sha' 'VFDQA marker hash field'
fixed 'b[304:336].hex()!=auth_sha' 'VFDQA authorization hash field'
fixed 'hashlib.sha256(b[:352]).digest()!=b[352:384]' 'VFDQA checksum'
fixed 'len(b)!=384' 'VFDQA exact size'
fixed 'durable == "$vfdqa_claim_path"' 'durable VFDQA path cross-binding'
fixed 'exact_file '\''durable VFDQA snapshot/source'\'' "$vfdqa" "$vfdqa_sha" "$data_mode" 384' 'VFDQA source/snapshot exact size and dynamic mode'
fixed 'exact_file '\''content-addressed durable VFDQA original'\'' "$vfdqa_claim_path" "$vfdqa_sha" 600 384' 'original content-addressed VFDQA stable-open mode/size/hash'

fixed 'validate_snapshot "$linux_started"' 'stable Linux-start snapshot validation'
fixed 'validate_snapshot "$post_reattest"' 'stable post-abort snapshot validation'
fixed '.linux==$started[0].linux and .windows==$started[0].windows' 'stable tuple cross-binding'
fixed 'viewflow_control_group' 'Linux control-group claim'
fixed 'viewflow_start_ticks' 'Linux start-ticks claim'
fixed 'viewflow_invocation_id' 'Linux invocation claim'
fixed 'viewflow_exec_start_sha256' 'Linux ExecStart hash claim'
fixed '.linux.viewflow_main_pid|type=="number"' 'Linux PID type gate'
fixed '.linux.viewflow_process_count==1' 'Linux process census'
fixed '.linux.viewflow_udp_listener_count==1' 'Linux UDP ownership census'
fixed '.linux.viewflow_sidecar_listener_count==1' 'Linux sidecar ownership census'
fixed '.windows.task_path=="\\\\"' 'Windows task path claim'
fixed '.windows.task_name=="Viewflow Peer"' 'Windows peer task claim'
fixed '.windows.task_state=="Running"' 'Windows task state claim'
fixed '.windows.request_sha256==$request' 'Windows request authorization binding'
fixed '.windows.viewflowd_sha256==$windows_vf' 'Windows executable authorization binding'
fixed '.windows.wrapper_sha256==$wrapper' 'Windows wrapper authorization binding'
fixed '.windows.task_xml_sha256==$task_xml' 'Windows task XML authorization binding'
fixed '.windows.rollback_sha256==$rollback' 'Windows rollback authorization binding'
fixed '.windows.session_id==1' 'Windows Session 1 binding'
fixed '.windows.pid|type=="number" and .>=1 and .<=4294967295 and .==floor' 'Windows PID uint32 gate'
fixed '.windows.parent_pid|type=="number" and .>=1 and .<=4294967295 and .==floor' 'Windows parent PID uint32 gate'
fixed '.windows.process_start_filetime_utc|test("^[1-9][0-9]{16,18}$")' 'Windows canonical FILETIME gate'
fixed '.windows.user_sid=="S-1-5-21-1940417919-1835306932-1635351729-1001"' 'Windows SID binding'
fixed '.windows.protocol_2_1==false' 'old snapshot protocol gate'

# systemd identity tuple, argv, journal and authenticated peer probe.
fixed 'systemctl --user show --property' 'user systemd property query'
fixed 'MainPID' 'systemd MainPID binding'
fixed 'InvocationID' 'systemd invocation binding'
fixed 'ControlGroup' 'systemd cgroup binding'
fixed 'Transient' 'transient/persistent unit distinction'
fixed 'process_ticks()' 'proc start-ticks reader'
fixed 'process_cgroup()' 'proc cgroup reader'
fixed 'sha256 "/proc/$pid/exe"' 'proc executable hash binding'
fixed 'expected_cmdline_sha' 'argv/cmdline hash binding'
fixed 'observed_exec_start_json' 'systemd ExecStart argv binding'
fixed 'journalctl --user --quiet --no-pager --output=json' 'user journal query'
fixed '"_SYSTEMD_INVOCATION_ID=$invocation" "_PID=$pid"' 'journal PID/invocation filters'
fixed '"_BOOT_ID=$boot_compact"' 'journal boot filter'
fixed 'journal crossed PID/invocation/boot identity' 'journal identity rejection'
fixed 'protocol-1.3 startup record' 'journal startup record'
fixed 'viewflowd server authenticated peer' 'authenticated peer journal record'
fixed 'viewflowd server peer' 'authenticated probe journal record'
fixed '172\\.16\\.105\\.70' 'authenticated peer address binding'
fixed 'no exact post-auth Windows probe in invocation' 'post-auth probe rejection'
fixed 'validate_receipt_bound_probe()' 'immutable receipt-bound probe journal search'
fixed "auth=re.compile(r'^viewflowd server authenticated peer (" 'receipt probe exact authenticated endpoint regex'
fixed "probe=re.compile(r'^viewflowd server peer (" 'receipt probe exact message regex'
fixed '([1-9][0-9]{0,4})) probe=[0-9]+ responder_us=[0-9]+$' 'receipt probe canonical port/numeric fields'
fixed "if port>65535:raise SystemExit('probe peer port differs')" 'receipt probe port upper bound'
fixed 'if probe_match.group(1) not in authenticated:continue' 'receipt probe post-auth endpoint ordering'
fixed "hashlib.sha256(line.encode('utf-8')).hexdigest()==expected" 'receipt probe exact message hash'
fixed "if matches<1:raise SystemExit('receipt-bound exact post-auth probe disappeared')" 'one-or-more receipt probe occurrence policy'
fixed 'assert_deskflow_zero' 'Deskflow zero boundary'
fixed 'assert_process_census' 'system-wide process census'
fixed 'self_pid=int(override) if override else os.getpid()' 'exact census self PID identity'
fixed "if override and proc_root=='/proc':raise SystemExit('self PID override is forbidden for production census')" 'production census override prohibition'
fixed 'if pid==self_pid:continue' 'single census self PID exclusion'
fixed "comm=stable_read(base+'/comm')" 'stable-open process comm census'
fixed "raw=stable_read(base+'/cmdline')" 'stable-open process cmdline census'
fixed 'candidate=pid==allowed or any(token.search(field) for field in [comm,*argv])' 'candidate classification before exe access'
fixed 'if not candidate:continue' 'benign unreadable-exe skip boundary'
fixed "link=os.readlink(base+'/exe')" 'candidate-only executable read'
fixed 'candidate executable unreadable at PID' 'candidate unreadable-exe rejection'
fixed "if still_same:raise SystemExit(f'candidate executable unreadable at PID {pid}')" 'stable candidate unreadable-exe rejection'
fixed 'sport = :44119' 'UDP listener ownership/zero check'
fixed 'sport = :24800' 'Deskflow TCP zero check'
fixed 'SIDECAR_SOCKET' 'sidecar socket boundary'
fixed 'assert_claims_absent' 'old claim absence gate'
fixed '(.main_pid|type=="number" and .>0 and .==floor)' 'persistent PID scalar gate'
fixed '(.start_ticks|type=="number" and .>0 and .==floor)' 'persistent start-ticks scalar gate'
fixed '(.invocation_id|test("^[0-9a-f]{32}$"))' 'persistent invocation scalar gate'
fixed '.control_group|endswith("/viewflow-peer.service")' 'persistent cgroup binding'
fixed '.expected_exec_start_sha256==$expected' 'persistent ExecStart hash binding'

# Fresh operation/coordinator identity and strict transition plan.
fixed 'uuidgen | tr' 'fresh identity generation'
fixed 'new_operation_id!=$old' 'fresh operation non-reuse'
fixed 'new_coordinator_instance_id!=$old_coord' 'fresh coordinator non-reuse'
fixed 'fresh_operation_root==("/home/wilf/.local/state/viewflow/deployments/"+.new_operation_id)' 'fresh root binding'
fixed 'fresh root collision' 'fresh root collision gate'
fixed 'transition-plan.json' 'immutable transition plan'
fixed 'publish_new "$temp" "$plan"' 'create-once plan publication'

# Ordered retirement/start boundary: old transient first, persistent Viewflow
# second, while Deskflow remains provably inactive.
fixed 'systemctl --user stop "$unit"' 'old transient stop'
fixed 'assert_all_runtime_zero "$unit"' 'post-stop runtime zero proof'
fixed 'old-stopped.json' 'durable old-stop receipt'
fixed 'systemctl --user start "$VIEWFLOW_UNIT"' 'persistent Viewflow start'
fixed 'viewflow-fresh-persistent-v13-start-intent' 'persistent start intent'
fixed 'viewflow-fresh-persistent-v13-authenticated' 'persistent authenticated receipt'
fixed 'unit_file_sha256' 'installed unit hash binding'
fixed 'validate_persistent_start_intent()' 'persistent start-intent exact validator'
fixed '.old_stopped_sha256==$stopped and .viewflowd_sha256==$vf and .unit_file_sha256==$unit' 'persistent intent hash cross-bindings'
fixed 'assert_old_transient_absent()' 'old transient tuple absence validator'
fixed 'old transient unit still has PID/cgroup ownership' 'old transient PID/cgroup zero gate'
fixed 'old transient recorded PID/start tuple still exists' 'old transient recorded tuple absence gate'
fixed 'validate_persistent_live_before_receipt()' 'intent-authorized active recovery validator'
fixed 'intent-authorized persistent service live tuple differs before receipt' 'pre-receipt persistent exact tuple gate'
fixed 'intent-authorized persistent UDP ownership differs before receipt' 'pre-receipt UDP ownership gate'
fixed 'intent-authorized persistent sidecar ownership differs before receipt' 'pre-receipt sidecar ownership gate'
fixed 'persistent receipt tuple became stale before create-once publication' 'pre-publication captured tuple/environment binding'
fixed 'persistent process environment changed across live reattestation' 'receipt live reattestation boundary'
fixed 'old_unit=$(jq -er '\''.linux.viewflow_unit'\'' "$linux_started")' 'pre-receipt old unit derivation'
fixed 'old_pid=$(jq -er '\''.linux.viewflow_main_pid'\'' "$linux_started")' 'pre-receipt old PID derivation'
fixed 'old_ticks=$(jq -er '\''.linux.viewflow_start_ticks'\'' "$linux_started")' 'pre-receipt old start-ticks derivation'
fixed 'active) validate_persistent_live_before_receipt' 'active-before-receipt recovery branch'
fixed "inactive|'') assert_all_runtime_zero \"\$unit\"" 'intent but inactive full-runtime-zero branch'
fixed 'assert_all_runtime_zero "$old_unit"' 'full runtime zero gate before new persistent start'
fixed 'intent-authorized persistent service has stale PID/cgroup before start' 'inactive persistent PID/cgroup zero gate'
fixed 'Deskflow is never started' 'Deskflow prohibition'
[[ $(function_line ensure_old_retired) -lt $(function_line ensure_persistent_started) ]] || fail 'old stop must precede persistent start'

# Exact-hash, sealed prepare/collector execution and crash-resumable marker/B
# evidence.  run_pinned_bash must verify bytes and execute only a sealed FD.
fixed 'run_pinned_bash()' 'sealed pinned-script runner'
fixed "os.memfd_create('viewflow-pinned-bridge-script'" 'pinned runner dedicated sealed FD'
fixed 'ident(before)!=ident(after)' 'pinned source identity stability'
fixed 'hashlib.sha256(data).hexdigest()!=expected): raise SystemExit('\''pinned script identity/hash differs'\'')' 'pinned source hash'
fixed 'fcntl.F_SEAL_WRITE|fcntl.F_SEAL_GROW|fcntl.F_SEAL_SHRINK|fcntl.F_SEAL_SEAL' 'memfd seal set'
fixed 'fcntl.F_ADD_SEALS' 'memfd seal application'
fixed "os.execve('/usr/bin/bash',['/usr/bin/bash',f'/proc/self/fd/{sealed}'" 'sealed FD execution'
fixed 'invoke_prepare_contract()' 'prepare CLI contract function'
fixed 'invoke_prepare_contract' 'prepare contract invocation'
fixed 'run_pinned_bash "$prepare_script" "$prepare_script_sha"' 'prepare sealed execution'
fixed 'invoke_collector_contract()' 'collector CLI contract function'
fixed 'invoke_collector_contract "$intent" "$stage"' 'collector contract invocation'
fixed 'run_pinned_bash "$collector_script" "$collector_script_sha"' 'collector sealed execution'
fixed 'collector_script_sha' 'collector hash input binding'
fixed 'recover_partial_marker_handoff()' 'marker crash recovery'
fixed 'validate_fresh_marker_bytes' 'marker byte recovery validation'
fixed 'validate_fresh_marker_record' 'marker recovery stable-open record validation'
fixed "print(hashlib.sha256(b).hexdigest(),created,before.st_dev,before.st_ino,sep=':')" 'marker hash/timestamp/inode derived from one FD'
fixed 'os.open(path,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW)' 'marker nofollow stable open'
fixed 'ident(before)!=ident(after) or ident(after)!=ident(current)' 'marker fstat/path identity stability'
fixed 'fresh marker stable-open identity differs' 'marker symlink/swap rejection'
fixed 'exact_file '\''partial marker CLI'\'' "$MARKER_CLI" "$marker_candidate_sha" 755' 'marker recovery CLI stable metadata/hash'
fixed 'readonly MARKER_LOCK=$STATE/.deployment-quarantine.v1.lock' 'marker CLI lock path'
fixed 'enter_marker_lock()' 'stable marker lock acquisition'
fixed 'assert_marker_lock_held()' 'marker lock ownership assertion'
fixed '[[ -z $marker_lock_fd ]] || { assert_marker_lock_held; return; }' 'already-locked branch returns normally'
fixed 'exec /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$bridge_source_path"' 'outer marker locker process replacement'
fixed 'fcntl.flock(fd,fcntl.LOCK_EX)' 'exclusive marker lock'
fixed 'os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW' 'marker lock nofollow open'
fixed 'marker lock stable identity/mode differs' 'owner-only marker lock metadata'
fixed 'viewflow-marker-locked-bridge' 'sealed locked bridge re-exec'
fixed 'bridge source hash changed across locked re-exec' 'locked bridge source pinning'
fixed 'VIEWFLOW_BRIDGE_SOURCE_SHA256' 'locked bridge source hash carry-forward'
fixed 'release_marker_lock' 'prepare lock release to avoid CLI deadlock'
fixed 'enter_marker_lock' 'post-prepare locked recovery'
fixed "die 'locked marker re-exec unexpectedly returned'" 'unreachable post-reexec sentinel'
fixed 'fresh marker inode/hash changed across publish/handoff validation' 'marker cross-validation stability'
fixed 'fresh marker inode/hash changed across final validation' 'marker final stability'
fixed 'fresh marker inode/hash changed before final publication' 'marker pre-publication stability'
fixed 'fresh marker inode/hash changed across create-once final publication' 'marker post-publication stability'
fixed 'marker-publish-intent.json' 'marker publish intent'
fixed 'validate_collector_intent()' 'collector crash recovery intent'
fixed 'viewflow-fresh-v13-collector-intent' 'collector intent schema'
fixed 'validate_frozen()' 'collector frozen evidence validation'
fixed 'viewflow-v13-bootstrap-frozen' 'frozen evidence state'
fixed '.schema_version==1 and .state=="viewflow-v13-bootstrap-frozen"' 'frozen evidence state predicate'
fixed '/proc/sys/kernel/random/boot_id' 'current boot binding'
fixed 'frozen evidence is from another boot' 'frozen current-boot rejection'
fixed '== "$boot" && ! -e /proc/$pid' 'collector current-boot equality'
fixed '.daemon.pid==$intent[0].daemon_pid' 'frozen collector PID binding'
fixed 'journal.query_systemd_invocation_id==.daemon.systemd_invocation_id' 'frozen journal invocation binding'
fixed 'observe_persistent_stably_stopped()' 'stable persistent stop observation'
fixed 'systemctl --user stop "$VIEWFLOW_UNIT"' 'collector recovery explicit persistent stop'
fixed '$state == inactive && $sub == dead && $main == 0 && $result == success' 'inactive/dead/result gate'
fixed '$restarts =~ ^[0-9]+$ && $restart_policy == on-failure' 'restart counter/policy gate'
fixed 'stable>=5' 'multi-observation stable-stop gate'
fixed 'observe_persistent_stably_stopped' 'frozen/final stable-stop reattestation'
fixed 'FragmentPath' 'effective unit FragmentPath binding'
fixed 'DropInPaths' 'effective unit drop-in binding'
fixed 'Environment' 'effective unit environment binding'
fixed 'RestartUSec) == 1s' 'effective unit RestartSec binding'
fixed 'ExecStartPre' 'empty ExecStartPre binding'
fixed 'ExecStartPost' 'empty ExecStartPost binding'
fixed 'assert_cgroup_only_main' 'full cgroup PID-set gate'
fixed '[[ $procs == "$pid " ]]' 'exact cgroup PID-set equality'
fixed 'assert_persistent_unit_contract; assert_cgroup_only_main "$cgroup" "$pid"' 'live cgroup PID-set invocation'
fixed 'persistent cgroup contains an unexpected helper PID' 'helper PID rejection'
fixed '-z $cgroup' 'stopped cgroup emptiness gate'
fixed 'process_environment_sha()' 'persistent proc environment validator'
fixed 'proc_root=${4:-/proc}' 'persistent proc environment source'
fixed "'LD_PRELOAD','LD_AUDIT','LD_LIBRARY_PATH','PYTHONPATH','PYTHONHOME','BASH_ENV','ENV'" 'dangerous daemon environment rejection'
fixed 'process environment contains an unapproved name' 'daemon environment allowlist'
fixed "desktop_input_exact={'GTK_IM_MODULE':b'fcitx','QT_IM_MODULE':b'fcitx','XMODIFIERS':b'@im=fcitx'}" 'exact desktop input-method environment contract'
fixed "'RUNTIME_DIRECTORY':b'/run/user/1000/viewflow'" 'exact systemd runtime directory environment'
fixed "re.fullmatch(rb'[1-9][0-9]{0,18}',manager_pidfd_id)" 'canonical MANAGERPIDFDID environment'
fixed 'int(manager_pidfd_id)>2**63-1' 'bounded MANAGERPIDFDID environment'
fixed "approved_path=(b'/usr/lib/jvm/java-21-openjdk/bin:/home/wilf/.nix-profile/bin:/nix/var/nix/profiles/default/bin:'" 'exact host process PATH prefix'
fixed "b'/home/wilf/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/cuda/bin:/usr/lib/emscripten:'" 'exact host process PATH middle'
fixed "b'/usr/lib/jvm/default/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl:/usr/lib/rustup/bin:'" 'exact host process PATH suffix'
fixed "b'/home/wilf/.local/bin')" 'exact host process PATH final component'
fixed "if environment.get('PATH')!=approved_path:" 'exact process PATH equality'
fixed 'environment_sha256' 'daemon environment receipt binding'
fixed '(.environment_sha256|test("^[0-9a-f]{64}$"))' 'daemon environment receipt exact hash predicate'
fixed 'persistent process environment changed across live reattestation' 'daemon environment double reattestation'

# Marker publication is create-once and fsyncs both file and directory.
fixed 'libc=ctypes.CDLL(None,use_errno=True); fn=libc.renameat2' 'renameat2 publication'
fixed 'if fn(pfd,os.fsencode(os.path.basename(source)),pfd,os.fsencode(leaf),1)!=0' 'RENAME_NOREPLACE publication'
fixed 'os.O_NOFOLLOW' 'nofollow input/output opens'
fixed 'os.fsync(sfd)' 'source fsync'
fixed 'os.fsync(pfd)' 'parent-directory fsync'
fixed 'published identity differs' 'published inode identity'
fixed 'deployment-quarantine-published' 'fresh publish output'
fixed 'viewflow-v13-marker-handoff-prepared' 'fresh handoff output'
fixed 'early-abort-terminal-to-fresh-v21.json' 'final boundary output'
fixed 'final_receipt=$fresh_root/early-abort-terminal-to-fresh-v21.json' 'final receipt path binding'
fixed 'publish_final()' 'final receipt publication'
fixed 'keys==["fresh_boundary","marker_generation","new_coordinator_instance_id","new_operation_id","old_operation_id","old_terminal","persistent_v13","retirement","schema_version","state"]' 'final exact keys'
fixed '.retirement=={old_stopped_sha256:$stopped,viewflow_process_count:0,deskflow_process_count:0' 'final retirement cross-binding'
fixed '.persistent_v13=={persistent_started_sha256:$persistent,authenticated_probe_record_sha256:$probe,stopped_by_collector:true}' 'final persistent cross-binding'
fixed '.fresh_boundary=={deployment_publish_sha256:$publish,marker_handoff_sha256:$handoff,linux_frozen_sha256:$frozen' 'final boundary cross-binding'
for output in publish_receipt handoff_receipt frozen_evidence final_receipt; do
    fixed "$output" "final output variable: $output"
done

# No remote or live Windows operation may be hidden in this Linux-only bridge.
if awk '!/^[[:space:]]*#/ && tolower($0) ~ /(^|[^[:alnum:]_])(ssh|scp|sftp|winrs|powershell|invoke-command|get-scheduled-task|enter-pssession)([^[:alnum:]_]|$)/ {bad=1} END{exit !bad}' "$SOURCE"; then
    fail 'bridge contains remote/Windows command'
fi
if awk '!/^[[:space:]]*#/ && $0 ~ /systemctl[[:space:]]+--user[[:space:]]+(restart|enable|disable|daemon-reexec)/ {bad=1} END{exit !bad}' "$SOURCE"; then
    fail 'bridge contains unapproved live systemd mutation'
fi

/usr/bin/python3 -I - "$SOURCE" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
def body(name):
 match=re.search(r'^'+re.escape(name)+r'\(\) \{\n(?P<body>.*?)(?=^\}\n)',s,re.M|re.S)
 if not match: raise SystemExit('missing function body: '+name)
 return re.sub(r'\\\n\s*',' ',match.group('body'))
prepare=' '.join(body('invoke_prepare_contract').split())
expected_prepare=' '.join('''run_pinned_bash "$prepare_script" "$prepare_script_sha" --deployment-marker-candidate "$marker_candidate" --deployment-marker-sha256 "$marker_candidate_sha" --operation-id "$new_operation" --source-display-id "$SOURCE_UUID" --target-device-id "$TARGET_UUID" --coordinator-instance-id "$new_coordinator" --marker-generation 1 --deployment-publish-receipt "$publish_receipt" --bootstrap-handoff-receipt "$handoff_receipt"'''.split())
if prepare!=expected_prepare: raise SystemExit('prepare CLI argv contract differs')
collector=' '.join(body('invoke_collector_contract').split())
expected_collector=' '.join('''local intent=$1 stage=$2 run_pinned_bash "$collector_script" "$collector_script_sha" --daemon-pid "$(jq -er '.daemon_pid' "$intent")" --daemon-sha256 "$installed_viewflow_sha" --operation-id "$new_operation" --evidence-output "$stage"'''.split())
if collector!=expected_collector: raise SystemExit('collector CLI argv contract differs')
census=body('assert_process_census')
ordered=['if pid==self_pid:continue',"comm=stable_read(base+'/comm')","raw=stable_read(base+'/cmdline')",'candidate=pid==allowed','if not candidate:continue',"link=os.readlink(base+'/exe')"]
positions=[census.find(token) for token in ordered]
if any(position<0 for position in positions) or positions!=sorted(positions):
 raise SystemExit('process census must classify stable comm/cmdline before candidate-only exe read')
if 'os.getppid' in census or 'PPid' in census:
 raise SystemExit('process census must not exempt parent or ancestor processes')
intent=body('validate_persistent_start_intent')
for token in ('.operation_id==$op','.old_stopped_sha256==$stopped','.viewflowd_sha256==$vf','.unit_file_sha256==$unit'):
 if token not in intent:raise SystemExit('persistent start intent lacks exact binding: '+token)
old=body('ensure_old_retired')
ordered=['old stopped receipt binding differs','assert_old_transient_absent "$unit" "$pid" "$ticks"','validate_persistent_start_intent','active) validate_persistent_live_before_receipt']
positions=[old.find(token) for token in ordered]
if any(position<0 for position in positions) or positions!=sorted(positions):
 raise SystemExit('old-stopped recovery must exclude the old tuple before validating intent-authorized active persistent state')
if 'else\n            assert_all_runtime_zero "$unit"' not in old or 'inactive|\'\') assert_all_runtime_zero "$unit"' not in old:
 raise SystemExit('old-stopped recovery must require total Viewflow zero without active intent-authorized persistent state')
live=body('validate_persistent_live_before_receipt')
for token in ('validate_persistent_start_intent','validate_installed_persistent','$(exact_executable_pids "$VIEWFLOW") == "$pid"',
              'assert_persistent_unit_contract','assert_cgroup_only_main "$cgroup" "$pid"','process_environment_sha "$pid" "$ticks" "$invocation"',
              'intent-authorized persistent UDP ownership differs before receipt','intent-authorized persistent sidecar ownership differs before receipt',
              'assert_deskflow_zero "$pid"','assert_claims_absent',"old_unit=$(jq -er '.linux.viewflow_unit' \"$linux_started\")",
              "old_pid=$(jq -er '.linux.viewflow_main_pid' \"$linux_started\")","old_ticks=$(jq -er '.linux.viewflow_start_ticks' \"$linux_started\")",
              'assert_old_transient_absent "$old_unit" "$old_pid" "$old_ticks"'):
 if token not in live:raise SystemExit('pre-receipt persistent recovery lacks exact live gate: '+token)
if 'persistent-started.json' in live or 'validate_persistent_receipt' in live:
 raise SystemExit('pre-receipt persistent recovery must not depend on a persistent-started receipt')
old_final=live.rfind('assert_old_transient_absent "$old_unit" "$old_pid" "$old_ticks"')
if old_final<live.find('assert_claims_absent') or live[old_final+len('assert_old_transient_absent "$old_unit" "$old_pid" "$old_ticks"'):].strip():
 raise SystemExit('old transient absence must be the final pre-receipt live observation')
start=body('ensure_persistent_started')
for token in ('validate_persistent_start_intent','active)\n            validate_persistent_live_before_receipt','assert_all_runtime_zero "$old_unit"',
              'systemctl --user start "$VIEWFLOW_UNIT"','fresh persistent invocation lacks exact authenticated probe','validate_persistent_live_before_receipt'):
 if token not in start:raise SystemExit('persistent start/resume ordering lacks gate: '+token)
if start.find('validate_persistent_start_intent')>start.find('systemctl --user start "$VIEWFLOW_UNIT"'):
 raise SystemExit('persistent start intent must be validated before service start')
if start.rfind('validate_persistent_live_before_receipt')<start.find('fresh persistent invocation lacks exact authenticated probe'):
 raise SystemExit('persistent tuple must be revalidated after the authenticated probe and before receipt publication')
final_gate='validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"'
publish='publish_new "$temp" "$receipt"'
gate_at=start.find(final_gate);publish_at=start.find(publish)
if gate_at<0 or publish_at<gate_at or start[gate_at+len(final_gate):publish_at].strip():
 raise SystemExit('captured persistent tuple and old-unit absence must be revalidated immediately before create-once receipt publication')
for token in ('$pid == "$expected_pid"','$ticks == "$expected_ticks"','$invocation == "$expected_invocation"',
              '$cgroup == "$expected_cgroup"','$environment_sha == "$expected_environment_sha"'):
 if token not in live:raise SystemExit('final persistent receipt validation lacks captured tuple binding: '+token)
receipt=body('validate_persistent_receipt')
receipt_final='validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"'
if receipt.rfind(receipt_final)<receipt.find('persistent process environment changed across live reattestation') or not receipt.rstrip().endswith(receipt_final):
 raise SystemExit('existing persistent receipt must finish with exact tuple and old-transient absence revalidation')
receipt_probe=body('validate_receipt_bound_probe')
ordered=["auth_match=auth.fullmatch(line)",'authenticated.add(auth_match.group(1))',"probe_match=probe.fullmatch(line)",
         'if probe_match.group(1) not in authenticated:continue',"hashlib.sha256(line.encode('utf-8')).hexdigest()==expected",'if matches<1:']
positions=[receipt_probe.find(token) for token in ordered]
if any(position<0 for position in positions) or positions!=sorted(positions):
 raise SystemExit('receipt-bound probe must hash only exact endpoint-matched probes occurring after authentication')
receipt_order=['capture_journal "$pid" "$invocation" "$temp" >/dev/null',
               "probe_sha=$(jq -er '.authenticated_probe_record_sha256' \"$receipt\")",
               'validate_receipt_bound_probe "$temp" "$probe_sha" >/dev/null',receipt_final]
positions=[receipt.find(token) for token in receipt_order]
if any(position<0 for position in positions) or positions!=sorted(positions):
 raise SystemExit('existing receipt must search the captured journal for its exact bound probe before final tuple revalidation')
marker_lock=body('enter_marker_lock')
locked_return='[[ -z $marker_lock_fd ]] || { assert_marker_lock_held; return; }'
outer_exec='exec /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$bridge_source_path"'
if marker_lock.count(outer_exec)!=1 or marker_lock.find(locked_return)<0 or marker_lock.find(locked_return)>marker_lock.find(outer_exec):
 raise SystemExit('already-locked marker branch must return before the single outer exec-replacement locker chain')
if '\n    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$bridge_source_path"' in marker_lock:
 raise SystemExit('outer marker locker must never be invoked as a returning child process')
PY

printf 'early-abort terminal to fresh-v2.1 bridge static checker passed\n'
