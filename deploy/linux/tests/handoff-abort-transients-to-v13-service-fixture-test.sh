#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317

set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly LINUX_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
readonly HANDOFF=$LINUX_DIR/handoff-abort-transients-to-v13-service.sh
readonly CHECKER=$LINUX_DIR/check-handoff-abort-transients-to-v13-service.sh
fixture_root=$(mktemp -d)
fixture_processes=()
cleanup_fixture() {
    local fixture_pid
    for fixture_pid in "${fixture_processes[@]}"; do kill "$fixture_pid" 2>/dev/null || true; done
    for fixture_pid in "${fixture_processes[@]}"; do wait "$fixture_pid" 2>/dev/null || true; done
    rm -rf -- "$fixture_root"
}
trap cleanup_fixture EXIT

fail() { printf 'handoff isolated fixture failed: %s\n' "$*" >&2; exit 1; }

extract_function() {
    local name=$1
    awk -v start="${name}() {" '
        $0 == start {inside=1}
        inside {print}
        inside && /^}$/ {exit}
    ' "$HANDOFF"
}

expect_checker_rejected() {
    local name=$1 from=$2 to=$3 mutant
    mutant=$fixture_root/$name.sh
    awk -v from="$from" -v to="$to" '
        {
            line=$0; result=""
            while ((p=index(line,from)) != 0) {
                result=result substr(line,1,p-1) to
                line=substr(line,p+length(from)); done=1
            }
            print result line
        }
        END {if (!done) exit 42}
    ' "$HANDOFF" >"$mutant" || fail "mutation target absent: $name"
    cmp -s "$HANDOFF" "$mutant" && fail "mutation was a no-op: $name"
    if "$CHECKER" "$mutant" >/dev/null 2>&1; then
        fail "checker accepted unsafe mutation: $name"
    fi
}

"$CHECKER" "$HANDOFF" >/dev/null
expect_checker_rejected stop-order 'systemctl --user stop "$deskflow_unit"' \
    'systemctl --user stop "$viewflow_unit"'
expect_checker_rejected start-deskflow 'systemctl --user start "$VIEWFLOW_UNIT"' \
    'systemctl --user start "$DESKFLOW_UNIT"'
expect_checker_rejected no-clobber 'atomic_publish_noreplace "$receipt_temp" "$handoff_receipt"' \
    'mv -f -- "$receipt_temp" "$handoff_receipt"'
expect_checker_rejected intent-no-clobber 'atomic_publish_noreplace "$intent_temp" "$transition_intent"' \
    'mv -f -- "$intent_temp" "$transition_intent"'
expect_checker_rejected rename-flags 'RENAME_NOREPLACE = 1' 'RENAME_NOREPLACE = 0'
expect_checker_rejected parent-fsync 'os.fsync(directory_fd)' ': # parent fsync bypassed'
expect_checker_rejected final-reattest 'final_reattest_against_receipt "$receipt_temp"' \
    ': # final reattestation bypassed'
expect_checker_rejected missing-probe '172\\.16\\.105\\.70:[1-9]' '172\\.16\\.105\\.71:[1-9]'
expect_checker_rejected receipt-schema 'journal_slice_sha256' 'journal_slice_digest'
expect_checker_rejected cleanup-ownership 'persistent_started == 1 && receipt_published == 0' \
    'persistent_started == 0 && receipt_published == 1'
expect_checker_rejected cleanup-identity-gate 'if persistent_cleanup_identity_matches; then' 'if true; then'
expect_checker_rejected cleanup-invocation-compare \
    '== "$persistent_owned_invocation"' '== "$(unit_property "$VIEWFLOW_UNIT" InvocationID)"'
expect_checker_rejected cleanup-capture-call \
    'capture_persistent_cleanup_identity "$pid" "$ticks" "$invocation" "$cgroup"' \
    ': # cleanup identity capture bypassed'
expect_checker_rejected cleanup-identity-default \
    "persistent_owned_pid='' persistent_owned_ticks='' persistent_owned_invocation='' persistent_owned_cgroup=''" \
    "persistent_owned_pid=1 persistent_owned_ticks=1 persistent_owned_invocation=x persistent_owned_cgroup=/"
expect_checker_rejected deleted-runtime-link '"$runtime_path (deleted)"' '"$runtime_path"'
expect_checker_rejected loader-environment 'LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV ENV' \
    'LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH BASH_ENV'
expect_checker_rejected journal-order '$journal_end_us >= $journal_start_us' \
    '. >= .persistent_viewflow.journal_start_realtime_timestamp_us'
expect_checker_rejected adoption-default \
    "intent_initial_state='' preintent_partial_adopted=0 adopt_preintent_partial=0" \
    "intent_initial_state='' preintent_partial_adopted=0 adopt_preintent_partial=1"
expect_checker_rejected recovery-terminal-hash \
    'f5d5446e51b0d6138352da7c323102baf283df9e63cf7574ab12246708508af3' \
    'e5d5446e51b0d6138352da7c323102baf283df9e63cf7574ab12246708508af3'
expect_checker_rejected recovery-query-hash \
    '4f8a7cb2f0f0c4f01397a4eb4b9f0c1350f52607fb07acec763c19593da519a8' \
    '5f8a7cb2f0f0c4f01397a4eb4b9f0c1350f52607fb07acec763c19593da519a8'
expect_checker_rejected schema5-receipt-hash \
    '6cd825cd6003053b3677acc0235933f34e179aba3723a77b14aeada9d1ec3766' \
    '7cd825cd6003053b3677acc0235933f34e179aba3723a77b14aeada9d1ec3766'
expect_checker_rejected durable-vfdqa-hash \
    'c5a4b7b0900f8907087c65724f630b474facd894d4bf23749b562ea7af967b19' \
    'd5a4b7b0900f8907087c65724f630b474facd894d4bf23749b562ea7af967b19'
expect_checker_rejected retired-claim-hash \
    'a336070106802153c9834154ab493b22a19eeb434ebed1e77000e44aa9ba5000' \
    'b336070106802153c9834154ab493b22a19eeb434ebed1e77000e44aa9ba5000'
expect_checker_rejected absence-symlink '[[ ! -e $path && ! -L $path ]]' '[[ ! -e $path ]]'
expect_checker_rejected sidecar-absence '! -e $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR' 'true'
expect_checker_rejected partial-sidecar-owner 'validate_live_viewflow_transient_sidecar' ': # sidecar owner bypassed'
expect_checker_rejected partial-forbids-sidecar 'assert_no_deskflow_process_runtime' 'assert_no_deskflow_runtime'
expect_checker_rejected sidecar-socket-type '-S $VIEWFLOW_SIDECAR' '-e $VIEWFLOW_SIDECAR'
expect_checker_rejected sidecar-exclusive-pid 'ss_pid_count == 1' 'ss_pid_count >= 1'
expect_checker_rejected persistent-sidecar-classification 'validate_live_persistent_viewflow_sidecar' \
    'assert_no_deskflow_runtime'
expect_checker_rejected persistent-activation-boundary 'validate_persistent_activation_boundary' \
    ': # persistent activation boundary bypassed'
expect_checker_rejected persistent-sidecar-capture 'capture_persistent_sidecar_identity "$pid"' \
    ': # persistent sidecar capture bypassed'
expect_checker_rejected persistent-sidecar-replay 'validate_persistent_sidecar_against_receipt "$receipt"' \
    ': # persistent sidecar replay bypassed'
expect_checker_rejected persistent-sidecar-receipt-field 'sidecar_socket_inode' 'sidecar_inode_ignored'
expect_checker_rejected deleted-elf-census 'runtime_pids=$(deskflow_runtime_pids)' "runtime_pids=''"
expect_checker_rejected historical-deskflow-hash '.linux_deskflow_executable_sha256' '.ignored_deskflow_executable_sha256'
expect_checker_rejected deleted-exe-symlink '[[ -L $proc/exe ]] || continue' '[[ -e $proc/exe ]] || continue'
expect_checker_rejected resume-adoption '        persistent_started=1' '        persistent_started=0'
expect_checker_rejected commit-ownership '    receipt_published=1' '    : # receipt ownership bypassed'

# Execute the live-baseline validator with all host-facing helpers replaced by
# deterministic fixture functions.  Each receipt identity class must be live.
terminal_receipt=$fixture_root/terminal.json
linux_started_receipt=$fixture_root/linux-started.json
installed_viewflow_sha=$(printf viewflow | sha256sum | awk '{print $1}')
deskflow_sha=$(printf deskflow | sha256sum | awk '{print $1}')
core_sha=$(printf core | sha256sum | awk '{print $1}')
bwrap_sha=$(printf bwrap | sha256sum | awk '{print $1}')
viewflow_exec=$(printf vfexec | sha256sum | awk '{print $1}')
deskflow_exec=$(printf dfexec | sha256sum | awk '{print $1}')
jq -cn --arg sha "$installed_viewflow_sha" --arg exec "$viewflow_exec" '
    {unit:"viewflow-v13-recovery-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.service",main_pid:111,start_ticks:1001,
     invocation_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",control_group:"/fixture/viewflow",exec_start_sha256:$exec,
     viewflowd_sha256:$sha}' >"$linux_started_receipt"
jq -cn --arg bwrap "$bwrap_sha" --arg desk "$deskflow_sha" --arg core "$core_sha" --arg exec "$deskflow_exec" '
    {linux_deskflow_unit:"deskflow-v13-recovery-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.service",
     linux_deskflow_main_pid:222,linux_deskflow_main_start_ticks:2002,
     linux_deskflow_runtime_pid:333,linux_deskflow_runtime_start_ticks:3003,
     linux_deskflow_core_pid:444,linux_deskflow_core_start_ticks:4004,
     linux_deskflow_invocation_id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
     linux_deskflow_control_group:"/fixture/deskflow",bubblewrap_sha256:$bwrap,
     linux_deskflow_executable_sha256:$desk,linux_deskflow_core_executable_sha256:$core,
     linux_deskflow_runtime_path:"/sealed/deskflow",linux_deskflow_core_runtime_path:"/sealed/deskflow-core",
     linux_deskflow_exec_start_sha256:$exec}' >"$terminal_receipt"

live_viewflow_sha=$installed_viewflow_sha
runtime_link='/sealed/deskflow (deleted)'
core_link='/sealed/deskflow-core (deleted)'
eval "$(extract_function validate_live_transient_baseline)"
eval "$(extract_function validate_live_viewflow_transient)"
eval "$(extract_function validate_live_deskflow_transient)"
eval "$(extract_function assert_persistent_services_inactive)"
die() { printf 'fixture rejection: %s\n' "$*" >&2; exit 1; }
assert_unit_identity() {
    case $1 in
        viewflow-*) [[ $2 == 111 && $3 == 1001 && $4 == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && $5 == /fixture/viewflow ]] || die 'viewflow unit identity mutation' ;;
        deskflow-*) [[ $2 == 222 && $3 == 2002 && $4 == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && $5 == /fixture/deskflow ]] || die 'deskflow unit identity mutation' ;;
        *) die 'unknown fixture unit' ;;
    esac
}
sha256() {
    case $1 in
        /proc/111/exe) printf '%s\n' "$live_viewflow_sha" ;;
        /proc/222/exe) printf '%s\n' "$bwrap_sha" ;;
        /proc/333/exe) printf '%s\n' "$deskflow_sha" ;;
        /proc/444/exe) printf '%s\n' "$core_sha" ;;
        *) sha256sum -- "$1" | awk '{print $1}' ;;
    esac
}
process_start_ticks() { case $1 in 333) echo 3003;; 444) echo 4004;; *) return 1;; esac; }
process_control_group() { case $1 in 333|444) echo /fixture/deskflow;; *) return 1;; esac; }
observed_exec_start_sha() { case $1 in viewflow-*) echo "$viewflow_exec";; deskflow-*) echo "$deskflow_exec";; esac; }
readlink() { case $2 in /proc/333/exe) echo "$runtime_link";; /proc/444/exe) echo "$core_link";; *) /usr/bin/readlink "$@";; esac; }
process_descends_from() { [[ $1:$2 == 333:222 || $1:$2 == 444:333 ]]; }
fixture_persistent_state=inactive
systemctl() { [[ $2 == is-active ]] && echo "${fixture_persistent_state:-inactive}"; }
unit_property() { [[ $2 == MainPID ]] && echo 0; }
VIEWFLOW_UNIT=viewflow-peer.service
DESKFLOW_UNIT=deskflow.service
VIEWFLOW_PORT=44119

(set -e; validate_live_transient_baseline) || fail 'valid isolated transient baseline was rejected'

mutate_json_and_reject() {
    local name=$1 file=$2 filter=$3 original
    original=$fixture_root/$name.original
    cp -- "$file" "$original"
    jq "$filter" "$original" >"$file"
    if (set -e; validate_live_transient_baseline) >/dev/null 2>&1; then
        fail "live validator accepted $name mutation"
    fi
    mv -- "$original" "$file"
}
mutate_json_and_reject pid "$linux_started_receipt" '.main_pid=112'
mutate_json_and_reject ticks "$terminal_receipt" '.linux_deskflow_core_start_ticks=4005'
mutate_json_and_reject invocation "$terminal_receipt" '.linux_deskflow_invocation_id="cccccccccccccccccccccccccccccccc"'
mutate_json_and_reject cgroup "$terminal_receipt" '.linux_deskflow_control_group="/fixture/other"'
mutate_json_and_reject exec-start "$terminal_receipt" '.linux_deskflow_exec_start_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
live_viewflow_sha=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
if (set -e; validate_live_transient_baseline) >/dev/null 2>&1; then fail 'live validator accepted source hash mutation'; fi
live_viewflow_sha=$installed_viewflow_sha
runtime_link=/sealed/deskflow
if (set -e; validate_live_transient_baseline) >/dev/null 2>&1; then fail 'live validator accepted non-deleted runtime link'; fi
runtime_link='/sealed/deskflow (deleted)'

# The unified zero boundary rejects processes by live executable path, by the
# receipt-frozen Deskflow/core hashes after replacement/deletion, and rejects a
# residual sidecar even when units and listeners are otherwise zero.
eval "$(extract_function deskflow_runtime_pids)"
cp -- /usr/bin/sleep "$fixture_root/deskflow"; chmod 0700 "$fixture_root/deskflow"
"$fixture_root/deskflow" 300 & census_pid=$!; fixture_processes+=("$census_pid")
DESKFLOW_INSTALLED=$fixture_root/deskflow
DESKFLOW_CORE_INSTALLED=/fixture/no-core
mapfile -t census_hits < <(deskflow_runtime_pids)
printf '%s\n' "${census_hits[@]}" | grep -Fqx -- "$census_pid" ||
    fail 'Deskflow census missed a live executable-path match'
sleep_sha=$(sha256sum "$fixture_root/deskflow" | awk '{print $1}')
jq --arg sha "$sleep_sha" '.linux_deskflow_executable_sha256=$sha' "$terminal_receipt" >"$fixture_root/terminal-hash.json"
terminal_receipt=$fixture_root/terminal-hash.json
rm -f -- "$fixture_root/deskflow"
[[ $(/usr/bin/readlink "/proc/$census_pid/exe") == *' (deleted)' ]] ||
    fail 'fixture executable did not enter deleted-link state'
DESKFLOW_INSTALLED=/fixture/no-deskflow
mapfile -t census_hits < <(deskflow_runtime_pids)
printf '%s\n' "${census_hits[@]}" | grep -Fqx -- "$census_pid" ||
    fail 'Deskflow census missed a receipt-frozen executable-hash match'
eval "$(extract_function assert_no_deskflow_runtime)"
VIEWFLOW_SIDECAR=$fixture_root/sidecar.sock
DESKFLOW_UNIT=deskflow.service
DESKFLOW_PORT=24800
exact_executable_pids() { :; }
deskflow_runtime_pids() { :; }
assert_no_deskflow_process_runtime() { :; }
systemctl() { [[ $2 == is-active ]] && echo inactive; }
unit_property() { [[ $2 == MainPID ]] && echo 0; }
ss() { :; }
(set -e; assert_no_deskflow_runtime) || fail 'clean Deskflow zero boundary was rejected'
printf x >"$VIEWFLOW_SIDECAR"
if (set -e; assert_no_deskflow_runtime) >/dev/null 2>&1; then
    fail 'Deskflow zero boundary accepted a residual sidecar'
fi
rm -f -- "$VIEWFLOW_SIDECAR"

# Reproduce the real partial-resume shape with an actual AF_UNIX listening
# socket.  The socket must remain present, but its kernel inode, sole PID and FD
# must all belong to the receipt-bound live Viewflow transient.
eval "$(extract_function inspect_live_viewflow_sidecar)"
eval "$(extract_function validate_live_viewflow_transient_sidecar)"
saved_linux_started_receipt=$linux_started_receipt
VIEWFLOW_SIDECAR=$fixture_root/live-transient-sidecar.sock
(umask 077; exec /usr/bin/python3 -c \
    'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4); time.sleep(300)' \
    "$VIEWFLOW_SIDECAR") &
sidecar_pid=$!; fixture_processes+=("$sidecar_pid")
for _ in {1..100}; do [[ -S $VIEWFLOW_SIDECAR ]] && break; sleep 0.01; done
[[ -S $VIEWFLOW_SIDECAR ]] || fail 'AF_UNIX sidecar fixture did not start'
chmod 0600 "$VIEWFLOW_SIDECAR"
linux_started_receipt=$fixture_root/sidecar-linux-started.json
jq -cn --argjson pid "$sidecar_pid" '{main_pid:$pid}' >"$linux_started_receipt"
ss() { /usr/bin/ss "$@"; }
readlink() { /usr/bin/readlink "$@"; }
(set -e; validate_live_viewflow_transient_sidecar) ||
    fail 'exact live Viewflow transient sidecar ownership was rejected'
jq '.main_pid += 1' "$linux_started_receipt" >"$fixture_root/sidecar-linux-started.wrong"
linux_started_receipt=$fixture_root/sidecar-linux-started.wrong
if (set -e; validate_live_viewflow_transient_sidecar) >/dev/null 2>&1; then
    fail 'live transient sidecar validator accepted the wrong PID owner'
fi
linux_started_receipt=$fixture_root/sidecar-linux-started.json
rm -f -- "$VIEWFLOW_SIDECAR"
if (set -e; validate_live_viewflow_transient_sidecar) >/dev/null 2>&1; then
    fail 'live sidecar validator accepted a missing socket dentry'
fi
(umask 077; exec /usr/bin/python3 -c \
    'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4); time.sleep(300)' \
    "$VIEWFLOW_SIDECAR") &
ambiguous_sidecar_pid=$!; fixture_processes+=("$ambiguous_sidecar_pid")
for _ in {1..100}; do [[ -S $VIEWFLOW_SIDECAR ]] && break; sleep 0.01; done
chmod 0600 "$VIEWFLOW_SIDECAR"
if (set -e; validate_live_viewflow_transient_sidecar) >/dev/null 2>&1; then
    fail 'live sidecar validator accepted ambiguous same-path kernel listeners'
fi
kill "$sidecar_pid" "$ambiguous_sidecar_pid"
wait "$sidecar_pid" "$ambiguous_sidecar_pid" 2>/dev/null || true
rm -f -- "$VIEWFLOW_SIDECAR"
linux_started_receipt=$saved_linux_started_receipt
fixture_persistent_state=inactive
systemctl() { [[ $2 == is-active ]] && echo "${fixture_persistent_state:-inactive}"; }

# Drive the unmodified classifier body with real /proc PID liveness.  Only the
# host observation helpers are isolated; its three-state branch logic is real.
classify_linux=$fixture_root/classify-linux.json
classify_terminal=$fixture_root/classify-terminal.json
spawn_fixture_process() {
    /usr/bin/sleep 300 &
    fixture_processes+=("$!")
}
for _ in 1 2 3 4; do spawn_fixture_process; done
classify_viewflow_pid=${fixture_processes[-4]}
classify_main_pid=${fixture_processes[-3]}
classify_runtime_pid=${fixture_processes[-2]}
classify_core_pid=${fixture_processes[-1]}
jq -cn --argjson pid "$classify_viewflow_pid" '{main_pid:$pid}' >"$classify_linux"
jq -cn --argjson main "$classify_main_pid" --argjson runtime "$classify_runtime_pid" --argjson core "$classify_core_pid" \
    '{linux_deskflow_main_pid:$main,linux_deskflow_runtime_pid:$runtime,linux_deskflow_core_pid:$core}' >"$classify_terminal"
run_real_classifier() {
    local expected=$1 expected_log=$2 log_file=$fixture_root/classify.log accepted=0
    : >"$log_file"
    if (
        set -e
        linux_started_receipt=$classify_linux; terminal_receipt=$classify_terminal; transition_state=''
        eval "$(extract_function classify_transition_state)"
        die() { exit 1; }
        validate_live_transient_baseline() { echo baseline >>"$log_file"; }
        validate_live_viewflow_transient() { echo viewflow-live >>"$log_file"; }
        validate_live_viewflow_transient_sidecar() { echo sidecar-live >>"$log_file"; }
        assert_transient_deskflow_zero() { echo deskflow-zero >>"$log_file"; }
        assert_transient_viewflow_zero() { echo viewflow-zero >>"$log_file"; }
        assert_viewflow_transient_unit_zero() { echo viewflow-unit-zero >>"$log_file"; }
        assert_persistent_services_inactive() { echo persistent-zero >>"$log_file"; }
        assert_no_deskflow_runtime() { echo deskflow-runtime-zero >>"$log_file"; }
        assert_no_deskflow_process_runtime() { echo deskflow-process-zero >>"$log_file"; }
        validate_live_persistent_viewflow_sidecar() { echo persistent-sidecar-live >>"$log_file"; }
        classify_transition_state
        [[ $transition_state == "$expected" ]]
    ); then accepted=1; fi
    if [[ $expected == unsupported ]]; then
        ((accepted == 0)) || fail 'real classifier accepted unsupported partial PID state'
        return 0
    fi
    ((accepted == 1)) || fail "real classifier rejected $expected"
    [[ $(paste -sd, "$log_file") == "$expected_log" ]] || fail "real classifier called wrong gates for $expected"
}
run_real_classifier both-live baseline
kill "$classify_main_pid" "$classify_runtime_pid" "$classify_core_pid"
wait "$classify_main_pid" "$classify_runtime_pid" "$classify_core_pid" 2>/dev/null || true
run_real_classifier deskflow-stopped-viewflow-live viewflow-live,deskflow-zero,sidecar-live,persistent-zero
real_partial_state=deskflow-stopped-viewflow-live
kill "$classify_viewflow_pid"; wait "$classify_viewflow_pid" 2>/dev/null || true
run_real_classifier both-zero viewflow-unit-zero,deskflow-zero,viewflow-zero,deskflow-runtime-zero,persistent-zero
fixture_persistent_state=active
run_real_classifier persistent-live viewflow-unit-zero,deskflow-zero,deskflow-process-zero,persistent-sidecar-live
fixture_persistent_state=inactive
for _ in 1 2 3 4; do spawn_fixture_process; done
classify_viewflow_pid=${fixture_processes[-4]}; classify_main_pid=${fixture_processes[-3]}
classify_runtime_pid=${fixture_processes[-2]}; classify_core_pid=${fixture_processes[-1]}
jq -cn --argjson pid "$classify_viewflow_pid" '{main_pid:$pid}' >"$classify_linux"
jq -cn --argjson main "$classify_main_pid" --argjson runtime "$classify_runtime_pid" --argjson core "$classify_core_pid" \
    '{linux_deskflow_main_pid:$main,linux_deskflow_runtime_pid:$runtime,linux_deskflow_core_pid:$core}' >"$classify_terminal"
kill "$classify_main_pid"; wait "$classify_main_pid" 2>/dev/null || true
run_real_classifier unsupported ignored
kill "$classify_viewflow_pid" "$classify_runtime_pid" "$classify_core_pid" 2>/dev/null || true
wait "$classify_viewflow_pid" "$classify_runtime_pid" "$classify_core_pid" 2>/dev/null || true

# The start/resume entry boundary distinguishes both-zero from an already-live
# persistent invocation.  Active resume must retain and reattest its sidecar;
# only inactive/both-zero may require the socket to be absent.
activation_boundary_log=$fixture_root/activation-boundary.log
run_activation_boundary() {
    local state=$1 expected=$2
    : >"$activation_boundary_log"
    (
        set -e
        eval "$(extract_function validate_persistent_activation_boundary)"
        systemctl() { [[ $2 == is-active ]] && echo "$state"; }
        unit_property() { [[ $2 == MainPID ]] && echo 0; }
        assert_no_deskflow_process_runtime() { echo process-zero >>"$activation_boundary_log"; }
        assert_no_deskflow_runtime() { echo full-zero >>"$activation_boundary_log"; }
        validate_live_persistent_viewflow_sidecar() { echo sidecar-live >>"$activation_boundary_log"; }
        validate_persistent_activation_boundary
    ) || fail "persistent $state activation boundary was rejected"
    [[ $(paste -sd, "$activation_boundary_log") == "$expected" ]] ||
        fail "persistent $state activation boundary used the wrong sidecar gate"
}
run_activation_boundary active process-zero,sidecar-live
run_activation_boundary inactive process-zero,full-zero

# The deterministic create-once intent is resumable only with identical input
# bindings.  Partial/both-zero resumes accept the same bytes; missing or corrupt
# intent bytes are rejected without overwrite.
eval "$(extract_function assert_strict_json_document)"
eval "$(extract_function atomic_publish_noreplace)"
eval "$(extract_function write_expected_transition_intent)"
eval "$(extract_function validate_transition_intent)"
eval "$(extract_function read_transition_intent_adoption)"
eval "$(extract_function ensure_transition_intent)"
temporary_files=()
adopt_preintent_partial=0
intent_initial_state=''
preintent_partial_adopted=0
recovery_v3_terminal=''; recovery_v3_terminal_sha=''
recovery_v3_query=''; recovery_v3_query_sha=''
schema5_abort_receipt=''; schema5_abort_receipt_sha=''
durable_vfdqa=''; durable_vfdqa_sha=''
retired_claim=''; retired_claim_sha=''
operation_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
terminal_receipt_sha=$(sha256 "$terminal_receipt")
linux_started_receipt_sha=$(sha256 "$linux_started_receipt")
installed_viewflow_unit_sha=$(printf unit | sha256sum | awk '{print $1}')
handoff_receipt=$fixture_root/intent-handoff.json
ensure_transition_intent both-live
[[ -f ${handoff_receipt}.intent && $(stat -c '%u:%a:%h' -- "${handoff_receipt}.intent") == 1000:600:1 ]] ||
    fail 'fresh durable transition intent was not owner-only/create-once'
intent_good=$fixture_root/intent.good
cp -- "${handoff_receipt}.intent" "$intent_good"
ensure_transition_intent deskflow-stopped-viewflow-live
ensure_transition_intent both-zero
printf '%s\n' corrupt >"${handoff_receipt}.intent"
if (set -e; ensure_transition_intent deskflow-stopped-viewflow-live) >/dev/null 2>&1; then
    fail 'corrupt transition intent was accepted on resume'
fi
cp -- "$intent_good" "${handoff_receipt}.intent"; chmod 0600 "${handoff_receipt}.intent"
handoff_receipt=$fixture_root/missing-resume.json
if (set -e; ensure_transition_intent "$real_partial_state") >/dev/null 2>&1; then
    fail 'partial resume without durable intent was accepted'
fi
eval "$(extract_function assert_preintent_partial_adoption_boundary)"
handoff_receipt=$fixture_root/adopted-partial.json
adopt_preintent_partial=1
adoption_log=$fixture_root/adoption.log
: >"$adoption_log"
unit_property() { [[ $2 == LoadState ]] && echo not-found || echo 0; }
validate_live_viewflow_transient() { echo viewflow >>"$adoption_log"; }
validate_live_viewflow_transient_sidecar() { echo sidecar-live >>"$adoption_log"; }
assert_transient_deskflow_zero() { echo deskflow-zero >>"$adoption_log"; }
assert_persistent_services_inactive() { echo persistent-zero >>"$adoption_log"; }
ensure_transition_intent deskflow-stopped-viewflow-live
[[ $(jq -r '.initial_state' "${handoff_receipt}.intent") == deskflow-stopped-viewflow-live &&
   $(jq -r '.preintent_partial_adopted' "${handoff_receipt}.intent") == true &&
   $(paste -sd, "$adoption_log") == viewflow,deskflow-zero,sidecar-live,persistent-zero ]] ||
    fail 'explicit exact pre-intent partial adoption was not frozen'
if (set -e; ensure_transition_intent deskflow-stopped-viewflow-live) >/dev/null 2>&1; then
    fail 'pre-intent adoption flag was reusable after intent publication'
fi
adopt_preintent_partial=0
handoff_receipt=$fixture_root/preexisting.json
printf '%s\n' owner-existing >"${handoff_receipt}.intent"; chmod 0600 "${handoff_receipt}.intent"
intent_existing_sha=$(sha256sum -- "${handoff_receipt}.intent" | awk '{print $1}')
if (set -e; ensure_transition_intent both-live) >/dev/null 2>&1; then
    fail 'preexisting non-matching intent was overwritten/accepted'
fi
[[ $(sha256sum -- "${handoff_receipt}.intent" | awk '{print $1}') == "$intent_existing_sha" ]] ||
    fail 'preexisting intent changed during no-clobber test'

# A stop interruption must end at the first (Deskflow transient) stop and must
# not advance to Viewflow retirement or persistent service startup.
eval "$(extract_function retire_transients)"
terminal_receipt_sha=$(sha256 "$terminal_receipt")
linux_started_receipt_sha=$(sha256 "$linux_started_receipt")
transition_intent=$fixture_root/transition.intent
printf '%s\n' intent >"$transition_intent"
transition_intent_sha=$(sha256 "$transition_intent")
stop_log=$fixture_root/stop.log
validate_live_transient_baseline() { :; }
classify_transition_state() { transition_state=both-live; }
wait_transients_retired() { printf 'unexpected wait\n' >>"$stop_log"; }
assert_no_deskflow_runtime() { printf 'unexpected boundary\n' >>"$stop_log"; }
systemctl() {
    printf '%s\n' "$*" >>"$stop_log"
    [[ $* != *'stop deskflow-v13-recovery-'* ]] || exit 77
}
if (set -e; retire_transients) >/dev/null 2>&1; then fail 'Deskflow transient stop interruption was accepted'; fi
[[ $(wc -l <"$stop_log") == 1 && $(<"$stop_log") == *'stop deskflow-v13-recovery-'* ]] ||
    fail 'stop interruption advanced beyond the failed Deskflow stop'

# A journal slice with the exact startup record but no new Windows probe is not
# an authenticated persistent-v1.3 boundary.
eval "$(extract_function capture_persistent_journal)"
persistent_invocation=dddddddddddddddddddddddddddddddd
PROTOCOL_13_STARTUP='viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged'
journalctl() {
    jq -cn --arg invocation "$persistent_invocation" --arg message "$PROTOCOL_13_STARTUP" \
        '{_SYSTEMD_INVOCATION_ID:$invocation,MESSAGE:$message,__CURSOR:"s=1",__REALTIME_TIMESTAMP:"100"}'
}
if (set -e; capture_persistent_journal "$fixture_root/journal.json") >/dev/null 2>&1; then
    fail 'persistent journal without authenticated probe was accepted'
fi

# Execute the production final reattestation helper itself.  The systemd,
# socket and journal boundaries are deterministic, while every tuple comparison
# and the receipt binding logic remains the production implementation.
eval "$(extract_function final_reattest_against_receipt)"
eval "$(extract_function validate_persistent_sidecar_against_receipt)"
assert_bound_inputs_unchanged() { :; }
VIEWFLOW_SIDECAR=$fixture_root/final-sidecar.sock
(umask 077; exec /usr/bin/python3 -c \
    'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4); time.sleep(300)' \
    "$VIEWFLOW_SIDECAR") &
final_pid=$!; fixture_processes+=("$final_pid")
for _ in {1..100}; do [[ -S $VIEWFLOW_SIDECAR ]] && break; sleep 0.01; done
[[ -S $VIEWFLOW_SIDECAR ]] || fail 'persistent AF_UNIX sidecar fixture did not start'
chmod 0600 "$VIEWFLOW_SIDECAR"
final_sidecar_inode=$(awk -v path="$VIEWFLOW_SIDECAR" '$8 == path {print $7}' /proc/net/unix)
final_sidecar_fd=''
for fixture_fd in /proc/$final_pid/fd/[0-9]*; do
    [[ $(/usr/bin/readlink "$fixture_fd" 2>/dev/null || true) == "socket:[$final_sidecar_inode]" ]] &&
        final_sidecar_fd=${fixture_fd##*/}
done
[[ $final_sidecar_inode =~ ^[1-9][0-9]*$ && $final_sidecar_fd =~ ^[0-9]+$ ]] ||
    fail 'persistent AF_UNIX sidecar fixture identity is incomplete'
final_ticks=9009
final_invocation=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
final_cgroup=/fixture/final
final_exec=$(printf final-exec | sha256sum | awk '{print $1}')
final_cmdline=$(printf final-cmdline | sha256sum | awk '{print $1}')
final_probe='viewflowd server peer 172.16.105.70:44119 probe=7 responder_us=88'
final_probe_sha=$(printf '%s' "$final_probe" | sha256sum | awk '{print $1}')
VIEWFLOW_INSTALLED=/fixture/viewflowd
VIEWFLOW_UNIT_FILE=/fixture/viewflow-peer.service
VIEWFLOW_UNIT=viewflow-peer.service
DESKFLOW_UNIT=deskflow.service
transition_intent=$fixture_root/final.intent
printf '%s\n' final-intent >"$transition_intent"
transition_intent_sha=$(sha256sum -- "$transition_intent" | awk '{print $1}')
terminal_receipt_sha=$(sha256sum -- "$terminal_receipt" | awk '{print $1}')
linux_started_receipt_sha=$(sha256sum -- "$linux_started_receipt" | awk '{print $1}')
final_receipt=$fixture_root/final-receipt.json
jq -cn --argjson pid "$final_pid" --argjson ticks "$final_ticks" --arg invocation "$final_invocation" \
    --arg cgroup "$final_cgroup" --arg exec "$final_exec" --arg cmdline "$final_cmdline" --arg probe "$final_probe_sha" \
    --arg sidecar "$VIEWFLOW_SIDECAR" --argjson sidecar_inode "$final_sidecar_inode" \
    --argjson sidecar_fd "$final_sidecar_fd" '
    {persistent_viewflow:{main_pid:$pid,start_ticks:$ticks,invocation_id:$invocation,control_group:$cgroup,
      expected_exec_start_sha256:$exec,observed_exec_start_sha256:$exec,cmdline_sha256:$cmdline,
      sidecar_socket_path:$sidecar,sidecar_socket_inode:$sidecar_inode,sidecar_owner_pid:$pid,
      sidecar_owner_fd:$sidecar_fd,sidecar_listener_count:1,
      authenticated_probe_record_sha256:$probe}}' >"$final_receipt"
final_observed_exec=$final_exec
final_live_cmdline=$final_cmdline
final_live_exe=$installed_viewflow_sha
final_exact_pids=$final_pid
final_udp_owner=$final_pid
final_deskflow_zero=1
unit_property() {
    case $2 in
        LoadState) echo loaded;; ActiveState) echo active;; SubState) echo running;;
        MainPID) echo "$final_pid";; InvocationID) echo "$final_invocation";; ControlGroup) echo "$final_cgroup";;
        *) return 1;;
    esac
}
process_start_ticks() { echo "$final_ticks"; }
process_control_group() { echo "$final_cgroup"; }
observed_exec_start_sha() { echo "$final_observed_exec"; }
exact_executable_pids() { printf '%b\n' "$final_exact_pids"; }
sha256() {
    case $1 in
        "$terminal_receipt") echo "$terminal_receipt_sha";;
        "$linux_started_receipt") echo "$linux_started_receipt_sha";;
        "$transition_intent") echo "$transition_intent_sha";;
        "$VIEWFLOW_INSTALLED") echo "$installed_viewflow_sha";;
        "$VIEWFLOW_UNIT_FILE") echo "$installed_viewflow_unit_sha";;
        "/proc/$final_pid/exe") echo "$final_live_exe";;
        "/proc/$final_pid/cmdline") echo "$final_live_cmdline";;
        *) sha256sum -- "$1" | awk '{print $1}';;
    esac
}
ss() {
    if [[ $* == *'-xlpn'* ]]; then
        /usr/bin/ss "$@"
    else
        printf 'UNCONN 0 0 0.0.0.0:44119 0.0.0.0:* users:(("viewflowd",pid=%s,fd=3))\n' "$final_udp_owner"
    fi
}
assert_no_deskflow_process_runtime() { ((final_deskflow_zero == 1)) || die 'fixture Deskflow mutation'; }
journalctl() {
    jq -cn --arg invocation "$final_invocation" --arg message "$PROTOCOL_13_STARTUP" \
        '{_SYSTEMD_INVOCATION_ID:$invocation,MESSAGE:$message,__CURSOR:"s=1",__REALTIME_TIMESTAMP:"100"}'
    jq -cn --arg invocation "$final_invocation" --arg message "$final_probe" \
        '{_SYSTEMD_INVOCATION_ID:$invocation,MESSAGE:$message,__CURSOR:"s=2",__REALTIME_TIMESTAMP:"200"}'
}
(set -e; final_reattest_against_receipt "$final_receipt") || fail 'valid final tuple was rejected by production reattestation helper'

# Exercise the complete production receipt validator with a real, fully shaped
# receipt.  Keep this before the publication no-clobber section, which
# intentionally replaces the validator with a stub for that isolated test.
eval "$(extract_function validate_handoff_receipt)"
persistent_invocation=$final_invocation
capture_persistent_journal "$fixture_root/persistent-journal.json"
persistent_journal_sha=$(sha256sum -- "$fixture_root/persistent-journal.json" | awk '{print $1}')
persistent_startup_sha=$(printf '%s' "$PROTOCOL_13_STARTUP" | sha256sum | awk '{print $1}')
persistent_probe_sha=$final_probe_sha
persistent_journal_start_cursor=s=1
persistent_journal_end_cursor=s=2
persistent_journal_entries=2
persistent_journal_start_us=100
persistent_journal_end_us=200
persistent_probe_port=44119
persistent_invocation=$final_invocation
persistent_cgroup=$final_cgroup
persistent_expected_exec=$final_exec
persistent_observed_exec=$final_exec
persistent_cmdline_sha=$final_cmdline
persistent_pid=$final_pid
persistent_ticks=$final_ticks
intent_initial_state=both-live
preintent_partial_adopted=0
installed_viewflow_unit_sha=$(printf unit | sha256sum | awk '{print $1}')
handoff_receipt=$fixture_root/validated-handoff.json
recovery_v3_terminal=$fixture_root/recovery-terminal.json; recovery_v3_terminal_sha=$(printf recovery-terminal | sha256sum | awk '{print $1}')
recovery_v3_query=$fixture_root/recovery-query.json; recovery_v3_query_sha=$(printf recovery-query | sha256sum | awk '{print $1}')
schema5_abort_receipt=$fixture_root/schema5-abort.json; schema5_abort_receipt_sha=$(printf schema5-abort | sha256sum | awk '{print $1}')
durable_vfdqa=$fixture_root/durable-vfdqa.bin; durable_vfdqa_sha=$(printf durable-vfdqa | sha256sum | awk '{print $1}')
retired_claim=$fixture_root/retired-vfdqt.bin; retired_claim_sha=$(printf retired-vfdqt | sha256sum | awk '{print $1}')
jq -cn --arg op "$operation_id" --arg terminal "$terminal_receipt" --arg terminal_sha "$terminal_receipt_sha" \
    --arg linux "$linux_started_receipt" --arg linux_sha "$linux_started_receipt_sha" \
    --arg recovery_terminal "$recovery_v3_terminal" --arg recovery_terminal_sha "$recovery_v3_terminal_sha" \
    --arg recovery_query "$recovery_v3_query" --arg recovery_query_sha "$recovery_v3_query_sha" \
    --arg abort_receipt "$schema5_abort_receipt" --arg abort_receipt_sha "$schema5_abort_receipt_sha" \
    --arg vfdqa "$durable_vfdqa" --arg vfdqa_sha "$durable_vfdqa_sha" \
    --arg retired "$retired_claim" --arg retired_sha "$retired_claim_sha" \
    --arg viewflow "$VIEWFLOW_INSTALLED" --arg viewflow_sha "$installed_viewflow_sha" \
    --arg unit_file "$VIEWFLOW_UNIT_FILE" --arg unit_sha "$installed_viewflow_unit_sha" \
    --arg unit "$VIEWFLOW_UNIT" --arg deskflow "$DESKFLOW_UNIT" --arg invocation "$final_invocation" \
    --arg intent "$transition_intent" --arg intent_sha "$transition_intent_sha" \
    --arg initial_state "$intent_initial_state" --arg cgroup "$persistent_cgroup" \
    --arg expected "$persistent_expected_exec" --arg observed "$persistent_observed_exec" \
    --arg cmdline "$persistent_cmdline_sha" --arg startup "$persistent_startup_sha" \
    --arg sidecar "$VIEWFLOW_SIDECAR" --argjson sidecar_inode "$final_sidecar_inode" \
    --argjson sidecar_fd "$final_sidecar_fd" \
    --arg probe "$persistent_probe_sha" --arg journal "$persistent_journal_sha" \
    --arg start_cursor "$persistent_journal_start_cursor" --arg end_cursor "$persistent_journal_end_cursor" \
    --arg completed '2026-08-30T00:00:00.000Z' --argjson peer_port "$persistent_probe_port" \
    --argjson journal_entries "$persistent_journal_entries" --argjson journal_start_us "$persistent_journal_start_us" \
    --argjson journal_end_us "$persistent_journal_end_us" --argjson pid "$persistent_pid" \
    --argjson ticks "$persistent_ticks" '
    {schema_version:1,state:"viewflow-abort-transients-handed-off-to-persistent-v13",operation_id:$op,
     initial_state:$initial_state,preintent_partial_adopted:false,
     terminal_receipt_path:$terminal,terminal_receipt_sha256:$terminal_sha,
     linux_v13_started_receipt_path:$linux,linux_v13_started_receipt_sha256:$linux_sha,
     transition_intent_path:$intent,transition_intent_sha256:$intent_sha,
     recovery_v3_lineage:{terminal_path:$recovery_terminal,terminal_sha256:$recovery_terminal_sha,
       query_path:$recovery_query,query_sha256:$recovery_query_sha,
       schema5_abort_receipt_path:$abort_receipt,schema5_abort_receipt_sha256:$abort_receipt_sha,
       durable_vfdqa_path:$vfdqa,durable_vfdqa_sha256:$vfdqa_sha,
       retired_claim_path:$retired,retired_claim_sha256:$retired_sha},
     quarantine_absence:{deployment_marker_present:false,abort_claim_present:false,
       release_claim_present:false,runtime_marker_present:false},
     post_transient_stop:{viewflow_exact_process_count:0,deskflow_exact_process_count:0,
       deskflow_core_exact_process_count:0,udp_44119_listener_count:0,tcp_24800_listener_count:0,
       sidecar_socket_present:false},
     persistent_viewflow:{unit:$unit,unit_active_state:"active",unit_file_path:$unit_file,
       unit_file_sha256:$unit_sha,executable_path:$viewflow,executable_sha256:$viewflow_sha,
       main_pid:$pid,start_ticks:$ticks,invocation_id:$invocation,control_group:$cgroup,
       expected_exec_start_sha256:$expected,observed_exec_start_sha256:$observed,
       sidecar_socket_path:$sidecar,sidecar_socket_inode:$sidecar_inode,sidecar_owner_pid:$pid,
       sidecar_owner_fd:$sidecar_fd,sidecar_listener_count:1,
       cmdline_sha256:$cmdline,udp_44119_listener_count:1,protocol_startup_record_sha256:$startup,
       authenticated_peer_ip:"172.16.105.70",authenticated_peer_port:$peer_port,
       authenticated_probe_record_sha256:$probe,journal_invocation_id:$invocation,
       journal_slice_sha256:$journal,journal_entry_count:$journal_entries,
       journal_start_cursor:$start_cursor,journal_start_realtime_timestamp_us:$journal_start_us,
       journal_end_cursor:$end_cursor,journal_end_realtime_timestamp_us:$journal_end_us},
     deskflow:{unit:$deskflow,unit_active_state:"inactive",main_pid:0,exact_process_count:0,
       core_exact_process_count:0,tcp_24800_listener_count:0,started_by_handoff:false},
     completed_at_utc:$completed}
    ' >"$handoff_receipt"
if (set -e; validate_handoff_receipt "$handoff_receipt") >/dev/null 2>&1; then :; else
    fail 'complete valid handoff receipt was rejected by production validator'
fi
cp -- "$handoff_receipt" "$fixture_root/validated-handoff.original"
jq '.persistent_viewflow.journal_end_realtime_timestamp_us = 99' \
    "$fixture_root/validated-handoff.original" >"$handoff_receipt"
if (set -e; validate_handoff_receipt "$handoff_receipt") >/dev/null 2>&1; then
    fail 'production validator accepted journal end before journal start'
fi
mv -- "$fixture_root/validated-handoff.original" "$handoff_receipt"

mutate_final_receipt_reject() {
    local name=$1 filter=$2 original
    original=$fixture_root/final-$name.original
    cp -- "$final_receipt" "$original"
    jq "$filter" "$original" >"$final_receipt"
    if (set -e; final_reattest_against_receipt "$final_receipt") >/dev/null 2>&1; then
        fail "final reattestation accepted $name receipt mutation"
    fi
    mv -- "$original" "$final_receipt"
}
mutate_final_receipt_reject pid '.persistent_viewflow.main_pid += 1'
mutate_final_receipt_reject ticks '.persistent_viewflow.start_ticks += 1'
mutate_final_receipt_reject invocation '.persistent_viewflow.invocation_id="ffffffffffffffffffffffffffffffff"'
mutate_final_receipt_reject cgroup '.persistent_viewflow.control_group="/fixture/other"'
mutate_final_receipt_reject exec-start '.persistent_viewflow.expected_exec_start_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
mutate_final_receipt_reject cmdline '.persistent_viewflow.cmdline_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
mutate_final_receipt_reject probe '.persistent_viewflow.authenticated_probe_record_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"'
mutate_final_receipt_reject sidecar-path '.persistent_viewflow.sidecar_socket_path="/fixture/wrong.sock"'
mutate_final_receipt_reject sidecar-inode '.persistent_viewflow.sidecar_socket_inode += 1'
mutate_final_receipt_reject sidecar-owner-pid '.persistent_viewflow.sidecar_owner_pid += 1'
mutate_final_receipt_reject sidecar-owner-fd '.persistent_viewflow.sidecar_owner_fd += 1'
mutate_final_receipt_reject sidecar-count '.persistent_viewflow.sidecar_listener_count = 2'
final_live_exe=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
if (set -e; final_reattest_against_receipt "$final_receipt") >/dev/null 2>&1; then fail 'final reattestation accepted executable hash mutation'; fi
final_live_exe=$installed_viewflow_sha
final_exact_pids="$final_pid\\n99999"
if (set -e; final_reattest_against_receipt "$final_receipt") >/dev/null 2>&1; then fail 'final reattestation accepted extra exact executable PID'; fi
final_exact_pids=$final_pid
final_udp_owner=99999
if (set -e; final_reattest_against_receipt "$final_receipt") >/dev/null 2>&1; then fail 'final reattestation accepted wrong UDP owner'; fi
final_udp_owner=$final_pid
final_deskflow_zero=0
if (set -e; final_reattest_against_receipt "$final_receipt") >/dev/null 2>&1; then fail 'final reattestation accepted nonzero Deskflow boundary'; fi
final_deskflow_zero=1
rm -f -- "$VIEWFLOW_SIDECAR"
if (set -e; final_reattest_against_receipt "$final_receipt") >/dev/null 2>&1; then
    fail 'final reattestation accepted a missing persistent sidecar dentry'
fi
(umask 077; exec /usr/bin/python3 -c \
    'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(4); time.sleep(300)' \
    "$VIEWFLOW_SIDECAR") &
final_ambiguous_pid=$!; fixture_processes+=("$final_ambiguous_pid")
for _ in {1..100}; do [[ -S $VIEWFLOW_SIDECAR ]] && break; sleep 0.01; done
chmod 0600 "$VIEWFLOW_SIDECAR"
if (set -e; final_reattest_against_receipt "$final_receipt") >/dev/null 2>&1; then
    fail 'final reattestation accepted ambiguous persistent sidecar listeners'
fi
kill "$final_ambiguous_pid"; wait "$final_ambiguous_pid" 2>/dev/null || true
kill "$final_pid"; wait "$final_pid" 2>/dev/null || true
rm -f -- "$VIEWFLOW_SIDECAR"

# Publication uses a hard-link no-replace linearization point.  An existing
# receipt must remain byte-for-byte unchanged.
eval "$(extract_function publish_handoff_receipt)"
handoff_receipt=$fixture_root/existing.json
printf '%s\n' 'owner-existing' >"$handoff_receipt"
existing_sha=$(sha256sum -- "$handoff_receipt" | awk '{print $1}')
receipt_temp=''; receipt_published=0
operation_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
terminal_receipt_sha=$(sha256 "$terminal_receipt"); linux_started_receipt_sha=$(sha256 "$linux_started_receipt")
VIEWFLOW_INSTALLED=/fixture/viewflowd; VIEWFLOW_UNIT_FILE=/fixture/viewflow-peer.service
VIEWFLOW_UNIT=viewflow-peer.service; DESKFLOW_UNIT=deskflow.service
installed_viewflow_unit_sha=$(printf unit | sha256sum | awk '{print $1}')
persistent_invocation=dddddddddddddddddddddddddddddddd; persistent_cgroup=/fixture/persistent
persistent_expected_exec=$viewflow_exec; persistent_observed_exec=$viewflow_exec
persistent_cmdline_sha=$viewflow_exec; persistent_startup_sha=$viewflow_exec
persistent_probe_sha=$viewflow_exec; persistent_journal_sha=$viewflow_exec
persistent_journal_start_cursor=s=1; persistent_journal_end_cursor=s=2
persistent_probe_port=44119; persistent_journal_entries=2
persistent_journal_start_us=100; persistent_journal_end_us=200
persistent_pid=555; persistent_ticks=5005
persistent_sidecar_path=$VIEWFLOW_SIDECAR; persistent_sidecar_inode=$final_sidecar_inode
persistent_sidecar_owner_pid=$persistent_pid; persistent_sidecar_owner_fd=$final_sidecar_fd
persistent_sidecar_listener_count=1
validate_handoff_receipt() { :; }
capture_persistent_journal() { :; }
final_reattest_against_receipt() { :; }
sync() { :; }
if (set -e; publish_handoff_receipt) >/dev/null 2>&1; then fail 'receipt publisher overwrote an existing path'; fi
[[ $(sha256sum -- "$handoff_receipt" | awk '{print $1}') == "$existing_sha" && $(<"$handoff_receipt") == owner-existing ]] ||
    fail 'existing receipt changed during no-clobber test'

# The activation helper makes a SIGKILL-left active service an explicit resume
# boundary: it adopts without a second start, while still owning cleanup until
# the create-once handoff receipt commits.
eval "$(extract_function establish_persistent_service_activation)"
activation_log=$fixture_root/activation.log
persistent_started=0
systemctl() {
    printf '%s\n' "$*" >>"$activation_log"
    [[ $2 == is-active ]] && echo active
}
establish_persistent_service_activation
[[ $persistent_started == 1 && $(wc -l <"$activation_log") == 1 &&
   $(<"$activation_log") == '--user is-active viewflow-peer.service' ]] ||
    fail 'active SIGKILL-resume boundary was restarted or not cleanup-owned'

# Cleanup ownership is the exact invocation tuple, not merely the unit name or
# a local boolean.  A concurrent restart changes InvocationID and must make the
# stop gate fail closed.
eval "$(extract_function capture_persistent_cleanup_identity)"
eval "$(extract_function persistent_cleanup_identity_matches)"
/usr/bin/sleep 300 & cleanup_pid=$!; fixture_processes+=("$cleanup_pid")
cleanup_ticks=8080
cleanup_invocation=abababababababababababababababab
cleanup_cgroup=/fixture/viewflow-peer.service
cleanup_live_invocation=$cleanup_invocation
installed_viewflow_sha=$(printf cleanup-exe | sha256sum | awk '{print $1}')
unit_property() {
    case $2 in
        ActiveState) echo active;; SubState) echo running;; MainPID) echo "$cleanup_pid";;
        InvocationID) echo "$cleanup_live_invocation";; ControlGroup) echo "$cleanup_cgroup";;
        *) return 1;;
    esac
}
process_start_ticks() { echo "$cleanup_ticks"; }
process_control_group() { echo "$cleanup_cgroup"; }
sha256() { [[ $1 == "/proc/$cleanup_pid/exe" ]] && echo "$installed_viewflow_sha" || sha256sum -- "$1" | awk '{print $1}'; }
persistent_owned_pid=''; persistent_owned_ticks=''; persistent_owned_invocation=''; persistent_owned_cgroup=''
capture_persistent_cleanup_identity "$cleanup_pid" "$cleanup_ticks" "$cleanup_invocation" "$cleanup_cgroup"
persistent_cleanup_identity_matches || fail 'exact cleanup ownership tuple was rejected'
cleanup_live_invocation=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
if persistent_cleanup_identity_matches; then
    fail 'cleanup ownership accepted an InvocationID swap'
fi
cleanup_live_invocation=$cleanup_invocation

# A committed receipt is recognized by EXIT cleanup even if the shell is
# interrupted before its in-memory flag is set.  The committed service must not
# be stopped; without a valid commit, cleanup still stops the owned service.
eval "$(extract_function cleanup)"
cleanup_log=$fixture_root/cleanup.log
handoff_receipt=$fixture_root/cleanup-committed.json
printf '{}\n' >"$handoff_receipt"; chmod 0600 "$handoff_receipt"
if (set +e; receipt_temp=''; temporary_files=(); persistent_started=1; receipt_published=0
    validate_handoff_receipt() { return 0; }
    systemctl() { printf '%s\n' "$*" >>"$cleanup_log"; }
    false; cleanup); then
    fail 'cleanup fixture unexpectedly returned success'
fi
[[ ! -s $cleanup_log ]] || fail 'cleanup stopped service after valid receipt commit'
: >"$cleanup_log"
if (set +e; receipt_temp=''; temporary_files=(); persistent_started=1; receipt_published=0
    validate_handoff_receipt() { return 1; }
    persistent_cleanup_identity_matches() { return 0; }
    systemctl() { printf '%s\n' "$*" >>"$cleanup_log"; }
    false; cleanup); then
    fail 'uncommitted cleanup fixture unexpectedly returned success'
fi
grep -Fqx -- '--user stop viewflow-peer.service' "$cleanup_log" ||
    fail 'cleanup did not stop an owned uncommitted service'
: >"$cleanup_log"
if (set +e; receipt_temp=''; temporary_files=(); persistent_started=1; receipt_published=0
    validate_handoff_receipt() { return 1; }
    persistent_cleanup_identity_matches() { return 1; }
    systemctl() { printf '%s\n' "$*" >>"$cleanup_log"; }
    false; cleanup) 2>/dev/null; then
    fail 'identity-swapped cleanup fixture unexpectedly returned success'
fi
[[ ! -s $cleanup_log ]] || fail 'cleanup stopped a concurrently replaced invocation'

# The no-replace rename is itself the durable commit.  Killing the caller
# immediately after it returns cannot leave a second-link intermediate or an
# ambiguous destination.
kill_source=$fixture_root/kill-source.json
kill_destination=$fixture_root/kill-destination.json
printf '%s\n' crash-safe >"$kill_source"; chmod 0600 "$kill_source"
set +e
(atomic_publish_noreplace "$kill_source" "$kill_destination"; kill -KILL "$BASHPID") 2>/dev/null
kill_status=$?
set -e
[[ $kill_status == 137 && ! -e $kill_source && -f $kill_destination &&
   $(stat -c '%u:%a:%h' -- "$kill_destination") == 1000:600:1 &&
   $(<"$kill_destination") == crash-safe ]] ||
    fail 'SIGKILL after atomic commit left an ambiguous receipt dentry'

# Once the receipt exists, main takes the read-only reattestation path and may
# not classify/retire/start/publish again.
eval "$(extract_function main)"
main_log=$fixture_root/main-replay.log
handoff_receipt=$kill_destination
preflight() { echo preflight >>"$main_log"; }
replay_committed_handoff() { echo replay >>"$main_log"; }
classify_transition_state() { echo classify >>"$main_log"; }
ensure_transition_intent() { echo intent >>"$main_log"; }
retire_transients() { echo retire >>"$main_log"; }
start_and_validate_persistent_viewflow() { echo start >>"$main_log"; }
publish_handoff_receipt() { echo publish >>"$main_log"; }
main
[[ $(paste -sd, "$main_log") == preflight,replay ]] ||
    fail 'committed handoff replay redispatched a service mutation'

# Exercise recovery-v3/schema5 lineage semantics with hermetic documents.
eval "$(extract_function validate_recovery_v3_lineage)"
assert_quarantine_absent() { :; }
operation_id=442fe737e67f43b89d85a7e33149a072
terminal_receipt_sha=$(printf transition | sha256sum | awk '{print $1}')
linux_started_receipt_sha=$(printf linux-started | sha256sum | awk '{print $1}')
schema5_abort_receipt_sha=6cd825cd6003053b3677acc0235933f34e179aba3723a77b14aeada9d1ec3766
recovery_v3_query_sha=4f8a7cb2f0f0c4f01397a4eb4b9f0c1350f52607fb07acec763c19593da519a8
durable_vfdqa_sha=c5a4b7b0900f8907087c65724f630b474facd894d4bf23749b562ea7af967b19
retired_claim_sha=a336070106802153c9834154ab493b22a19eeb434ebed1e77000e44aa9ba5000
durable_vfdqa=$fixture_root/frozen-vfdqa.bin
schema5_abort_receipt=$fixture_root/frozen-schema5-abort.json
recovery_v3_query=$fixture_root/frozen-recovery-query.json
recovery_v3_terminal=$fixture_root/frozen-recovery-terminal.json
jq -cn --arg op "$operation_id" --arg linux "$linux_started_receipt_sha" --arg marker "$retired_claim_sha" \
    --arg durable "$durable_vfdqa" '
    {schema_version:5,state:"deployment-quarantine-aborted",operation_id:$op,replayed:false,
     protocol_version:"1.3",protocol_2_1:false,rollback_performed:true,rollback_token_consumed:true,
     mutation_permit_published:true,force_release_executed:false,second_force_release_executed:false,
     deployment_release_claimed:false,coordinator_failure_phase:"MUTATION_PERMITTED",
     coordinator_mutation_possible:true,linux_v13_started_receipt_sha256:$linux,
     aborted_marker_sha256:$marker,marker_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1",
     abort_claim_path:"/home/wilf/.local/state/viewflow/deployment-quarantine.v1.abort-claim",
     abort_receipt_path:$durable,abort_authorization_path:"/fixture/auth",abort_authorization_sha256:("a"*64),
     abort_committed_at_unix_ms:"1",abort_committed_at_utc:"2026-09-04T00:00:00.000Z",abort_point:"fixture",
     authenticated_v13_peer_receipt_sha256:("b"*64),authorization_state:"fixture",
     bootstrap_request_sha256:("c"*64),coordinator_instance_id:"703230e5-6349-42f9-81de-bf1c1ba418a0",
     coordinator_terminal_state_sha256:("d"*64),deployment_publish_receipt_sha256:("e"*64),
     initial_force_release_executed:false,installer_exit_receipt_sha256:("f"*64),
     linux_deactivation_proof_sha256:("1"*64),linux_deactivation_transcript_sha256:("2"*64),
     linux_frozen_evidence_sha256:("3"*64),marker_created_at_unix_ms:"1",marker_generation:"1",
     marker_handoff_receipt_sha256:("4"*64),mutation_permit_receipt_sha256:("5"*64),
     recovery_bundle_sha256:("6"*64),schema1_handoff_lineage_receipt_sha256:("7"*64),
     source_display_id:"00000000-0000-0000-0000-000000000101",
     target_device_id:"00000000-0000-0000-0000-000000000002",windows_prepared_receipt_sha256:("8"*64),
     windows_rollback_receipt_sha256:("9"*64),windows_stop_evidence_sha256:("0"*64),
     windows_v13_started_receipt_sha256:("a"*64)}' >"$schema5_abort_receipt"
jq -cn --slurpfile abort "$schema5_abort_receipt" --arg op "$operation_id" --arg receipt "$schema5_abort_receipt_sha" '
    {schema_version:3,state:"viewflow-op442-schema5-abort-recovery-v3-marker-query-replayed",
     operation_id:$op,committed_abort_receipt_sha256:$receipt,coordinator_redispatched:false,
     authorization_sha256:("a"*64),marker_query:($abort[0]|.replayed=true),marker_query_sha256:("b"*64),
     predecessor_v2_approval_sha256:("c"*64),predecessor_v2_gate_sha256:("d"*64),
     predecessor_v2_launcher_sha256:("e"*64),predecessor_v2_manifest_sha256:("f"*64)}' >"$recovery_v3_query"
jq -cn --arg op "$operation_id" --arg receipt "$schema5_abort_receipt_sha" \
    --arg query "$recovery_v3_query_sha" --arg durable "$durable_vfdqa_sha" --arg retired "$retired_claim_sha" \
    --arg transition "$terminal_receipt_sha" --arg linux "$linux_started_receipt_sha" '
    {schema_version:3,state:"viewflow-op442-schema5-abort-post-commit-recovery-v3-terminal",operation_id:$op,
     committed_abort_receipt_sha256:$receipt,recovery_query_sha256:$query,durable_vfdqa_sha256:$durable,
     retired_claim_sha256:$retired,marker_absent:true,marker_query_replayed:true,coordinator_redispatched:false,
     committed_v1_output_sha256:{abort_receipt:$receipt,transition:$transition,linux_v13_started:$linux,
       authenticated_v13_peer:("a"*64),authorization:("b"*64),windows_v13_started:("c"*64)},
     abort_committed_at_unix_ms:"1",approval_sha256:("1"*64),gate_sha256:("2"*64),launcher_sha256:("3"*64),
     linux_live_census_sha256:("4"*64),manifest_sha256:("5"*64),predecessor_v2_approval_sha256:("6"*64),
     predecessor_v2_gate_sha256:("7"*64),predecessor_v2_launcher_sha256:("8"*64),
     predecessor_v2_manifest_sha256:("9"*64),windows_live_census_sha256:("0"*64)}' >"$recovery_v3_terminal"
jq --arg abort "$schema5_abort_receipt_sha" --arg marker "$retired_claim_sha" \
    '.deployment_abort_receipt_sha256=$abort | .deployment_marker_sha256=$marker' \
    "$terminal_receipt" >"$fixture_root/transition-bound.json"
terminal_receipt=$fixture_root/transition-bound.json
(set -e; validate_recovery_v3_lineage) || fail 'valid recovery-v3/schema5 lineage was rejected'
cp -- "$recovery_v3_query" "$fixture_root/recovery-query.good"
jq '.marker_query.replayed=false' "$fixture_root/recovery-query.good" >"$recovery_v3_query"
if (set -e; validate_recovery_v3_lineage) >/dev/null 2>&1; then
    fail 'lineage validator accepted non-replayed schema5 query'
fi
mv -- "$fixture_root/recovery-query.good" "$recovery_v3_query"
cp -- "$recovery_v3_terminal" "$fixture_root/recovery-terminal.good"
jq '.durable_vfdqa_sha256=("0"*64)' "$fixture_root/recovery-terminal.good" >"$recovery_v3_terminal"
if (set -e; validate_recovery_v3_lineage) >/dev/null 2>&1; then
    fail 'lineage validator accepted wrong durable VFDQA binding'
fi
mv -- "$fixture_root/recovery-terminal.good" "$recovery_v3_terminal"

printf 'handoff isolated/static-negative fixtures: PASS\n'
