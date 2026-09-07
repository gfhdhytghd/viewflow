#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2155
# Verify that one-point weakening of each early-abort bridge contract is
# rejected by the source checker.  No bridge invocation, SSH, or live action
# occurs in this test.
set -Eeuo pipefail

readonly HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly LINUX=$(cd -- "$HERE/.." && pwd)
readonly SOURCE=$LINUX/bridge-early-abort-terminal-to-fresh-v21.sh
readonly CHECKER=$LINUX/check-bridge-early-abort-terminal-to-fresh-v21.sh
temporary=()
cleanup() { local path; for path in "${temporary[@]}"; do rm -f -- "$path"; done; }
trap cleanup EXIT

bash "$CHECKER" "$SOURCE" >/dev/null

reject() {
    local label=$1 from=$2 to=$3 candidate
    candidate=$(mktemp --tmpdir 'viewflow-early-bridge-negative.XXXXXX')
    temporary+=("$candidate")
    python3 - "$SOURCE" "$candidate" "$from" "$to" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
old=sys.argv[3]; new=sys.argv[4]
text=source.read_text()
if text.count(old)!=1:
    raise SystemExit(f'mutation anchor is not exact-once: {old!r}')
out.write_text(text.replace(old,new,1))
PY
    if bash "$CHECKER" "$candidate" >/dev/null 2>&1; then
        printf 'error: checker accepted mutation: %s\n' "$label" >&2
        exit 1
    fi
}

reject_in_function() {
    local label=$1 function_name=$2 from=$3 to=$4 candidate
    candidate=$(mktemp --tmpdir 'viewflow-early-bridge-negative.XXXXXX')
    temporary+=("$candidate")
    python3 - "$SOURCE" "$candidate" "$function_name" "$from" "$to" <<'PY'
import pathlib,re,sys
source=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);name=sys.argv[3];old=sys.argv[4];new=sys.argv[5]
text=source.read_text();match=re.search(r'^'+re.escape(name)+r'\(\) \{\n.*?^\}\n',text,re.M|re.S)
if not match:raise SystemExit('function mutation target is absent: '+name)
body=match.group(0)
if body.count(old)!=1:raise SystemExit(f'function mutation anchor is not exact-once: {name}: {old!r}')
out.write_text(text[:match.start()]+body.replace(old,new,1)+text[match.end():])
PY
    if bash "$CHECKER" "$candidate" >/dev/null 2>&1; then
        printf 'error: checker accepted function mutation: %s\n' "$label" >&2
        exit 1
    fi
}

# Input schemas and content-addressed VFDQA.
reject terminal-schema \
    'schema_version==1 and .state=="viewflow-early-bootstrap-gate-abort-terminal"' \
    'schema_version>=1 and .state=="viewflow-early-bootstrap-gate-abort-terminal"'
reject authorization-schema \
    'schema_version==3 and .state=="viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized"' \
    'schema_version>=3 and .state=="viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized"'
reject vfdqa-magic 'b[:8]!=b'"'"'VFDQA001'"'"'' 'b[:8]!=b'"'"'VFDQX001'"'"''
reject vfdqa-protocol 'bytes((1,1,1,3,1))' 'bytes((1,1,2,1,1))'
reject vfdqa-marker-hash 'hashlib.sha256(m).hexdigest()!=marker_sha' 'hashlib.sha256(m).hexdigest()==marker_sha'
reject vfdqa-operation 'm[16:16+len(raw)]!=raw' 'm[16:16+len(raw)]==raw'
reject vfdqa-coordinator 'm[176:192]!=uuid.UUID(coord).bytes' 'm[176:192]!=uuid.UUID(op).bytes'
reject vfdqa-auth-hash 'b[304:336].hex()!=auth_sha' 'b[304:336].hex()==auth_sha'
reject vfdqa-checksum 'hashlib.sha256(b[:352]).digest()!=b[352:384]' 'hashlib.sha256(b[:352]).digest()==b[352:384]'
reject vfdqa-snapshot-size 'exact_file '\''durable VFDQA snapshot/source'\'' "$vfdqa" "$vfdqa_sha" "$data_mode" 384' 'exact_file '\''durable VFDQA snapshot/source'\'' "$vfdqa" "$vfdqa_sha" "$data_mode"'
reject vfdqa-original-mode 'exact_file '\''content-addressed durable VFDQA original'\'' "$vfdqa_claim_path" "$vfdqa_sha" 600 384' 'exact_file '\''content-addressed durable VFDQA original'\'' "$vfdqa_claim_path" "$vfdqa_sha" 400 384'
reject cross-binding 'jq -cS --arg key "$key" '\''.[$key]'\'' "$abort_receipt"' 'jq -c --arg key "$key" '\''.[$key]'\'' "$abort_receipt"'
reject windows-request-binding '.windows.request_sha256==$request' '(.windows.request_sha256|test("^[0-9a-f]{64}$"))'
reject windows-filetime '.windows.process_start_filetime_utc|test("^[1-9][0-9]{16,18}$")' '(.windows.process_start_filetime_utc|type=="string")'
reject strict-json-float 'parse_float=reject_float' 'parse_float=float'
reject strict-python-int 'type(value) is not int' 'not isinstance(value,(int,float))'

# Stable systemd/process/journal/probe tuple.
reject tuple-cross-binding '.linux==$started[0].linux and .windows==$started[0].windows' '.linux==$started[0].linux'
reject pid-type '(.main_pid|type=="number" and .>0 and .==floor)' '(.main_pid|type=="number")'
reject ticks-type '(.start_ticks|type=="number" and .>0 and .==floor)' '(.start_ticks|type=="number")'
reject invocation-type '(.invocation_id|test("^[0-9a-f]{32}$"))' '(.invocation_id|type=="string")'
reject cgroup-binding '.control_group|endswith("/viewflow-peer.service")' '.control_group|type=="string"'
reject execstart-hash '.expected_exec_start_sha256==$expected' '.expected_exec_start_sha256|type=="string"'
reject journal-identity 'journal crossed PID/invocation/boot identity' 'journal identity unchecked'
reject auth-probe 'no exact post-auth Windows probe in invocation' 'authenticated probe unchecked'
reject receipt-probe-post-auth 'if probe_match.group(1) not in authenticated:continue' 'if False:continue'
reject receipt-probe-message-hash "hashlib.sha256(line.encode('utf-8')).hexdigest()==expected" "hashlib.sha256(str(item).encode('utf-8')).hexdigest()==expected"
reject receipt-probe-occurrence-policy "if matches<1:raise SystemExit('receipt-bound exact post-auth probe disappeared')" "if matches<0:raise SystemExit('receipt-bound exact post-auth probe disappeared')"
reject_in_function receipt-probe-recovery-call validate_persistent_receipt \
    'validate_receipt_bound_probe "$temp" "$probe_sha" >/dev/null' \
    ': # receipt-bound probe search removed'
reject census-stable-comm "comm=stable_read(base+'/comm')" "comm=open(base+'/comm','rb').read()"
reject census-self-skip 'if pid==self_pid:continue' 'if False:continue'
reject census-production-override "if override and proc_root=='/proc':raise SystemExit('self PID override is forbidden for production census')" 'if False:raise SystemExit('\''override allowed'\'')'
reject census-benign-skip 'if not candidate:continue' 'if not candidate:pass'
reject census-candidate-unreadable "if still_same:raise SystemExit(f'candidate executable unreadable at PID {pid}')" 'if still_same:continue'

# Explicit user bus, fresh IDs, and old-stop-before-persistent-start.
reject explicit-bus 'readonly DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus' 'readonly DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/other'
reject operation-reuse 'new_operation_id!=$old' '(.new_operation_id|length)==32'
reject coordinator-reuse 'new_coordinator_instance_id!=$old_coord' '(.new_coordinator_instance_id|length)==36'
reject old-stop 'systemctl --user stop "$unit"' 'systemctl --user stop "$VIEWFLOW_UNIT"'
reject persistent-start 'systemctl --user start "$VIEWFLOW_UNIT"' 'systemctl --user start "$unit"'
reject persistent-intent-binding '.old_stopped_sha256==$stopped and .viewflowd_sha256==$vf and .unit_file_sha256==$unit' '.viewflowd_sha256==$vf and .unit_file_sha256==$unit'
reject old-tuple-absence 'assert_old_transient_absent "$unit" "$pid" "$ticks"' ': # old tuple absence unchecked'
reject active-before-receipt-recovery 'active) validate_persistent_live_before_receipt ;;' 'active) : ;;'
reject inactive-intent-runtime-zero "inactive|'') assert_all_runtime_zero \"\$unit\" ;;" "inactive|'') : ;;"
reject pre-receipt-extra-viewflow '$(exact_executable_pids "$VIEWFLOW") == "$pid" ]] || die '\''intent-authorized persistent service live tuple differs before receipt'\''' '-n $(exact_executable_pids "$VIEWFLOW") ]] || die '\''intent-authorized persistent service live tuple differs before receipt'\'''
reject post-probe-old-resurrection 'assert_old_transient_absent "$old_unit" "$old_pid" "$old_ticks"' ': # final old transient recheck removed'
reject stale-receipt-environment-binding '$environment_sha == "$expected_environment_sha"' 'true'
reject final-pre-receipt-call-order $'validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"\n    publish_new "$temp" "$receipt"' $'publish_new "$temp" "$receipt"\n    validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"'
reject_in_function existing-receipt-final-tuple validate_persistent_receipt \
    'validate_persistent_live_before_receipt "$pid" "$ticks" "$invocation" "$cgroup" "$environment_sha"' \
    ': # existing receipt final tuple unchecked'
reject pre-start-runtime-zero 'assert_all_runtime_zero "$old_unit"' 'assert_deskflow_zero 0'
reject immutable-snapshot-order 'ensure_roots; snapshot_inputs; validate_inputs; make_plan' 'ensure_roots; snapshot_inputs; make_plan'
reject snapshot-nofollow 'snapshot source identity/hash differs' 'snapshot source hash only'
reject snapshot-exact-mode 'os.fchmod(fd,mode)' 'os.fchmod(fd,mode & 0o700)'
reject snapshot-reopen 'published snapshot identity/hash/mode differs' 'snapshot publication unchecked'

# Exact-hash sealed scripts and crash-resumable marker/collector evidence.
reject pinned-hash 'hashlib.sha256(data).hexdigest()!=expected): raise SystemExit('\''pinned script identity/hash differs'\'')' 'hashlib.sha256(data).hexdigest()==expected): raise SystemExit('\''pinned script identity/hash differs'\'')'
reject pinned-seals "os.memfd_create('viewflow-pinned-bridge-script'" "os.memfd_create('viewflow-unsealed-script'"
reject pinned-exec 'run_pinned_bash() {' 'run_unpinned_bash() {'
reject marker-recovery 'recover_partial_marker_handoff()' 'marker_handoff_without_recovery()'
reject marker-bytes "print(hashlib.sha256(b).hexdigest(),created,before.st_dev,before.st_ino,sep=':')" "print(hashlib.sha256(open(path,'rb').read()).hexdigest(),created,before.st_dev,before.st_ino,sep=':')"
reject marker-nofollow 'fresh marker stable-open identity differs' 'fresh marker path accepted'
reject marker-lock 'fcntl.flock(fd,fcntl.LOCK_EX)' 'fcntl.flock(fd,fcntl.LOCK_SH)'
reject marker-locker-outer-exec 'exec /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$bridge_source_path"' '/usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/python3 -I - "$bridge_source_path"'
reject marker-locker-inner-return '[[ -z $marker_lock_fd ]] || { assert_marker_lock_held; return; }' '[[ -z $marker_lock_fd ]] || { assert_marker_lock_held; :; }'
reject marker-reexec-source-pin 'bridge source hash changed across locked re-exec' 'bridge source was not pinned across re-exec'
reject marker-cli-stable 'exact_file '\''partial marker CLI'\'' "$MARKER_CLI" "$marker_candidate_sha" 755' 'sha256 "$MARKER_CLI" >/dev/null'
reject collector-recovery 'validate_collector_intent()' 'collector_intent_without_recovery()'
reject collector-exec 'run_pinned_bash "$collector_script" "$collector_script_sha"' 'collector_unsealed_exec "$collector_script"'
reject frozen-evidence '.state=="viewflow-v13-bootstrap-frozen"' '.state=="viewflow-v13-bootstrap-unfrozen"'
reject current-boot '== "$boot" && ! -e /proc/$pid' '== "$boot" && true #'
reject stable-stop '$state == inactive && $sub == dead && $main == 0 && $result == success' '$main == 0'
reject restart-policy '$restarts =~ ^[0-9]+$ && $restart_policy == on-failure' '$restarts =~ ^[0-9]+$'
reject effective-restart-sec 'RestartUSec) == 1s' 'RestartUSec) != 0'
reject cgroup-helper '[[ $procs == "$pid " ]]' '[[ $procs == *"$pid "* ]]'
reject process-environment-forbidden "'LD_PRELOAD','LD_AUDIT','LD_LIBRARY_PATH','PYTHONPATH','PYTHONHOME','BASH_ENV','ENV'" "'LD_PRELOAD','LD_AUDIT'"
reject process-environment-input-method "desktop_input_exact={'GTK_IM_MODULE':b'fcitx','QT_IM_MODULE':b'fcitx','XMODIFIERS':b'@im=fcitx'}" "desktop_input_exact={'GTK_IM_MODULE':environment.get('GTK_IM_MODULE'),'QT_IM_MODULE':b'fcitx','XMODIFIERS':b'@im=fcitx'}"
reject process-environment-runtime-directory "'RUNTIME_DIRECTORY':b'/run/user/1000/viewflow'" "'RUNTIME_DIRECTORY':environment.get('RUNTIME_DIRECTORY')"
reject process-environment-managerpidfdid "re.fullmatch(rb'[1-9][0-9]{0,18}',manager_pidfd_id)" "re.fullmatch(rb'[0-9]+',manager_pidfd_id)"
reject process-environment-path "if environment.get('PATH')!=approved_path:" "if not environment.get('PATH',b'').startswith(approved_path):"
reject process-environment-receipt '(.environment_sha256|test("^[0-9a-f]{64}$"))' '(.environment_sha256|type=="string")'
reject prepare-cli '--bootstrap-handoff-receipt "$handoff_receipt"' '--bootstrap-handoff-output "$handoff_receipt"'
reject collector-cli '--evidence-output "$stage"' '--output "$stage"'

# No-replace publication and all four terminal outputs.
reject no-replace 'fn(pfd,os.fsencode(os.path.basename(source)),pfd,os.fsencode(leaf),1)!=0' 'fn(pfd,os.fsencode(os.path.basename(source)),pfd,os.fsencode(leaf),0)!=0'
reject renameat2 'libc=ctypes.CDLL(None,use_errno=True); fn=libc.renameat2' 'libc=ctypes.CDLL(None,use_errno=True); fn=libc.rename'
reject source-fsync 'os.fsync(sfd)' 'os.fdatasync(sfd)'
reject final-output 'final_receipt=$fresh_root/early-abort-terminal-to-fresh-v21.json' 'final_result=$fresh_root/early-abort-terminal-to-fresh-v21.json'
reject final-schema 'keys==["fresh_boundary","marker_generation","new_coordinator_instance_id","new_operation_id","old_operation_id","old_terminal","persistent_v13","retirement","schema_version","state"]' 'keys==["fresh_boundary"]'

# Remote/live commands are prohibited even if added as a single source line.
reject no-ssh 'readonly PATH=/usr/bin:/bin' 'readonly PATH=/usr/bin:/bin; ssh 127.0.0.1 true'

printf 'early-abort terminal to fresh-v2.1 static-negative mutations passed\n'
