#!/usr/bin/env bash

# Transactionally replace the Linux Viewflow/Deskflow runtime. This script is
# deliberately host-specific: changing a destination, unit, peer, or identity
# requires a reviewed script change instead of an extra command-line switch.

set -Eeuo pipefail
shopt -s nullglob

readonly EXPECTED_UID=1000
readonly EXPECTED_HOME=/home/wilf
readonly VIEWFLOW_UNIT=viewflow-peer.service
readonly DESKFLOW_UNIT=deskflow.service
readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd
readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker
readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow
readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core
readonly VIEWFLOW_UNIT_INSTALLED=/home/wilf/.config/systemd/user/viewflow-peer.service
readonly DESKFLOW_DROPIN_INSTALLED=/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf
readonly DESKFLOW_QUARANTINE_PARENT=/home/wilf/.local/state/viewflow
readonly DESKFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly DESKFLOW_QUARANTINE_MAGIC=VFQST002
readonly DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly DEPLOYMENT_QUARANTINE_MAGIC=VFDQT001
readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly DEPLOYMENT_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly BACKUP_PARENT=/home/wilf/.local/state/viewflow/deploy-backups
readonly VIEWFLOW_BIND=0.0.0.0:44119
readonly VIEWFLOW_PORT=44119
readonly DESKFLOW_PORT=24800
readonly VIEWFLOW_DEVICE=00000000000000000000000000000001
readonly VIEWFLOW_PEER=172.16.105.70
readonly VIEWFLOW_TARGET=00000000000000000000000000000002
readonly WINDOWS_EXPECTED_PEER=172.16.105.62:44119
readonly WINDOWS_EXPECTED_SESSION=1
readonly WINDOWS_EXPECTED_DESKTOP=Default
readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock
readonly VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/post-release-acceptance.sock
readonly DESKFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock
readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/home/wilf/.local/state/viewflow/post-release-acceptance
readonly VIEWFLOW_QUIESCE_RECEIPT=/run/user/1000/viewflow/deploy-quiesced.json
readonly VIEWFLOW_QUIESCE_ARM=/run/user/1000/viewflow/deploy-quiesce-arm.json
readonly VIEWFLOW_CERT=/home/wilf/.local/share/viewflow/identity/peer.pem
readonly VIEWFLOW_KEY=/home/wilf/.local/share/viewflow/identity/peer.key
readonly VIEWFLOW_CA=/home/wilf/.local/share/viewflow/identity/ca.pem
readonly DESKFLOW_SCREEN=WindowsVM
readonly DESKFLOW_SOURCE=00000000000000000000000000000101
readonly REQUIRED_VIEWFLOW_PROTOCOL=2.1
readonly REQUIRED_DESKFLOW_UPSTREAM_HEAD=760e3b99b00053647a96b405276bf614bd860075
readonly DEFAULT_MARKER_MAX_AGE_SECONDS=300
readonly READINESS_TIMEOUT_SECONDS=30

viewflow_candidate=
viewflow_expected_sha=
deployment_marker_tool_candidate=
deployment_marker_tool_expected_sha=
deskflow_candidate=
deskflow_expected_sha=
deskflow_core_candidate=
deskflow_core_expected_sha=
deskflow_provenance_manifest=
deskflow_provenance_expected_sha=
viewflow_unit_candidate=
viewflow_unit_expected_sha=
deskflow_dropin_candidate=
deskflow_dropin_expected_sha=
quiesced_marker=
daemon_exit_evidence=
daemon_exit_observation=
bootstrap_linux_evidence=
bootstrap_windows_force_receipt=
bootstrap_windows_install_receipt=
windows_viewflow_expected_sha=
windows_wrapper_expected_sha=
windows_task_xml_expected_sha=
windows_expected_user_sid=
operation_id=
marker_max_age_seconds=$DEFAULT_MARKER_MAX_AGE_SECONDS

backup_dir=
old_viewflow_sha=
old_deployment_marker_tool_sha=
old_deskflow_sha=
old_deskflow_core_sha=
old_viewflow_unit_sha=
old_deskflow_dropin_sha=
transaction_started=0
quiesced_marker_preflight_identity=
quiesced_marker_preflight_sha=
daemon_exit_evidence_preflight_identity=
daemon_exit_evidence_preflight_sha=
daemon_exit_observation_preflight_identity=
daemon_exit_observation_preflight_sha=
daemon_exit_observation_expected_name=
bootstrap_linux_preflight_identity=
bootstrap_linux_preflight_sha=
bootstrap_force_preflight_identity=
bootstrap_force_preflight_sha=
bootstrap_install_preflight_identity=
bootstrap_install_preflight_sha=
deskflow_provenance_preflight_identity=
deskflow_provenance_preflight_sha=
quarantine_marker_preflight_identity=
quarantine_marker_preflight_sha=
deployment_quarantine_marker_preflight_identity=
deployment_quarantine_marker_preflight_sha=

usage() {
    cat <<'EOF'
Usage:
  install-viewflow-deskflow.sh \
    --viewflow-candidate /absolute/path/viewflowd \
    --viewflow-sha256 <64 hex chars> \
    --deployment-marker-candidate /absolute/path/viewflow-deployment-marker \
    --deployment-marker-sha256 <64 hex chars> \
    --deskflow-candidate /absolute/path/deskflow \
    --deskflow-sha256 <64 hex chars> \
    --deskflow-core-candidate /absolute/path/deskflow-core \
    --deskflow-core-sha256 <64 hex chars> \
    --deskflow-provenance-manifest /absolute/path/deskflow-provenance.json \
    --deskflow-provenance-sha256 <64 hex chars> \
    --viewflow-unit-candidate /absolute/path/viewflow-peer.service \
    --viewflow-unit-sha256 <64 hex chars> \
    --deskflow-dropin-candidate /absolute/path/deskflow-viewflow.conf \
    --deskflow-dropin-sha256 <64 hex chars> \
    --operation-id <same unique ID passed to arm-quiesce> \
    --quiesced-marker /absolute/path/viewflow-input-quiesced.json \
    --daemon-exit-evidence /absolute/path/viewflow-daemon-exited.json \
    --daemon-exit-observation /absolute/path/viewflow-daemon-exit-observation.json \
    [--marker-max-age-seconds 300]

Normal updates consume only the schema-v4 receipt emitted by the armed
Viewflow daemon. The unsafe one-shot v1.3 bootstrap options are rejected.
Use bootstrap-stage-viewflow.sh followed by
bootstrap-finalize-viewflow-deskflow.sh for the one-time two-phase upgrade.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

require_value() {
    local option=$1
    local value=${2-}
    [[ -n $value ]] || die "$option requires a value"
}

while (($#)); do
    case $1 in
        --viewflow-candidate)
            require_value "$1" "${2-}"
            viewflow_candidate=$2
            shift 2
            ;;
        --viewflow-sha256)
            require_value "$1" "${2-}"
            viewflow_expected_sha=${2,,}
            shift 2
            ;;
        --deployment-marker-candidate)
            require_value "$1" "${2-}"
            deployment_marker_tool_candidate=$2
            shift 2
            ;;
        --deployment-marker-sha256)
            require_value "$1" "${2-}"
            deployment_marker_tool_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-candidate)
            require_value "$1" "${2-}"
            deskflow_candidate=$2
            shift 2
            ;;
        --deskflow-sha256)
            require_value "$1" "${2-}"
            deskflow_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-core-candidate)
            require_value "$1" "${2-}"
            deskflow_core_candidate=$2
            shift 2
            ;;
        --deskflow-core-sha256)
            require_value "$1" "${2-}"
            deskflow_core_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-provenance-manifest)
            require_value "$1" "${2-}"
            deskflow_provenance_manifest=$2
            shift 2
            ;;
        --deskflow-provenance-sha256)
            require_value "$1" "${2-}"
            deskflow_provenance_expected_sha=${2,,}
            shift 2
            ;;
        --viewflow-unit-candidate)
            require_value "$1" "${2-}"
            viewflow_unit_candidate=$2
            shift 2
            ;;
        --viewflow-unit-sha256)
            require_value "$1" "${2-}"
            viewflow_unit_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-dropin-candidate)
            require_value "$1" "${2-}"
            deskflow_dropin_candidate=$2
            shift 2
            ;;
        --deskflow-dropin-sha256)
            require_value "$1" "${2-}"
            deskflow_dropin_expected_sha=${2,,}
            shift 2
            ;;
        --quiesced-marker)
            require_value "$1" "${2-}"
            quiesced_marker=$2
            shift 2
            ;;
        --daemon-exit-evidence)
            require_value "$1" "${2-}"
            daemon_exit_evidence=$2
            shift 2
            ;;
        --daemon-exit-observation)
            require_value "$1" "${2-}"
            daemon_exit_observation=$2
            shift 2
            ;;
        --bootstrap-linux-evidence)
            require_value "$1" "${2-}"
            bootstrap_linux_evidence=$2
            shift 2
            ;;
        --bootstrap-windows-force-receipt)
            require_value "$1" "${2-}"
            bootstrap_windows_force_receipt=$2
            shift 2
            ;;
        --bootstrap-windows-install-receipt)
            require_value "$1" "${2-}"
            bootstrap_windows_install_receipt=$2
            shift 2
            ;;
        --windows-viewflow-sha256)
            require_value "$1" "${2-}"
            windows_viewflow_expected_sha=${2,,}
            shift 2
            ;;
        --windows-wrapper-sha256)
            require_value "$1" "${2-}"
            windows_wrapper_expected_sha=${2,,}
            shift 2
            ;;
        --windows-task-xml-sha256)
            require_value "$1" "${2-}"
            windows_task_xml_expected_sha=${2,,}
            shift 2
            ;;
        --windows-user-sid)
            require_value "$1" "${2-}"
            windows_expected_user_sid=$2
            shift 2
            ;;
        --operation-id)
            require_value "$1" "${2-}"
            operation_id=$2
            shift 2
            ;;
        --marker-max-age-seconds)
            require_value "$1" "${2-}"
            marker_max_age_seconds=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
done

if [[ -n $bootstrap_linux_evidence || -n $bootstrap_windows_force_receipt ||
      -n $bootstrap_windows_install_receipt || -n $windows_viewflow_expected_sha ||
      -n $windows_wrapper_expected_sha || -n $windows_task_xml_expected_sha ||
      -n $windows_expected_user_sid ]]; then
    die 'single-stage v1.3 bootstrap is disabled; use bootstrap-stage-viewflow.sh then bootstrap-finalize-viewflow-deskflow.sh'
fi

sha256() {
    sha256sum -- "$1" | awk '{print tolower($1)}'
}

require_sha256() {
    local label=$1
    local value=$2
    [[ $value =~ ^[0-9a-f]{64}$ ]] || die "$label must be exactly 64 hexadecimal characters"
}

require_absolute_regular_file() {
    local label=$1
    local path=$2
    [[ $path == /* ]] || die "$label must be an absolute path"
    [[ -f $path && ! -L $path ]] || die "$label must be a regular, non-symlink file: $path"
}

assert_hash() {
    local label=$1
    local path=$2
    local expected=$3
    local actual
    actual=$(sha256 "$path")
    [[ $actual == "$expected" ]] || die "$label SHA-256 mismatch: expected $expected, got $actual"
}

assert_owned_not_writable_by_others() {
    local label=$1
    local path=$2
    local owner mode
    owner=$(stat -c '%u' -- "$path")
    mode=$(stat -c '%a' -- "$path")
    [[ $owner == "$EXPECTED_UID" ]] || die "$label must be owned by uid $EXPECTED_UID"
    (( (8#$mode & 8#022) == 0 )) || die "$label must not be group- or world-writable"
}

assert_executable_artifact_metadata() {
    local label=$1 path=$2 owner mode links
    require_absolute_regular_file "$label" "$path"
    read -r owner mode links < <(stat -c '%u %a %h' -- "$path")
    [[ $owner == "$EXPECTED_UID" && $mode == 755 && $links == 1 ]] ||
        die "$label must be owned by uid 1000 with mode 0755 and link count 1"
}

assert_quarantine_storage() {
    local parent_owner parent_mode marker_owner marker_mode marker_links marker_size
    local deployment_owner deployment_mode deployment_links deployment_size
    local marker_magic deployment_magic
    [[ -d $DESKFLOW_QUARANTINE_PARENT && ! -L $DESKFLOW_QUARANTINE_PARENT ]] ||
        die 'Deskflow quarantine parent must be a real directory'
    read -r parent_owner parent_mode < <(
        stat -c '%u %a' -- "$DESKFLOW_QUARANTINE_PARENT"
    )
    [[ $parent_owner == "$EXPECTED_UID" && $parent_mode == 700 ]] ||
        die 'Deskflow quarantine parent must be owned by uid 1000 with mode 0700'

    [[ -e $DESKFLOW_QUARANTINE_MARKER || -L $DESKFLOW_QUARANTINE_MARKER ]] ||
        die 'Deskflow quarantine marker must exist before deployment preflight'
    [[ -f $DESKFLOW_QUARANTINE_MARKER && ! -L $DESKFLOW_QUARANTINE_MARKER ]] ||
        die 'Deskflow quarantine marker must be a regular non-symlink file'
    read -r marker_owner marker_mode marker_links marker_size < <(
        stat -c '%u %a %h %s' -- "$DESKFLOW_QUARANTINE_MARKER"
    )
    [[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&
       $marker_links == 1 && $marker_size == 152 ]] ||
        die 'Deskflow runtime quarantine marker must be uid 1000, mode 0600, link count 1, and 152 bytes'
    marker_magic=$(LC_ALL=C head -c 8 -- "$DESKFLOW_QUARANTINE_MARKER")
    [[ $marker_magic == "$DESKFLOW_QUARANTINE_MAGIC" ]] ||
        die 'Deskflow runtime quarantine marker magic must be VFQST002'

    [[ -e $DEPLOYMENT_QUARANTINE_MARKER || -L $DEPLOYMENT_QUARANTINE_MARKER ]] ||
        die 'Viewflow deployment quarantine marker must exist before deployment preflight'
    [[ -f $DEPLOYMENT_QUARANTINE_MARKER && ! -L $DEPLOYMENT_QUARANTINE_MARKER ]] ||
        die 'Viewflow deployment quarantine marker must be a regular non-symlink file'
    read -r deployment_owner deployment_mode deployment_links deployment_size < <(
        stat -c '%u %a %h %s' -- "$DEPLOYMENT_QUARANTINE_MARKER"
    )
    [[ $deployment_owner == "$EXPECTED_UID" && $deployment_mode == 600 &&
       $deployment_links == 1 && $deployment_size == 256 ]] ||
        die 'Viewflow deployment quarantine marker must be uid 1000, mode 0600, link count 1, and 256 bytes'
    deployment_magic=$(LC_ALL=C head -c 8 -- "$DEPLOYMENT_QUARANTINE_MARKER")
    [[ $deployment_magic == "$DEPLOYMENT_QUARANTINE_MAGIC" ]] ||
        die 'Viewflow deployment quarantine marker magic must be VFDQT001'
}

# The post-release acceptance journal is runtime-owned evidence.  It is not an
# install artifact: the installer never backs it up, replaces it, or deletes
# it.  Creating its empty parent is safe because the parent state directory is
# already owner-only and non-symlink validated above.
assert_acceptance_state_dir() {
    local owner mode
    [[ -d $VIEWFLOW_ACCEPTANCE_STATE_DIR && ! -L $VIEWFLOW_ACCEPTANCE_STATE_DIR ]] ||
        die 'post-release acceptance state directory must be a real directory'
    read -r owner mode < <(stat -c '%u %a' -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR")
    [[ $owner == "$EXPECTED_UID" && $mode == 700 ]] ||
        die 'post-release acceptance state directory must be owned by uid 1000 with mode 0700'
}

ensure_acceptance_state_dir() {
    [[ ! -L $VIEWFLOW_ACCEPTANCE_STATE_DIR ]] ||
        die 'post-release acceptance state directory must not be a symlink'
    if [[ ! -e $VIEWFLOW_ACCEPTANCE_STATE_DIR ]]; then
        mkdir -m 0700 -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR" 2>/dev/null || true
    fi
    assert_acceptance_state_dir
}

assert_deployment_marker_tool_stopped() {
    [[ -z $(exact_executable_pids "$DEPLOYMENT_MARKER_TOOL_INSTALLED") ]] ||
        die 'viewflow-deployment-marker must not be running during Linux deployment'
}

assert_quarantine_dropin_contract() {
    local path=$1 label=$2
    [[ $(grep -Fc 'Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=' "$path") == 1 &&
       $(grep -Fxc "$DESKFLOW_QUARANTINE_ENV_LINE" "$path") == 1 &&
       $(grep -Fc 'Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=' "$path") == 1 &&
       $(grep -Fxc "$DEPLOYMENT_QUARANTINE_ENV_LINE" "$path") == 1 &&
       $(grep -Fc 'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=' "$path") == 1 &&
       $(grep -Fxc "Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET" "$path") == 1 ]] ||
        die "$label must configure both fixed quarantine markers and the Deskflow acceptance socket exactly once"
}

assert_viewflow_unit_acceptance_contract() {
    local path=$1 label=$2
    [[ $(grep -Fc -- '--acceptance-socket' "$path") == 1 &&
       $(grep -Fc -- '--acceptance-state-dir' "$path") == 1 ]] ||
        die "$label must configure the acceptance options exactly once"
    grep -Fqx -- "ExecStart=/home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119 --cert /home/wilf/.local/share/viewflow/identity/peer.pem --key /home/wilf/.local/share/viewflow/identity/peer.key --ca /home/wilf/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002 --quiesce-proof %t/viewflow/deploy-quiesced.json --quiesce-arm-file %t/viewflow/deploy-quiesce-arm.json --acceptance-socket %t/viewflow/post-release-acceptance.sock --acceptance-state-dir $VIEWFLOW_ACCEPTANCE_STATE_DIR" "$path" ||
        die "$label must configure the exact post-release acceptance socket and state directory"
}

exact_executable_pids() {
    local expected=$1
    local proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
}

process_has_argument() {
    local pid=$1
    local expected=$2
    grep -Fzx -- "$expected" "/proc/$pid/cmdline"
}

process_has_environment() {
    local pid=$1
    local expected=$2
    grep -Fzx -- "$expected" "/proc/$pid/environ"
}

is_descendant_of() {
    local child=$1
    local ancestor=$2
    local parent
    while ((child > 1)); do
        [[ $child == "$ancestor" ]] && return 0
        parent=$(awk '/^PPid:/ { print $2 }' "/proc/$child/status" 2>/dev/null || true)
        [[ $parent =~ ^[0-9]+$ ]] || return 1
        child=$parent
    done
    return 1
}

unit_main_pid() {
    systemctl --user show --property MainPID --value "$1"
}

assert_loaded_unit_configuration() {
    local fragment dropins
    fragment=$(systemctl --user show --property FragmentPath --value "$VIEWFLOW_UNIT")
    [[ $(readlink -f -- "$fragment") == "$VIEWFLOW_UNIT_INSTALLED" ]] ||
        die 'systemd did not load the fixed Viewflow unit path'
    dropins=$(systemctl --user show --property DropInPaths --value "$DESKFLOW_UNIT")
    [[ " $dropins " == *" $DESKFLOW_DROPIN_INSTALLED "* ]] ||
        die 'systemd did not load the fixed Deskflow drop-in path'
}

wait_unit_stopped() {
    local unit=$1
    shift
    local deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
    local active pid path all_gone
    while ((SECONDS < deadline)); do
        active=$(systemctl --user is-active "$unit" 2>/dev/null || true)
        pid=$(unit_main_pid "$unit" 2>/dev/null || true)
        all_gone=1
        for path in "$@"; do
            [[ -z $(exact_executable_pids "$path") ]] || all_gone=0
        done
        if [[ $active != active && ${pid:-0} == 0 && $all_gone == 1 ]]; then
            return 0
        fi
        sleep 0.1
    done
    die "$unit or one of its exact executables did not stop"
}

stop_unit_and_wait() {
    local unit=$1
    shift
    systemctl --user stop "$unit"
    wait_unit_stopped "$unit" "$@"
}

assert_socket_owned_by_pid() {
    local protocol=$1
    local port=$2
    local pid=$3
    local output
    case $protocol in
        udp) output=$(ss -H -lunp "sport = :$port") ;;
        tcp) output=$(ss -H -ltnp "sport = :$port") ;;
        *) die "unsupported socket protocol: $protocol" ;;
    esac
    grep -Fq "pid=$pid," <<<"$output" ||
        die "pid $pid does not own the expected $protocol listener on port $port"
}

assert_no_listener() {
    local protocol=$1 port=$2 output
    case $protocol in
        udp) output=$(ss -H -lun "sport = :$port") ;;
        tcp) output=$(ss -H -ltn "sport = :$port") ;;
        *) die "unsupported socket protocol: $protocol" ;;
    esac
    [[ -z $output ]] || die "unexpected $protocol listener remains on port $port"
}

assert_sidecar_socket() {
    [[ -S $VIEWFLOW_SIDECAR ]] || die "Viewflow sidecar socket is not ready: $VIEWFLOW_SIDECAR"
    [[ $(stat -c '%u' -- "$VIEWFLOW_SIDECAR") == "$EXPECTED_UID" ]] ||
        die 'Viewflow sidecar socket owner is unexpected'
    [[ $(stat -c '%a' -- "$VIEWFLOW_SIDECAR") == 600 ]] ||
        die 'Viewflow sidecar socket must have mode 0600'
}

assert_owner_only_socket() {
    local label=$1 path=$2
    [[ -S $path && ! -L $path ]] || die "$label is not ready: $path"
    [[ $(stat -c '%u' -- "$path") == "$EXPECTED_UID" ]] ||
        die "$label owner is unexpected"
    [[ $(stat -c '%a' -- "$path") == 600 ]] ||
        die "$label must have mode 0600"
}

assert_acceptance_runtime_sockets_absent() {
    [[ ! -e $VIEWFLOW_ACCEPTANCE_SOCKET && ! -L $VIEWFLOW_ACCEPTANCE_SOCKET ]] ||
        die 'Viewflow post-release acceptance socket remains after shutdown'
    [[ ! -e $DESKFLOW_ACCEPTANCE_SOCKET && ! -L $DESKFLOW_ACCEPTANCE_SOCKET ]] ||
        die 'Deskflow post-release acceptance socket remains after shutdown'
}

invocation_has_protocol_log() {
    local invocation_id=$1
    local protocol=$2
    local output
    output=$(journalctl --user --quiet --output cat \
        "_SYSTEMD_INVOCATION_ID=$invocation_id" 2>/dev/null || true)
    if [[ $protocol == any ]]; then
        grep -Eq 'viewflowd protocol [0-9]+\.[0-9]+ serving mTLS QUIC' <<<"$output"
    else
        grep -Fq "viewflowd protocol $protocol serving mTLS QUIC" <<<"$output"
    fi
}

invocation_has_authenticated_health() {
    local invocation_id=$1 output
    output=$(journalctl --user --quiet --output cat \
        "_SYSTEMD_INVOCATION_ID=$invocation_id" 2>/dev/null || true)
    grep -Fq 'viewflowd server authenticated peer ' <<<"$output" &&
        grep -Eq 'viewflowd server peer .* probe=[0-9]+ responder_us=[0-9]+' <<<"$output"
}

assert_viewflow_ready() {
    local expected_hash=$1
    local expected_protocol=$2
    local deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
    local pid exe invocation_id exact_pids
    while ((SECONDS < deadline)); do
        if [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) == active ]]; then
            pid=$(unit_main_pid "$VIEWFLOW_UNIT" 2>/dev/null || true)
            if [[ $pid =~ ^[1-9][0-9]*$ && -e /proc/$pid/exe ]]; then
                exe=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
                exact_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
                invocation_id=$(systemctl --user show --property InvocationID --value \
                    "$VIEWFLOW_UNIT" 2>/dev/null || true)
                if [[ $exe == "$VIEWFLOW_INSTALLED" && $exact_pids == "$pid" ]] &&
                    assert_hash 'running Viewflow' "/proc/$pid/exe" "$expected_hash" &&
                    process_has_argument "$pid" serve &&
                    process_has_argument "$pid" --bind &&
                    process_has_argument "$pid" "$VIEWFLOW_BIND" &&
                    process_has_argument "$pid" --device-id &&
                    process_has_argument "$pid" "$VIEWFLOW_DEVICE" &&
                    process_has_argument "$pid" --sidecar-socket &&
                    process_has_argument "$pid" "$VIEWFLOW_SIDECAR" &&
                    process_has_argument "$pid" --sidecar-peer &&
                    process_has_argument "$pid" "$VIEWFLOW_PEER" &&
                    process_has_argument "$pid" --sidecar-target-device &&
                    process_has_argument "$pid" "$VIEWFLOW_TARGET" &&
                    process_has_argument "$pid" --quiesce-proof &&
                    process_has_argument "$pid" "$VIEWFLOW_QUIESCE_RECEIPT" &&
                    process_has_argument "$pid" --quiesce-arm-file &&
                    process_has_argument "$pid" "$VIEWFLOW_QUIESCE_ARM" &&
                    process_has_argument "$pid" --acceptance-socket &&
                    process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_SOCKET" &&
                    process_has_argument "$pid" --acceptance-state-dir &&
                    process_has_argument "$pid" "$VIEWFLOW_ACCEPTANCE_STATE_DIR" &&
                    [[ $invocation_id =~ ^[0-9a-f]{32}$ ]] &&
                    assert_sidecar_socket &&
                    assert_owner_only_socket 'Viewflow post-release acceptance socket' "$VIEWFLOW_ACCEPTANCE_SOCKET" &&
                    assert_acceptance_state_dir &&
                    assert_socket_owned_by_pid udp "$VIEWFLOW_PORT" "$pid" &&
                    invocation_has_protocol_log "$invocation_id" "$expected_protocol" &&
                    invocation_has_authenticated_health "$invocation_id"; then
                    return 0
                fi
            fi
        fi
        sleep 0.1
    done
    die "$VIEWFLOW_UNIT did not become ready with protocol $expected_protocol and the expected runtime identity"
}

find_deskflow_core_pid() {
    local deskflow_pid=$1
    local candidate
    while IFS= read -r candidate; do
        if is_descendant_of "$candidate" "$deskflow_pid"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    return 1
}

assert_deskflow_ready() {
    local expected_deskflow_hash=$1
    local expected_core_hash=$2
    local deadline=$((SECONDS + READINESS_TIMEOUT_SECONDS))
    local pid exe core_pid deskflow_pids core_pids
    while ((SECONDS < deadline)); do
        if [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) == active ]]; then
            pid=$(unit_main_pid "$DESKFLOW_UNIT" 2>/dev/null || true)
            if [[ $pid =~ ^[1-9][0-9]*$ && -e /proc/$pid/exe ]]; then
                exe=$(readlink -f -- "/proc/$pid/exe" 2>/dev/null || true)
                core_pid=$(find_deskflow_core_pid "$pid" 2>/dev/null || true)
                deskflow_pids=$(exact_executable_pids "$DESKFLOW_INSTALLED")
                core_pids=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
                if [[ $exe == "$DESKFLOW_INSTALLED" && $deskflow_pids == "$pid" &&
                      $core_pid =~ ^[1-9][0-9]*$ && $core_pids == "$core_pid" ]] &&
                    assert_hash 'running Deskflow' "/proc/$pid/exe" "$expected_deskflow_hash" &&
                    assert_hash 'running deskflow-core' "/proc/$core_pid/exe" "$expected_core_hash" &&
                    process_has_environment "$pid" \
                        "DESKFLOW_VIEWFLOW_SIDECAR_SOCKET=$VIEWFLOW_SIDECAR" &&
                    process_has_environment "$pid" "DESKFLOW_VIEWFLOW_SCREEN=$DESKFLOW_SCREEN" &&
                    process_has_environment "$pid" "DESKFLOW_VIEWFLOW_SOURCE_DISPLAY=$DESKFLOW_SOURCE" &&
                    process_has_environment "$pid" "DESKFLOW_VIEWFLOW_ROUTE_TO=$VIEWFLOW_TARGET" &&
                    process_has_environment "$pid" \
                        "DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_MARKER" &&
                    process_has_environment "$core_pid" \
                        "DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=$DESKFLOW_QUARANTINE_MARKER" &&
                    process_has_environment "$pid" \
                        "DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_QUARANTINE_MARKER" &&
                    process_has_environment "$core_pid" \
                        "DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=$DEPLOYMENT_QUARANTINE_MARKER" &&
                    process_has_environment "$pid" \
                        "DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET" &&
                    process_has_environment "$core_pid" \
                        "DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET" &&
                    assert_owner_only_socket 'Deskflow post-release acceptance socket' "$DESKFLOW_ACCEPTANCE_SOCKET" &&
                    assert_socket_owned_by_pid tcp "$DESKFLOW_PORT" "$core_pid"; then
                    return 0
                fi
            fi
        fi
        sleep 0.1
    done
    die "$DESKFLOW_UNIT did not become ready with the expected GUI, core, route environment, and listener"
}

atomic_install() {
    local source=$1
    local destination=$2
    local mode=$3
    local directory temporary
    directory=$(dirname -- "$destination")
    temporary=$(mktemp --tmpdir="$directory" ".$(basename -- "$destination").new.XXXXXX")
    if ! install -m "$mode" -- "$source" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -fT -- "$temporary" "$destination"
}

assert_evidence_permissions() {
    local label=$1 path=$2
    require_absolute_regular_file "$label" "$path"
    assert_owned_not_writable_by_others "$label" "$path"
    [[ $(stat -c '%a' -- "$path") == 600 ]] || die "$label must have mode 0600"
}

assert_strict_json_document() {
    local label=$1 path=$2
    python3 - "$label" "$path" <<'PY'
import json
import sys


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


label, path = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as evidence:
        value = json.load(evidence, object_pairs_hook=reject_duplicate_keys)
    if not isinstance(value, dict):
        raise ValueError("top-level JSON value is not an object")
except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
    print(f"error: {label} is not one strict JSON object: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

elf_build_id() {
    local path=$1 build_id
    build_id=$(readelf -n -- "$path" 2>/dev/null |
        awk '/Build ID:/ {print tolower($3); found=1; exit} END {if (!found) exit 1}') ||
        die "ELF artifact has no GNU build ID: $path"
    [[ $build_id =~ ^[0-9a-f]+$ ]] || die "invalid ELF build ID: $path"
    printf '%s\n' "$build_id"
}

validate_deskflow_provenance_manifest() (
    local path=$1 deskflow_size deskflow_build_id core_size core_build_id
    local validation_dir validation_copy
    # shellcheck disable=SC2329 # invoked indirectly by EXIT trap
    cleanup_provenance_validation() {
        local status=$?
        trap - EXIT HUP INT TERM
        rm -rf -- "$validation_dir"
        exit "$status"
    }
    validation_dir=$(mktemp -d "${TMPDIR:-/tmp}/viewflow-provenance-validate.XXXXXXXX")
    chmod 0700 "$validation_dir"
    trap cleanup_provenance_validation EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    validation_copy=$validation_dir/manifest.json
    install -m 0400 -- "$path" "$validation_copy"
    [[ $(sha256 "$validation_copy") == "$deskflow_provenance_expected_sha" ]] ||
        die 'Deskflow provenance manifest changed while it was staged for validation'
    assert_strict_json_document 'Deskflow provenance manifest' "$validation_copy"
    jq -e \
        --arg upstream "$REQUIRED_DESKFLOW_UPSTREAM_HEAD" \
        --arg deskflow_sha "$deskflow_expected_sha" \
        --arg core_sha "$deskflow_core_expected_sha" '
        def sha256: type == "string" and test("^[0-9a-f]{64}$");
        def build_id: type == "string" and test("^[0-9a-f]+$");
        def uint53: type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
        def absolute: type == "string" and startswith("/");
        def source_path: type == "string" and test("^[A-Za-z0-9._/@+=,:~-]+$") and
          (startswith("/") | not) and . != "." and . != ".." and
          (startswith("../") | not) and (contains("/../") | not) and
          (endswith("/..") | not);
        def tracked_entry:
          (keys == ["path", "sha256", "size_bytes", "status"]) and
          (.path | source_path) and .status == "M" and
          (.sha256 | sha256) and (.size_bytes | uint53);
        def untracked_entry:
          (keys == ["path", "sha256", "size_bytes"]) and
          (.path | source_path) and (.sha256 | sha256) and (.size_bytes | uint53);
        def critical_entry:
          (keys == ["path", "sha256", "size_bytes", "status"]) and
          (.path | source_path) and (.status == "M" or .status == "U") and
          (.sha256 | sha256) and (.size_bytes | uint53);
        def artifact:
          (keys == ["elf_build_id", "sha256", "size_bytes", "source_path"]) and
          (.source_path | absolute) and (.sha256 | sha256) and
          (.size_bytes | uint53 and . > 0) and (.elf_build_id | build_id);
        def live_acceptance:
          (keys == ["arm_magic", "core_query", "enabled", "peer_auth", "protocol_version", "receipt_magic", "receipt_size", "sidecar_protocol_version", "socket_kind"]) and
          .enabled == true and .socket_kind == "af_unix" and
          .peer_auth == "so_peercred_same_uid" and .arm_magic == "VFARM001" and
          .receipt_magic == "VFRCP001" and .receipt_size == 568 and
          .protocol_version == "2.1" and .sidecar_protocol_version == 3 and
          .core_query == true;
        (keys == ["artifacts", "build", "generated_at_utc", "kind", "protocol_version", "schema_version", "sidecar_protocol_version", "source", "upstream"]) and
        .schema_version == 1 and .kind == "viewflow-deskflow-linux-provenance" and
        .protocol_version == "2.1" and .sidecar_protocol_version == 3 and
        (.upstream | keys == ["commit", "detached_head"]) and
        .upstream.commit == $upstream and .upstream.detached_head == true and
        (.source | keys == ["critical_files", "modified_tracked_files", "root", "tracked_patch", "untracked_source_files"]) and
        (.source.root | absolute) and
        (.source.tracked_patch | keys == ["sha256", "size_bytes"]) and
        (.source.tracked_patch.sha256 | sha256) and
        (.source.tracked_patch.size_bytes | uint53 and . > 0) and
        (.source.modified_tracked_files | type == "array" and length == 8 and all(.[]; tracked_entry)) and
        (.source.modified_tracked_files | map(.path)) == [
          "src/apps/deskflow-core/deskflow-core.cpp",
          "src/lib/arch/unix/ArchMultithreadPosix.cpp",
          "src/lib/platform/PortalInputCapture.cpp",
          "src/lib/platform/PortalInputCapture.h",
          "src/lib/server/CMakeLists.txt",
          "src/lib/server/Server.cpp",
          "src/lib/server/Server.h",
          "src/unittests/server/CMakeLists.txt"
        ] and
        (.source.untracked_source_files | type == "array" and length == 4 and all(.[]; untracked_entry)) and
        (.source.untracked_source_files | map(.path)) == [
          "src/lib/server/ViewflowSidecarClient.cpp",
          "src/lib/server/ViewflowSidecarClient.h",
          "src/unittests/server/ViewflowSidecarClientTests.cpp",
          "src/unittests/server/ViewflowSidecarClientTests.h"
        ] and
        (.source.critical_files | type == "array" and length == 12 and all(.[]; critical_entry)) and
        .source.critical_files ==
          (.source.modified_tracked_files +
           (.source.untracked_source_files | map(. + {status: "U"}))) and
        (.build | keys == ["build_type", "cmake", "compilers", "directory", "generator", "live_acceptance", "ninja"]) and
        (.build.directory | absolute) and .build.generator == "Ninja" and
        (.build.build_type | type == "string" and length > 0) and
        (.build.cmake | keys == ["cache_sha256", "cache_size_bytes", "executable", "executable_sha256", "verify_globs_sha256", "verify_globs_size_bytes", "version"]) and
        (.build.cmake.executable | absolute) and (.build.cmake.version | type == "string" and length > 0) and
        (.build.cmake.executable_sha256 | sha256) and (.build.cmake.cache_sha256 | sha256) and
        (.build.cmake.cache_size_bytes | uint53 and . > 0) and
        (.build.cmake.verify_globs_sha256 | sha256) and
        (.build.cmake.verify_globs_size_bytes | uint53 and . > 0) and
        (.build.ninja | keys == ["build_file_sha256", "build_file_size_bytes", "executable", "executable_sha256", "pending_rebuild", "rules_file_sha256", "rules_file_size_bytes", "version"]) and
        (.build.ninja.executable | absolute) and (.build.ninja.version | type == "string" and length > 0) and
        (.build.ninja.executable_sha256 | sha256) and (.build.ninja.build_file_sha256 | sha256) and
        (.build.ninja.build_file_size_bytes | uint53 and . > 0) and
        (.build.ninja.rules_file_sha256 | sha256) and
        (.build.ninja.rules_file_size_bytes | uint53 and . > 0) and
        .build.ninja.pending_rebuild == false and
        (.build.live_acceptance | live_acceptance) and
        (.build.compilers | keys == ["c", "cxx"]) and
        all([.build.compilers.c, .build.compilers.cxx][];
          keys == ["executable_sha256", "path", "version"] and
          (.path | absolute) and (.version | type == "string" and length > 0) and
          (.executable_sha256 | sha256)) and
        (.artifacts | keys == ["deskflow", "deskflow_core"]) and
        (.artifacts.deskflow | artifact) and (.artifacts.deskflow_core | artifact) and
        .artifacts.deskflow.source_path == (.build.directory + "/bin/deskflow") and
        .artifacts.deskflow_core.source_path == (.build.directory + "/bin/deskflow-core") and
        .artifacts.deskflow.sha256 == $deskflow_sha and
        .artifacts.deskflow_core.sha256 == $core_sha and
        (.generated_at_utc | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        ' "$validation_copy" >/dev/null ||
        die 'Deskflow provenance manifest schema or embedded artifact identity is invalid'

    deskflow_size=$(jq -er '.artifacts.deskflow.size_bytes' "$validation_copy")
    deskflow_build_id=$(jq -er '.artifacts.deskflow.elf_build_id' "$validation_copy")
    core_size=$(jq -er '.artifacts.deskflow_core.size_bytes' "$validation_copy")
    core_build_id=$(jq -er '.artifacts.deskflow_core.elf_build_id' "$validation_copy")
    [[ $(stat -c '%s' -- "$deskflow_candidate") == "$deskflow_size" ]] ||
        die 'Deskflow candidate size does not match provenance manifest'
    [[ $(elf_build_id "$deskflow_candidate") == "$deskflow_build_id" ]] ||
        die 'Deskflow candidate build ID does not match provenance manifest'
    [[ $(stat -c '%s' -- "$deskflow_core_candidate") == "$core_size" ]] ||
        die 'deskflow-core candidate size does not match provenance manifest'
    [[ $(elf_build_id "$deskflow_core_candidate") == "$core_build_id" ]] ||
        die 'deskflow-core candidate build ID does not match provenance manifest'
    [[ $(sha256 "$validation_copy") == "$deskflow_provenance_expected_sha" ]] ||
        die 'staged Deskflow provenance manifest changed during validation'
)

evidence_identity() {
    stat -c '%d:%i' -- "$1"
}

assert_evidence_unchanged() {
    local label=$1 path=$2 expected_identity=$3 expected_sha=$4
    assert_evidence_permissions "$label" "$path"
    [[ $(evidence_identity "$path") == "$expected_identity" ]] ||
        die "$label file identity changed after preflight"
    assert_hash "$label" "$path" "$expected_sha"
}

freeze_quarantine_storage() {
    assert_quarantine_storage
    quarantine_marker_preflight_identity=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")
    quarantine_marker_preflight_sha=$(sha256 "$DESKFLOW_QUARANTINE_MARKER")
    deployment_quarantine_marker_preflight_identity=$(
        evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER"
    )
    deployment_quarantine_marker_preflight_sha=$(sha256 "$DEPLOYMENT_QUARANTINE_MARKER")
    assert_quarantine_storage_unchanged
}

assert_quarantine_storage_unchanged() {
    local identity_before identity_after deployment_identity_before deployment_identity_after
    [[ -n $quarantine_marker_preflight_identity &&
       $quarantine_marker_preflight_sha =~ ^[0-9a-f]{64}$ &&
       -n $deployment_quarantine_marker_preflight_identity &&
       $deployment_quarantine_marker_preflight_sha =~ ^[0-9a-f]{64}$ ]] ||
        die 'both quarantine marker identities must be frozen at preflight'
    assert_quarantine_storage
    identity_before=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")
    [[ $identity_before == "$quarantine_marker_preflight_identity" ]] ||
        die 'Deskflow quarantine marker inode changed after preflight'
    assert_hash 'Deskflow quarantine marker' "$DESKFLOW_QUARANTINE_MARKER" \
        "$quarantine_marker_preflight_sha"
    identity_after=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")
    [[ $identity_after == "$identity_before" ]] ||
        die 'Deskflow quarantine marker inode changed while hashing'
    deployment_identity_before=$(evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER")
    [[ $deployment_identity_before == "$deployment_quarantine_marker_preflight_identity" ]] ||
        die 'Viewflow deployment quarantine marker inode changed after preflight'
    assert_hash 'Viewflow deployment quarantine marker' "$DEPLOYMENT_QUARANTINE_MARKER" \
        "$deployment_quarantine_marker_preflight_sha"
    deployment_identity_after=$(evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER")
    [[ $deployment_identity_after == "$deployment_identity_before" ]] ||
        die 'Viewflow deployment quarantine marker inode changed while hashing'
    assert_quarantine_storage
}

assert_evidence_on_backup_filesystem() {
    local label=$1 path=$2
    [[ $(stat -c '%d' -- "$path") == "$(stat -c '%d' -- "$backup_dir")" ]] ||
        die "$label must be on the same filesystem as the transaction backup"
}

assert_fresh_epoch() {
    local label=$1 completed_epoch=$2 now age
    now=$(date -u +%s)
    age=$((now - completed_epoch))
    ((age >= -30 && age <= marker_max_age_seconds)) ||
        die "$label is stale or from the future"
}

utc_completion_epoch() {
    local label=$1 path=$2 completed_utc completed_epoch
    completed_utc=$(jq -er '.completed_at_utc | select(type == "string")' "$path")
    [[ $completed_utc =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$ ]] ||
        die "$label completed_at_utc is not canonical UTC"
    completed_epoch=$(date -u -d "$completed_utc" +%s) ||
        die "$label completed_at_utc is invalid"
    assert_fresh_epoch "$label" "$completed_epoch"
    printf '%s\n' "$completed_epoch"
}

validate_bootstrap_linux_evidence() {
    local path=$1 daemon_pid daemon_start_ticks boot_id daemon_instance_id
    local completed_at_ms completed_epoch transcript_sha
    local invocation_id journal_boot_id journal_json journal_sha journal_summary
    local journal_entries journal_start_cursor journal_start_us startup_cursor startup_us
    local journal_end_cursor journal_end_us startup_count lease_count input_count
    local activation_count cleanup_error_count
    jq -e \
        --arg operation_id "$operation_id" \
        --arg old_viewflow_sha "$old_viewflow_sha" \
        --arg executable "$VIEWFLOW_INSTALLED" \
         'def uint53:
             type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
         def sha256: type == "string" and test("^[0-9a-f]{64}$");
         def hex_digit:
             . as $n | "0123456789abcdef"[$n:$n + 1];
         def hex:
             if . < 16 then hex_digit
             else (((. / 16) | floor | hex) + ((. % 16) | floor | hex_digit))
             end;
         def hex16:
             (hex) as $encoded |
             ("0000000000000000" + $encoded)[-16:];
         (keys == ["completed_at_unix_ms", "daemon", "journal", "operation_id",
                   "post_stop", "pre_stop", "schema_version", "state"]) and
         (.schema_version == 1) and
         (.state == "viewflow-v13-bootstrap-frozen") and
         (.operation_id == $operation_id) and
         (.completed_at_unix_ms | uint53 and . > 0) and
         (.daemon | keys == ["boot_id", "daemon_instance_id", "executable", "pid",
                             "sha256", "start_ticks", "systemd_invocation_id"]) and
         (.daemon.pid | uint53 and . > 0 and . <= 4294967295) and
         (.daemon.start_ticks | uint53 and . > 0) and
         (.daemon.boot_id | type == "string" and
             test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
         (.daemon.daemon_instance_id ==
             (.daemon.boot_id + "-" + (.daemon.pid | tostring) + "-" +
                 (.daemon.start_ticks | tostring))) and
         (.daemon.executable == $executable) and
         (.daemon.sha256 | sha256) and
         (.daemon.sha256 == $old_viewflow_sha) and
         (.daemon.systemd_invocation_id | type == "string" and
             test("^[0-9a-f]{32}$")) and
         (.journal | keys == ["counts", "end_cursor", "end_realtime_timestamp_us",
                              "entry_count", "protocol_startup_cursor",
                              "protocol_startup_realtime_timestamp_us", "query_boot_id",
                              "query_pid", "query_systemd_invocation_id", "slice_sha256",
                              "start_cursor", "start_realtime_timestamp_us"]) and
         (.journal.query_boot_id == (.daemon.boot_id | gsub("-"; ""))) and
         (.journal.query_pid == (.daemon.pid | tostring)) and
         (.journal.query_systemd_invocation_id == .daemon.systemd_invocation_id) and
         (.journal.start_cursor | type == "string" and length > 0) and
         (.journal.protocol_startup_cursor | type == "string" and length > 0) and
         (.journal.end_cursor | type == "string" and length > 0) and
         (.journal.start_realtime_timestamp_us | uint53 and . > 0) and
         (.journal.protocol_startup_realtime_timestamp_us | uint53) and
         (.journal.protocol_startup_realtime_timestamp_us >=
             .journal.start_realtime_timestamp_us) and
         (.journal.end_realtime_timestamp_us | uint53) and
         (.journal.end_realtime_timestamp_us >=
             .journal.protocol_startup_realtime_timestamp_us) and
         (.journal.entry_count | uint53 and . > 0) and
         (.journal.slice_sha256 | sha256) and
         (.journal.counts | keys == ["cleanup_or_release_error", "input_event",
                                    "input_sidecar_activation", "lease_offered",
                                    "protocol_1_3_startup"]) and
         (.journal.counts.protocol_1_3_startup | uint53 and . == 1) and
         (.journal.counts.lease_offered | uint53) and
         (.journal.counts.input_event | uint53) and
         (.journal.counts.input_sidecar_activation | uint53) and
         (.journal.counts.cleanup_or_release_error | uint53) and
         (.journal.counts.protocol_1_3_startup <= .journal.entry_count) and
         (.journal.counts.lease_offered <= .journal.entry_count) and
         (.journal.counts.input_event <= .journal.entry_count) and
         (.journal.counts.input_sidecar_activation <= .journal.entry_count) and
         (.journal.counts.cleanup_or_release_error <= .journal.entry_count) and
         (.pre_stop | keys == ["deskflow_core_exact_process_count",
                               "deskflow_exact_process_count", "deskflow_main_pid",
                               "deskflow_tcp_24800_listener_count",
                               "deskflow_unit_active_state"]) and
         (.pre_stop == {deskflow_unit_active_state: "inactive", deskflow_main_pid: 0,
                        deskflow_exact_process_count: 0,
                        deskflow_core_exact_process_count: 0,
                        deskflow_tcp_24800_listener_count: 0}) and
         (.post_stop | keys == ["command_output_format", "command_output_sha256",
                                "command_outputs", "exact_process_count", "main_pid",
                                "original_daemon_pid_present", "sidecar_socket_present",
                                "udp_44119_listener_count", "unit_active_state"]) and
         (.post_stop.unit_active_state == "inactive") and
         (.post_stop.main_pid | uint53 and . == 0) and
         (.post_stop.exact_process_count | uint53 and . == 0) and
         (.post_stop.udp_44119_listener_count | uint53 and . == 0) and
         (.post_stop.sidecar_socket_present == false) and
         (.post_stop.original_daemon_pid_present == false) and
         (.post_stop.command_output_format ==
             "key=value newline-delimited UTF-8 in displayed order") and
         (.post_stop.command_output_sha256 | sha256) and
         (.post_stop.command_outputs | keys == ["exact_viewflow_pids",
                                                "original_daemon_pid_present",
                                                "sidecar_socket_present",
                                                "systemctl_is_active",
                                                "systemctl_main_pid",
                                                "udp_44119_listeners"]) and
         (.post_stop.command_outputs == {systemctl_is_active: "inactive",
                                         systemctl_main_pid: "0",
                                         exact_viewflow_pids: "",
                                         udp_44119_listeners: "",
                                         sidecar_socket_present: "false",
                                         original_daemon_pid_present: "false"}) and
         (.completed_at_unix_ms >=
             ((.journal.end_realtime_timestamp_us / 1000) | floor))' \
        "$path" >/dev/null || die 'Linux bootstrap frozen evidence is invalid'

    daemon_pid=$(jq -er '.daemon.pid' "$path")
    daemon_start_ticks=$(jq -er '.daemon.start_ticks' "$path")
    boot_id=$(jq -er '.daemon.boot_id' "$path")
    daemon_instance_id=$(jq -er '.daemon.daemon_instance_id' "$path")
    [[ $daemon_instance_id == "$boot_id-$daemon_pid-$daemon_start_ticks" ]] ||
        die 'Linux bootstrap daemon instance identity is inconsistent'
    [[ $boot_id == "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" ]] ||
        die 'Linux bootstrap frozen evidence belongs to a different boot'
    [[ ! -e /proc/$daemon_pid ]] ||
        die 'Linux bootstrap frozen daemon PID exists again'
    invocation_id=$(jq -er '.daemon.systemd_invocation_id' "$path")
    assert_strict_json_document 'Linux bootstrap frozen evidence' "$path"

    journal_boot_id=${boot_id//-/}
    journal_json=$(journalctl --user --quiet --no-pager --output=json \
        "_SYSTEMD_INVOCATION_ID=$invocation_id" "_PID=$daemon_pid" \
        "_BOOT_ID=$journal_boot_id")
    [[ -n $journal_json ]] || die 'Linux bootstrap invocation journal is no longer available'
    printf '%s\n' "$journal_json" | jq -s -e \
        'length > 0 and all(.[];
            ._SYSTEMD_INVOCATION_ID == $invocation and
            ._PID == $pid and ._BOOT_ID == $boot_id)' \
        --arg invocation "$invocation_id" --arg pid "$daemon_pid" \
        --arg boot_id "$journal_boot_id" \
        >/dev/null || die 'replayed bootstrap journal is not bound to the frozen invocation'
    journal_sha=$(printf '%s\n' "$journal_json" | sha256sum | awk '{print tolower($1)}')
    [[ $journal_sha == "$(jq -er '.journal.slice_sha256' "$path")" ]] ||
        die 'replayed bootstrap journal SHA-256 does not match frozen evidence'
    journal_summary=$(printf '%s\n' "$journal_json" | jq -sr \
        --arg startup 'viewflowd protocol 1.3 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged' \
        '[length, .[0].__CURSOR, .[0].__REALTIME_TIMESTAMP,
          ([.[] | select(.MESSAGE == $startup)][0].__CURSOR),
          ([.[] | select(.MESSAGE == $startup)][0].__REALTIME_TIMESTAMP),
          .[-1].__CURSOR, .[-1].__REALTIME_TIMESTAMP,
          ([.[] | (.MESSAGE // "") | select(. == $startup)] | length),
          ([.[] | (.MESSAGE // "") | select(test("lease_offered="))] | length),
          ([.[] | (.MESSAGE // "") | select(test("input_event_sequence="))] | length),
          ([.[] | (.MESSAGE // "") | select(test("input sidecar activation"))] | length),
          ([.[] | (.MESSAGE // "") |
              select(test("(?i)(((cleanup|release[-_ ]?all|releaseall).*(failed|error|not confirmed|timed out|rejected))|((failed|error).*(cleanup|release[-_ ]?all|releaseall)))"))] |
              length)] | @tsv')
    IFS=$'\t' read -r journal_entries journal_start_cursor journal_start_us \
        startup_cursor startup_us journal_end_cursor journal_end_us startup_count \
        lease_count input_count activation_count cleanup_error_count <<<"$journal_summary"
    [[ $journal_entries == "$(jq -er '.journal.entry_count' "$path")" &&
       $journal_start_cursor == "$(jq -er '.journal.start_cursor' "$path")" &&
       $journal_start_us == "$(jq -er '.journal.start_realtime_timestamp_us' "$path")" &&
       $startup_cursor == "$(jq -er '.journal.protocol_startup_cursor' "$path")" &&
       $startup_us == "$(jq -er '.journal.protocol_startup_realtime_timestamp_us' "$path")" &&
       $journal_end_cursor == "$(jq -er '.journal.end_cursor' "$path")" &&
       $journal_end_us == "$(jq -er '.journal.end_realtime_timestamp_us' "$path")" &&
       $startup_count == "$(jq -er '.journal.counts.protocol_1_3_startup' "$path")" &&
       $lease_count == "$(jq -er '.journal.counts.lease_offered' "$path")" &&
       $input_count == "$(jq -er '.journal.counts.input_event' "$path")" &&
       $activation_count == "$(jq -er '.journal.counts.input_sidecar_activation' "$path")" &&
       $cleanup_error_count == "$(jq -er '.journal.counts.cleanup_or_release_error' "$path")" ]] ||
        die 'replayed bootstrap journal inventory does not match frozen evidence'

    transcript_sha=$(
        printf '%s\n' \
            'systemctl_is_active=inactive' \
            'systemctl_main_pid=0' \
            'exact_viewflow_pids=' \
            'udp_44119_listeners=' \
            'sidecar_socket_present=false' \
            'original_daemon_pid_present=false' |
            sha256sum | awk '{print tolower($1)}'
    )
    [[ $(jq -er '.post_stop.command_output_sha256' "$path") == "$transcript_sha" ]] ||
        die 'Linux bootstrap command output SHA-256 is invalid'
    completed_at_ms=$(jq -er '.completed_at_unix_ms' "$path")
    completed_epoch=$((completed_at_ms / 1000))
    assert_fresh_epoch 'Linux bootstrap frozen evidence' "$completed_epoch"
    printf '%s\n' "$completed_epoch"
}

validate_bootstrap_windows_force_receipt() {
    local path=$1 linux_sha=$2
    assert_strict_json_document 'Windows force-release receipt' "$path"
    jq -e \
        --arg operation_id "$operation_id" \
        --arg linux_sha "$linux_sha" \
        --arg candidate_sha "$windows_viewflow_expected_sha" \
        --arg expected_sid "$windows_expected_user_sid" \
        --arg desktop "$WINDOWS_EXPECTED_DESKTOP" \
        --argjson session "$WINDOWS_EXPECTED_SESSION" \
        'def uint53:
             type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
         def sha256: type == "string" and test("^[0-9a-f]{64}$");
         def u64dec:
             type == "string" and test("^[1-9][0-9]{0,19}$") and
             (length < 20 or (length == 20 and . <= "18446744073709551615"));
         (keys == ["completed_at_utc", "input_desktop", "inserted_input_count",
                   "linux_frozen_evidence_sha256", "operation_id", "requested_input_count",
                   "schema_version", "state",
                   "tool_executable_sha256", "tool_pid", "tool_process_start_filetime",
                   "tool_session_id", "tool_user_sid", "verification_stable_ms"]) and
         (.schema_version == 3) and
         (.state == "viewflow-force-release-completed") and
         (.operation_id == $operation_id) and
         (.linux_frozen_evidence_sha256 == $linux_sha) and
         (.tool_executable_sha256 == $candidate_sha) and
         (.tool_pid | uint53 and . > 0 and . <= 4294967295) and
         (.tool_process_start_filetime | u64dec) and
         (.tool_session_id | uint53 and . == $session) and
         (.tool_user_sid == $expected_sid) and
         (.input_desktop == $desktop) and
         (.requested_input_count | uint53 and . == 135) and
         (.inserted_input_count | uint53 and . == 135) and
         (.verification_stable_ms | uint53 and . == 500) and
         (.completed_at_utc | type == "string")' \
        "$path" >/dev/null || die 'Windows force-release receipt is invalid'
    utc_completion_epoch 'Windows force-release receipt' "$path"
}

validate_bootstrap_windows_install_receipt() {
    local path=$1 force_path=$2 force_sha=$3 linux_sha=$4
    local force_sid force_pid force_start
    force_sid=$(jq -er '.tool_user_sid' "$force_path")
    force_pid=$(jq -er '.tool_pid' "$force_path")
    force_start=$(jq -er '.tool_process_start_filetime' "$force_path")
    assert_strict_json_document 'Windows install-success receipt' "$path"
    jq -e \
        --arg operation_id "$operation_id" \
        --arg force_sha "$force_sha" \
        --arg linux_sha "$linux_sha" \
        --arg candidate_sha "$windows_viewflow_expected_sha" \
        --arg wrapper_sha "$windows_wrapper_expected_sha" \
        --arg task_xml_sha "$windows_task_xml_expected_sha" \
        --arg force_sid "$force_sid" \
        --arg force_pid "$force_pid" \
        --arg force_start "$force_start" \
        --arg expected_sid "$windows_expected_user_sid" \
        --arg protocol "$REQUIRED_VIEWFLOW_PROTOCOL" \
        --arg peer "$WINDOWS_EXPECTED_PEER" \
        --arg device "$VIEWFLOW_TARGET" \
        --argjson session "$WINDOWS_EXPECTED_SESSION" \
        'def uint53:
             type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
         def sha256: type == "string" and test("^[0-9a-f]{64}$");
         def u64dec:
             type == "string" and test("^[1-9][0-9]{0,19}$") and
             (length < 20 or (length == 20 and . <= "18446744073709551615"));
         (keys == ["completed_at_utc", "device_id", "force_release_receipt_sha256",
                   "installed_wrapper_sha256", "linux_frozen_evidence_sha256",
                   "new_process_pid",
                   "new_process_session_id", "new_process_start_filetime",
                   "new_process_user_sid", "new_viewflow_executable_sha256",
                   "old_viewflow_executable_sha256", "operation_id", "peer",
                   "protocol_version", "scheduled_task_xml_sha256", "schema_version",
                   "state"]) and
         (.schema_version == 1) and
         (.state == "viewflow-v2-windows-installed") and
         (.operation_id == $operation_id) and
         (.linux_frozen_evidence_sha256 == $linux_sha) and
         (.force_release_receipt_sha256 == $force_sha) and
         (.old_viewflow_executable_sha256 | sha256) and
         (.new_viewflow_executable_sha256 == $candidate_sha) and
         (.old_viewflow_executable_sha256 != $candidate_sha) and
         (.installed_wrapper_sha256 == $wrapper_sha) and
         (.scheduled_task_xml_sha256 == $task_xml_sha) and
         (.new_process_pid | uint53 and . > 0 and . <= 4294967295) and
         (.new_process_start_filetime | u64dec) and
         (.new_process_session_id | uint53 and . == $session) and
         (.new_process_user_sid == $force_sid) and
         (.new_process_user_sid == $expected_sid) and
         (((.new_process_pid | tostring) != $force_pid) or
             (.new_process_start_filetime != $force_start)) and
         (.protocol_version == $protocol) and
         (.peer == $peer) and
         (.device_id == $device) and
         (.completed_at_utc | type == "string")' \
        "$path" >/dev/null || die 'Windows install-success receipt is invalid'
    utc_completion_epoch 'Windows install-success receipt' "$path"
}

validate_bootstrap_bundle() {
    local linux_path=${1:-$bootstrap_linux_evidence}
    local force_path=${2:-$bootstrap_windows_force_receipt}
    local install_path=${3:-$bootstrap_windows_install_receipt}
    local force_epoch install_epoch force_sha linux_sha
    validate_bootstrap_linux_evidence "$linux_path" >/dev/null
    linux_sha=$(sha256 "$linux_path")
    force_epoch=$(validate_bootstrap_windows_force_receipt \
        "$force_path" "$linux_sha")
    force_sha=$(sha256 "$force_path")
    install_epoch=$(validate_bootstrap_windows_install_receipt \
        "$install_path" "$force_path" "$force_sha" "$linux_sha")
    ((force_epoch <= install_epoch)) ||
        die 'bootstrap evidence completion order is invalid'
}

validate_marker() {
    local path=$1
    local completed_at_ms completed_epoch now age daemon_pid daemon_start_ticks boot_id
    local cert_sha key_sha ca_sha daemon_instance_id revoke_operation_id bound_peer_epoch
    cert_sha=$(sha256 "$VIEWFLOW_CERT")
    key_sha=$(sha256 "$VIEWFLOW_KEY")
    ca_sha=$(sha256 "$VIEWFLOW_CA")
    assert_strict_json_document 'quiescence receipt' "$path"
    jq -e \
        --arg viewflow_sha "$old_viewflow_sha" \
        --arg required_protocol "$REQUIRED_VIEWFLOW_PROTOCOL" \
        --arg operation_id "$operation_id" \
        --arg peer "$VIEWFLOW_PEER" \
        --arg local_device "$VIEWFLOW_DEVICE" \
        --arg target "$VIEWFLOW_TARGET" \
        --arg source_display "$DESKFLOW_SOURCE" \
        --arg cert_sha "$cert_sha" \
        --arg key_sha "$key_sha" \
        --arg ca_sha "$ca_sha" \
        'def uint53:
             type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
         def sha256: type == "string" and test("^[0-9a-f]{64}$");
         (keys == ["artifact_hashes", "boot_id", "cleanup", "completed_at_unix_ms",
                   "daemon_exit_required", "daemon_instance_id", "daemon_pid",
                   "daemon_sha256", "daemon_start_ticks", "local_device",
                   "operation_id", "peer_disconnect_status", "protocol_version",
                   "route_status", "schema_version", "sidecar_session_disconnected",
                   "state", "target_device"]) and
         (.schema_version == 4) and
         (.state == "viewflow-input-quiesced") and
         (.operation_id == $operation_id) and
         (.daemon_pid | uint53 and . > 0) and
         (.daemon_start_ticks | uint53 and . > 0) and
         (.boot_id | type == "string") and
         (.boot_id | test("^[0-9a-f]{8}-[0-9a-f-]{27,}$")) and
         (.daemon_sha256 | sha256) and
         (.daemon_sha256 == $viewflow_sha) and
         (.protocol_version == $required_protocol) and
         (.local_device == $local_device) and
         (.target_device == $target) and
         (.daemon_instance_id | type == "string") and
         (.route_status == "removed") and
         (.peer_disconnect_status == "initiated_before_daemon_exit") and
         (.daemon_exit_required == true) and
         (.sidecar_session_disconnected == true) and
         (.artifact_hashes | keys == ["linux_certificate_authority",
                                      "linux_peer_certificate",
                                      "linux_peer_private_key", "linux_viewflowd"]) and
         (.artifact_hashes.linux_viewflowd | sha256) and
         (.artifact_hashes.linux_viewflowd == $viewflow_sha) and
         (.artifact_hashes.linux_peer_certificate | sha256) and
         (.artifact_hashes.linux_peer_certificate == $cert_sha) and
         (.artifact_hashes.linux_peer_private_key | sha256) and
         (.artifact_hashes.linux_peer_private_key == $key_sha) and
         (.artifact_hashes.linux_certificate_authority | sha256) and
         (.artifact_hashes.linux_certificate_authority == $ca_sha) and
         (.completed_at_unix_ms | uint53 and . > 0) and
         (.cleanup | keys == ["active_lease_generation", "bound_peer_epoch",
                              "bound_peer_socket", "last_input_sequence",
                              "lease_revoke", "release_all", "route_ever_activated",
                              "route_generation", "route_was_active",
                              "source_display"]) and
         (.cleanup.release_all | keys == ["ack", "status"]) and
         (.cleanup.lease_revoke | keys == ["ack", "generation", "status"]) and
         (.cleanup.route_ever_activated | type == "boolean") and
         (.cleanup.route_was_active | type == "boolean") and
         (if .cleanup.route_was_active == false then
              .cleanup.route_ever_activated == false and
              .cleanup.source_display == null and
              .cleanup.route_generation == null and
              .cleanup.active_lease_generation == null and
              .cleanup.last_input_sequence == null and
              .cleanup.release_all.status == "not_required_no_active_route" and
              .cleanup.release_all.ack == null and
              .cleanup.lease_revoke.status == "not_required_no_active_route" and
              .cleanup.lease_revoke.generation == null and
              .cleanup.lease_revoke.ack == null and
              .cleanup.bound_peer_epoch == null and
              .cleanup.bound_peer_socket == null
          else
              .cleanup.route_ever_activated == true and
              .cleanup.source_display == $source_display and
              (.cleanup.route_generation | uint53 and . > 0) and
              (.cleanup.active_lease_generation |
                  uint53 and . > 0 and . < 9007199254740991) and
              (.cleanup.last_input_sequence |
                  uint53 and . < 9007199254740991) and
              .cleanup.release_all.status == "applied" and
              (.cleanup.release_all.ack |
                  keys == ["event_sequence", "lease_generation", "result",
                           "target_device"]) and
              .cleanup.release_all.ack.result == "applied" and
              .cleanup.release_all.ack.lease_generation == .cleanup.active_lease_generation and
              .cleanup.release_all.ack.target_device == $target and
              .cleanup.release_all.ack.event_sequence ==
                  ((.cleanup.last_input_sequence + 1) | if . < 1 then 1 else . end) and
              .cleanup.lease_revoke.status == "applied" and
              .cleanup.lease_revoke.generation == (.cleanup.active_lease_generation + 1) and
              (.cleanup.lease_revoke.ack |
                  keys == ["lease_generation", "operation_id", "owner_device",
                           "result", "state", "target_device"]) and
              (.cleanup.lease_revoke.ack.operation_id |
                  type == "string" and test("^[0-9a-f]{32}$")) and
              .cleanup.lease_revoke.ack.operation_id != "00000000000000000000000000000000" and
              (.cleanup.lease_revoke.ack.lease_generation | uint53) and
              .cleanup.lease_revoke.ack.lease_generation == .cleanup.lease_revoke.generation and
              .cleanup.lease_revoke.ack.owner_device == $local_device and
              .cleanup.lease_revoke.ack.target_device == $target and
              .cleanup.lease_revoke.ack.state == "revoked" and
              .cleanup.lease_revoke.ack.result == "applied" and
              (.cleanup.bound_peer_epoch | uint53 and . > 0) and
              .cleanup.lease_revoke.ack.operation_id[0:16] ==
                  (.cleanup.bound_peer_epoch | hex16) and
              .cleanup.lease_revoke.ack.operation_id[16:32] !=
                  "0000000000000000" and
              (.cleanup.bound_peer_socket | type == "string") and
              ((.cleanup.bound_peer_socket | split(":")) as $socket_parts |
                  ($socket_parts | length) == 2 and
                  $socket_parts[0] == $peer and
                  ($socket_parts[1] | test("^[0-9]+$") and
                      (tonumber >= 1 and tonumber <= 65535)))
          end)' \
        "$path" >/dev/null || die 'quiescence receipt schema, identity, hashes, or cleanup evidence is invalid'

    if [[ $(jq -r '.cleanup.route_was_active' "$path") == true ]]; then
        revoke_operation_id=$(jq -er '.cleanup.lease_revoke.ack.operation_id' "$path")
        bound_peer_epoch=$(jq -er '.cleanup.bound_peer_epoch' "$path")
        [[ ${revoke_operation_id:0:16} == "$(printf '%016x' "$bound_peer_epoch")" ]] ||
            die 'quiescence receipt revoke operation does not bind the exact peer epoch'
    fi

    daemon_pid=$(jq -er '.daemon_pid' "$path")
    daemon_start_ticks=$(jq -er '.daemon_start_ticks' "$path")
    boot_id=$(jq -er '.boot_id' "$path")
    daemon_instance_id=$(jq -er '.daemon_instance_id' "$path")
    [[ $daemon_instance_id == "$boot_id-$daemon_pid-$daemon_start_ticks" ]] ||
        die 'quiescence receipt daemon_instance_id does not match its process identity'
    [[ $boot_id == "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" ]] ||
        die 'quiescence receipt belongs to a different Linux boot'
    [[ ! -e /proc/$daemon_pid ]] ||
        die 'quiescence receipt daemon PID still exists; disconnect is not yet confirmed by exit'
    completed_at_ms=$(jq -er '.completed_at_unix_ms' "$path")
    completed_epoch=$((completed_at_ms / 1000))
    now=$(date -u +%s)
    age=$((now - completed_epoch))
    ((age >= -30 && age <= marker_max_age_seconds)) ||
        die 'quiescence receipt is stale or from the future'
}

validate_daemon_exit_bundle() {
    local receipt_path=${1:-$quiesced_marker}
    local evidence_path=${2:-$daemon_exit_evidence}
    local observation_path=${3:-$daemon_exit_observation}
    local receipt_sha observation_sha daemon_pid boot_id invocation_id journal_boot_id
    local journal_json journal_sha journal_summary journal_entries startup_count exit_count
    local first_us last_us exit_us observed_at_ms completed_at_ms
    receipt_sha=$(sha256 "$receipt_path")
    observation_sha=$(sha256 "$observation_path")
    assert_strict_json_document 'daemon-exit evidence' "$evidence_path"
    assert_strict_json_document 'daemon-exit raw observation' "$observation_path"

    jq -e \
        --arg operation_id "$operation_id" \
        --arg receipt_sha "$receipt_sha" \
        --arg observation_sha "$observation_sha" \
        --arg observation_name "$daemon_exit_observation_expected_name" \
        --arg daemon_sha "$old_viewflow_sha" \
        --arg protocol "$REQUIRED_VIEWFLOW_PROTOCOL" \
        --slurpfile receipt "$receipt_path" \
        --slurpfile observation "$observation_path" \
        'def uint53:
             type == "number" and . == floor and . >= 0 and . <= 9007199254740991;
         def sha256: type == "string" and test("^[0-9a-f]{64}$");
         ($receipt | length == 1) and ($observation | length == 1) and
         ($receipt[0] as $r | $observation[0] as $o |
         (keys == ["active_state", "boot_id", "command_outputs", "daemon_instance_id",
                   "daemon_pid", "daemon_sha256", "daemon_start_ticks",
                   "exact_process_count", "exit_status", "invocation_id", "journal",
                   "main_pid", "observation_file_name", "observation_sha256",
                   "observed_at_unix_ms", "operation_id", "protocol_version",
                   "runtime_receipt_sha256", "schema_version", "sidecar_socket_present",
                   "state", "udp_listener_count", "unit"]) and
         (.schema_version == 1) and (.state == "viewflow-daemon-exited") and
         (.operation_id == $operation_id) and
         (.runtime_receipt_sha256 | sha256) and
         (.runtime_receipt_sha256 == $receipt_sha) and
         (.observation_sha256 | sha256) and
         (.observation_sha256 == $observation_sha) and
         (.observation_file_name == $observation_name) and
         (.daemon_instance_id == $r.daemon_instance_id) and
         (.daemon_pid == $r.daemon_pid and (.daemon_pid | uint53 and . > 0)) and
         (.daemon_start_ticks == $r.daemon_start_ticks and
             (.daemon_start_ticks | uint53 and . > 0)) and
         (.boot_id == $r.boot_id) and
         (.daemon_sha256 | sha256) and
         ($r.daemon_sha256 | sha256) and
         (.daemon_sha256 == $daemon_sha) and
         (.daemon_sha256 == $r.daemon_sha256) and
         (.invocation_id | type == "string" and test("^[0-9a-f]{32}$")) and
         (.protocol_version == $protocol) and (.unit == "viewflow-peer.service") and
         (.journal | keys == ["entry_count", "exit_realtime_us", "first_realtime_us",
                              "last_realtime_us", "query", "quiescence_exit_count",
                              "slice_sha256", "startup_count"]) and
         (.journal.query | keys == ["_BOOT_ID", "_PID", "_SYSTEMD_INVOCATION_ID"]) and
         (.journal.query._SYSTEMD_INVOCATION_ID == .invocation_id) and
         (.journal.query._PID == (.daemon_pid | tostring)) and
         (.journal.query._BOOT_ID == (.boot_id | gsub("-"; ""))) and
         (.journal.entry_count | uint53 and . > 0) and
         (.journal.startup_count | uint53 and . == 1) and
         (.journal.quiescence_exit_count | uint53 and . == 1) and
         (.journal.slice_sha256 | sha256) and
         (.journal.first_realtime_us | uint53 and . > 0) and
         (.journal.last_realtime_us | uint53 and . >= .journal.first_realtime_us) and
         (.journal.exit_realtime_us | uint53 and
             . >= .journal.first_realtime_us and . <= .journal.last_realtime_us) and
         (.active_state == "inactive") and (.main_pid | uint53 and . == 0) and
         (.exact_process_count | uint53 and . == 0) and
         (.udp_listener_count | uint53 and . == 0) and
         (.sidecar_socket_present == false) and
         (.exit_status | keys == ["exact_process_count", "main_pid_zero",
                                  "original_daemon_pid_present", "sidecar_socket_present",
                                  "udp_listener_count", "unit_inactive"]) and
         (.exit_status == {unit_inactive: true, main_pid_zero: true,
                           original_daemon_pid_present: false, exact_process_count: 0,
                           udp_listener_count: 0, sidecar_socket_present: false}) and
         (.command_outputs | keys == ["exact_process_pids", "journal_entries",
                                      "journal_json_sha256", "journal_selected_invocation_id",
                                      "original_daemon_pid_present",
                                      "sidecar_socket_lstat", "systemctl_invocation_id",
                                      "systemctl_is_active", "systemctl_main_pid",
                                      "udp_listener_output"]) and
         (.command_outputs.systemctl_is_active == "inactive") and
         (.command_outputs.systemctl_main_pid == "0") and
         ((.command_outputs.systemctl_invocation_id == "") or
             (.command_outputs.systemctl_invocation_id == .invocation_id)) and
         (.command_outputs.journal_selected_invocation_id == .invocation_id) and
         (.command_outputs.original_daemon_pid_present == "false") and
         (.command_outputs.exact_process_pids == "") and
         (.command_outputs.udp_listener_output == "") and
         (.command_outputs.sidecar_socket_lstat == "absent") and
         (.command_outputs.journal_json_sha256 | sha256) and
         (.command_outputs.journal_json_sha256 == .journal.slice_sha256) and
         (.command_outputs.journal_entries | type == "array") and
         ((.command_outputs.journal_entries | length) == .journal.entry_count) and
         (.observed_at_unix_ms | uint53 and . > 0) and
         ($o | keys == ["command_outputs", "daemon_identity", "journal_query",
                        "observed_at_unix_ms", "operation_id", "runtime_receipt_sha256",
                        "schema_version", "state"]) and
         ($o.schema_version == 1) and ($o.state == "viewflow-daemon-exit-observation") and
         ($o.operation_id == $operation_id) and
         ($o.runtime_receipt_sha256 | sha256) and
         ($o.runtime_receipt_sha256 == $receipt_sha) and
         ($o.observed_at_unix_ms == .observed_at_unix_ms) and
         ($o.daemon_identity | keys == ["boot_id", "daemon_instance_id", "daemon_pid",
                                        "daemon_sha256", "daemon_start_ticks",
                                        "invocation_id"]) and
         ($o.daemon_identity == {daemon_instance_id: .daemon_instance_id,
                                 daemon_pid: .daemon_pid,
                                 daemon_start_ticks: .daemon_start_ticks,
                                 boot_id: .boot_id, daemon_sha256: .daemon_sha256,
                                 invocation_id: .invocation_id}) and
         ($o.journal_query == .journal.query) and
         ($o.command_outputs == .command_outputs))' \
        "$evidence_path" >/dev/null ||
        die 'daemon-exit evidence, raw observation, and runtime receipt are inconsistent'

    daemon_pid=$(jq -er '.daemon_pid' "$evidence_path")
    boot_id=$(jq -er '.boot_id' "$evidence_path")
    invocation_id=$(jq -er '.invocation_id' "$evidence_path")
    [[ $boot_id == "$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)" ]] ||
        die 'daemon-exit evidence belongs to another Linux boot'
    [[ ! -e /proc/$daemon_pid ]] || die 'daemon-exit evidence PID exists again'
    journal_boot_id=${boot_id//-/}
    journal_json=$(journalctl --user --quiet --no-pager --output=json \
        "_SYSTEMD_INVOCATION_ID=$invocation_id" "_PID=$daemon_pid" \
        "_BOOT_ID=$journal_boot_id")
    [[ -n $journal_json ]] || die 'daemon-exit invocation journal is no longer available'
    printf '%s\n' "$journal_json" | jq -s -e \
        'length > 0 and all(.[];
            ._SYSTEMD_INVOCATION_ID == $invocation and
            ._PID == $pid and ._BOOT_ID == $boot_id)' \
        --arg invocation "$invocation_id" --arg pid "$daemon_pid" \
        --arg boot_id "$journal_boot_id" >/dev/null ||
        die 'replayed daemon-exit journal is not bound to the evidenced invocation'
    journal_sha=$(printf '%s\n' "$journal_json" | sha256sum | awk '{print tolower($1)}')
    [[ $journal_sha == "$(jq -er '.journal.slice_sha256' "$evidence_path")" ]] ||
        die 'replayed daemon-exit journal SHA-256 does not match evidence'
    journal_summary=$(printf '%s\n' "$journal_json" | jq -sr \
        --arg startup 'viewflowd protocol 2.1 serving mTLS QUIC on 0.0.0.0:44119; Deskflow unchanged' \
        --arg exit 'viewflowd deployment quiescence receipt written; daemon exiting' \
        '[length,
          ([.[] | select((.MESSAGE // "") == $startup)] | length),
          ([.[] | select((.MESSAGE // "") == $exit)] | length),
          (map(.__REALTIME_TIMESTAMP | tonumber) | min),
          (map(.__REALTIME_TIMESTAMP | tonumber) | max),
          ([.[] | select((.MESSAGE // "") == $exit) |
              .__REALTIME_TIMESTAMP | tonumber] | only)] | @tsv')
    IFS=$'\t' read -r journal_entries startup_count exit_count first_us last_us exit_us \
        <<<"$journal_summary"
    [[ $journal_entries == "$(jq -er '.journal.entry_count' "$evidence_path")" &&
       $startup_count == "$(jq -er '.journal.startup_count' "$evidence_path")" &&
       $exit_count == "$(jq -er '.journal.quiescence_exit_count' "$evidence_path")" &&
       $first_us == "$(jq -er '.journal.first_realtime_us' "$evidence_path")" &&
       $last_us == "$(jq -er '.journal.last_realtime_us' "$evidence_path")" &&
       $exit_us == "$(jq -er '.journal.exit_realtime_us' "$evidence_path")" ]] ||
        die 'replayed daemon-exit journal inventory does not match evidence'
    printf '%s\n' "$journal_json" | jq -s -e \
        --slurpfile evidence "$evidence_path" \
        '. == $evidence[0].command_outputs.journal_entries' >/dev/null ||
        die 'replayed daemon-exit journal entries differ from the raw observation'

    observed_at_ms=$(jq -er '.observed_at_unix_ms' "$evidence_path")
    completed_at_ms=$(jq -er '.completed_at_unix_ms' "$receipt_path")
    ((observed_at_ms >= completed_at_ms && exit_us >= completed_at_ms * 1000)) ||
        die 'daemon-exit evidence time order is invalid'
    assert_fresh_epoch 'daemon-exit evidence' "$((observed_at_ms / 1000))"
}

backup_current_runtime() {
    local stamp
    stamp=$(date -u +%Y%m%dT%H%M%S)-$$
    backup_dir=$BACKUP_PARENT/$stamp
    install -d -m 0700 -- "$BACKUP_PARENT" "$backup_dir"
    install -m 0755 -- "$VIEWFLOW_INSTALLED" "$backup_dir/viewflowd"
    install -m 0755 -- "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
        "$backup_dir/viewflow-deployment-marker"
    install -m 0755 -- "$DESKFLOW_INSTALLED" "$backup_dir/deskflow"
    install -m 0755 -- "$DESKFLOW_CORE_INSTALLED" "$backup_dir/deskflow-core"
    install -m 0644 -- "$VIEWFLOW_UNIT_INSTALLED" "$backup_dir/viewflow-peer.service"
    install -m 0644 -- "$DESKFLOW_DROPIN_INSTALLED" "$backup_dir/deskflow-viewflow.conf"
    assert_hash 'Viewflow backup' "$backup_dir/viewflowd" "$old_viewflow_sha"
    assert_hash 'deployment marker tool backup' "$backup_dir/viewflow-deployment-marker" \
        "$old_deployment_marker_tool_sha"
    assert_hash 'Deskflow backup' "$backup_dir/deskflow" "$old_deskflow_sha"
    assert_hash 'deskflow-core backup' "$backup_dir/deskflow-core" "$old_deskflow_core_sha"
    assert_hash 'Viewflow unit backup' "$backup_dir/viewflow-peer.service" "$old_viewflow_unit_sha"
    assert_hash 'Deskflow drop-in backup' "$backup_dir/deskflow-viewflow.conf" \
        "$old_deskflow_dropin_sha"
}

restore_runtime_files() {
    local failed=0
    atomic_install "$backup_dir/viewflowd" "$VIEWFLOW_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/viewflow-deployment-marker" \
        "$DEPLOYMENT_MARKER_TOOL_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/deskflow" "$DESKFLOW_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/deskflow-core" "$DESKFLOW_CORE_INSTALLED" 0755 || failed=1
    atomic_install "$backup_dir/viewflow-peer.service" "$VIEWFLOW_UNIT_INSTALLED" 0644 || failed=1
    atomic_install "$backup_dir/deskflow-viewflow.conf" "$DESKFLOW_DROPIN_INSTALLED" 0644 || failed=1
    assert_hash 'restored Viewflow' "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" || failed=1
    assert_hash 'restored deployment marker tool' "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
        "$old_deployment_marker_tool_sha" || failed=1
    assert_executable_artifact_metadata 'restored deployment marker tool' \
        "$DEPLOYMENT_MARKER_TOOL_INSTALLED" || failed=1
    assert_hash 'restored Deskflow' "$DESKFLOW_INSTALLED" "$old_deskflow_sha" || failed=1
    assert_hash 'restored deskflow-core' "$DESKFLOW_CORE_INSTALLED" "$old_deskflow_core_sha" || failed=1
    assert_hash 'restored Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED" "$old_viewflow_unit_sha" || failed=1
    assert_hash 'restored Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" \
        "$old_deskflow_dropin_sha" || failed=1
    assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED" \
        'restored Deskflow drop-in' || failed=1
    assert_viewflow_unit_acceptance_contract "$VIEWFLOW_UNIT_INSTALLED" \
        'restored Viewflow unit' || failed=1
    return "$failed"
}

rollback_runtime() {
    local failed=0
    printf 'deployment failed; rolling back from %s\n' "$backup_dir" >&2
    # QUARANTINE_BOUNDARY: rollback-before-stop
    assert_quarantine_storage_unchanged || failed=1
    assert_acceptance_state_dir || failed=1
    systemctl --user stop "$DESKFLOW_UNIT" >/dev/null 2>&1 || failed=1
    wait_unit_stopped "$DESKFLOW_UNIT" "$DESKFLOW_INSTALLED" "$DESKFLOW_CORE_INSTALLED" || failed=1
    assert_quarantine_storage_unchanged || failed=1
    assert_acceptance_state_dir || failed=1
    systemctl --user stop "$VIEWFLOW_UNIT" >/dev/null 2>&1 || failed=1
    wait_unit_stopped "$VIEWFLOW_UNIT" "$VIEWFLOW_INSTALLED" || failed=1
    # QUARANTINE_BOUNDARY: rollback-before-restore
    assert_quarantine_storage_unchanged || return 1
    assert_acceptance_state_dir || return 1
    assert_deployment_marker_tool_stopped || return 1
    restore_runtime_files || failed=1
    systemctl --user daemon-reload || failed=1
    assert_loaded_unit_configuration || failed=1
    # QUARANTINE_BOUNDARY: rollback-after-reload
    assert_quarantine_storage_unchanged || failed=1
    assert_acceptance_state_dir || failed=1
    assert_hash 'rollback Viewflow' "$VIEWFLOW_INSTALLED" "$old_viewflow_sha" || failed=1
    assert_hash 'rollback deployment marker tool' "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
        "$old_deployment_marker_tool_sha" || failed=1
    assert_hash 'rollback Deskflow' "$DESKFLOW_INSTALLED" "$old_deskflow_sha" || failed=1
    assert_hash 'rollback deskflow-core' "$DESKFLOW_CORE_INSTALLED" \
        "$old_deskflow_core_sha" || failed=1
    assert_hash 'rollback Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED" "$old_viewflow_unit_sha" || failed=1
    assert_hash 'rollback Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" \
        "$old_deskflow_dropin_sha" || failed=1
    [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_main_pid "$VIEWFLOW_UNIT") == 0 ]] || failed=1
    [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_main_pid "$DESKFLOW_UNIT") == 0 ]] || failed=1
    assert_no_listener udp "$VIEWFLOW_PORT" || failed=1
    assert_no_listener tcp "$DESKFLOW_PORT" || failed=1
    assert_acceptance_runtime_sockets_absent || failed=1
    # QUARANTINE_BOUNDARY: rollback-final-proof
    assert_quarantine_storage_unchanged || failed=1
    assert_acceptance_state_dir || failed=1
    return "$failed"
}

handle_failure() {
    local status=$1
    local command=$2
    trap - ERR INT TERM
    set +e
    printf 'transaction command failed (%s): %s\n' "$status" "$command" >&2
    if ((transaction_started)); then
        if ! rollback_runtime; then
            printf 'automatic rollback failed; inspect retained backup: %s\n' "$backup_dir" >&2
            exit 70
        fi
        printf 'automatic rollback completed with both units inactive; backup retained: %s\n' \
            "$backup_dir" >&2
        printf 'cross-host protocol compatibility must be confirmed before either unit is started\n' >&2
    fi
    exit "$status"
}

handle_signal() {
    local status=$1
    handle_failure "$status" 'received termination signal'
}

trap 'handle_failure $? "$BASH_COMMAND"' ERR
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

assert_old_runtime_stopped() {
    [[ $(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_main_pid "$VIEWFLOW_UNIT") == 0 &&
       -z $(exact_executable_pids "$VIEWFLOW_INSTALLED") ]] ||
        die "$VIEWFLOW_UNIT must be inactive with the old daemon fully exited"
    [[ $(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true) != active &&
       $(unit_main_pid "$DESKFLOW_UNIT") == 0 &&
       -z $(exact_executable_pids "$DESKFLOW_INSTALLED") &&
       -z $(exact_executable_pids "$DESKFLOW_CORE_INSTALLED") ]] ||
        die "$DESKFLOW_UNIT must be inactive before evidence consumption"
    [[ ! -e $VIEWFLOW_SIDECAR ]] || die 'Viewflow sidecar socket remains after shutdown'
    assert_acceptance_runtime_sockets_absent
    assert_no_listener udp "$VIEWFLOW_PORT"
    assert_no_listener tcp "$DESKFLOW_PORT"
    assert_deployment_marker_tool_stopped
}

preflight() {
    local path canonical installed_canonical bootstrap_option_count
    local linux_evidence_canonical windows_force_canonical windows_install_canonical
    local marker_canonical exit_evidence_canonical exit_observation_canonical
    [[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] ||
        die "run as uid $EXPECTED_UID with HOME=$EXPECTED_HOME"
    for command in awk basename chmod date grep head install jq journalctl mkdir mktemp mv python3 \
        readelf readlink rm sha256sum ss stat systemctl; do
        command -v "$command" >/dev/null || die "required command is unavailable: $command"
    done
    # QUARANTINE_BOUNDARY: preflight
    freeze_quarantine_storage
    ensure_acceptance_state_dir

    [[ -n $viewflow_candidate && -n $viewflow_expected_sha &&
       -n $deployment_marker_tool_candidate && -n $deployment_marker_tool_expected_sha &&
       -n $deskflow_candidate && -n $deskflow_expected_sha &&
       -n $deskflow_core_candidate && -n $deskflow_core_expected_sha &&
       -n $deskflow_provenance_manifest && -n $deskflow_provenance_expected_sha &&
       -n $viewflow_unit_candidate && -n $viewflow_unit_expected_sha &&
       -n $deskflow_dropin_candidate && -n $deskflow_dropin_expected_sha &&
       -n $operation_id ]] ||
        die 'all candidate, SHA-256, and operation ID options are mandatory'
    bootstrap_option_count=0
    [[ -n $bootstrap_linux_evidence ]] && ((bootstrap_option_count += 1))
    [[ -n $bootstrap_windows_force_receipt ]] && ((bootstrap_option_count += 1))
    [[ -n $bootstrap_windows_install_receipt ]] && ((bootstrap_option_count += 1))
    [[ -n $windows_viewflow_expected_sha ]] && ((bootstrap_option_count += 1))
    [[ -n $windows_wrapper_expected_sha ]] && ((bootstrap_option_count += 1))
    [[ -n $windows_task_xml_expected_sha ]] && ((bootstrap_option_count += 1))
    [[ -n $windows_expected_user_sid ]] && ((bootstrap_option_count += 1))
    ((bootstrap_option_count == 0)) ||
        die 'single-stage v1.3 bootstrap options are disabled'
    [[ -n $quiesced_marker && -n $daemon_exit_evidence && -n $daemon_exit_observation ]] ||
        die 'normal schema-v4 mode requires quiescence receipt, daemon-exit evidence, and raw observation'
    [[ ${#operation_id} -ge 16 && ${#operation_id} -le 128 &&
       $operation_id =~ ^[A-Za-z0-9_-]+$ ]] ||
        die 'operation ID must be 16-128 ASCII letters, digits, hyphens, or underscores'
    [[ $marker_max_age_seconds =~ ^[1-9][0-9]*$ && $marker_max_age_seconds -le 1800 ]] ||
        die 'marker max age must be an integer from 1 through 1800 seconds'

    require_sha256 '--viewflow-sha256' "$viewflow_expected_sha"
    require_sha256 '--deployment-marker-sha256' "$deployment_marker_tool_expected_sha"
    require_sha256 '--deskflow-sha256' "$deskflow_expected_sha"
    require_sha256 '--deskflow-core-sha256' "$deskflow_core_expected_sha"
    require_sha256 '--deskflow-provenance-sha256' "$deskflow_provenance_expected_sha"
    require_sha256 '--viewflow-unit-sha256' "$viewflow_unit_expected_sha"
    require_sha256 '--deskflow-dropin-sha256' "$deskflow_dropin_expected_sha"
    [[ -z $windows_viewflow_expected_sha ]] ||
        require_sha256 '--windows-viewflow-sha256' "$windows_viewflow_expected_sha"
    [[ -z $windows_wrapper_expected_sha ]] ||
        require_sha256 '--windows-wrapper-sha256' "$windows_wrapper_expected_sha"
    [[ -z $windows_task_xml_expected_sha ]] ||
        require_sha256 '--windows-task-xml-sha256' "$windows_task_xml_expected_sha"
    [[ -z $windows_expected_user_sid ||
       $windows_expected_user_sid =~ ^S-1-[0-9]+(-[0-9]+)+$ ]] ||
        die '--windows-user-sid must be a canonical Windows SID'
    require_absolute_regular_file 'Viewflow candidate' "$viewflow_candidate"
    assert_executable_artifact_metadata 'deployment marker tool candidate' \
        "$deployment_marker_tool_candidate"
    require_absolute_regular_file 'Deskflow candidate' "$deskflow_candidate"
    require_absolute_regular_file 'deskflow-core candidate' "$deskflow_core_candidate"
    assert_evidence_permissions 'Deskflow provenance manifest' \
        "$deskflow_provenance_manifest"
    deskflow_provenance_preflight_identity=$(evidence_identity \
        "$deskflow_provenance_manifest")
    deskflow_provenance_preflight_sha=$(sha256 "$deskflow_provenance_manifest")
    [[ $deskflow_provenance_preflight_sha == "$deskflow_provenance_expected_sha" ]] ||
        die 'Deskflow provenance manifest SHA-256 mismatch'
    require_absolute_regular_file 'Viewflow unit candidate' "$viewflow_unit_candidate"
    require_absolute_regular_file 'Deskflow drop-in candidate' "$deskflow_dropin_candidate"
    if [[ -n $quiesced_marker ]]; then
        assert_evidence_permissions 'quiesced marker' "$quiesced_marker"
        assert_evidence_permissions 'daemon-exit evidence' "$daemon_exit_evidence"
        assert_evidence_permissions 'daemon-exit raw observation' "$daemon_exit_observation"
        marker_canonical=$(readlink -f -- "$quiesced_marker")
        exit_evidence_canonical=$(readlink -f -- "$daemon_exit_evidence")
        exit_observation_canonical=$(readlink -f -- "$daemon_exit_observation")
        [[ $marker_canonical != "$exit_evidence_canonical" &&
           $marker_canonical != "$exit_observation_canonical" &&
           $exit_evidence_canonical != "$exit_observation_canonical" ]] ||
            die 'normal receipt, exit evidence, and raw observation must be distinct files'
        quiesced_marker_preflight_identity=$(evidence_identity "$quiesced_marker")
        quiesced_marker_preflight_sha=$(sha256 "$quiesced_marker")
        daemon_exit_evidence_preflight_identity=$(evidence_identity "$daemon_exit_evidence")
        daemon_exit_evidence_preflight_sha=$(sha256 "$daemon_exit_evidence")
        daemon_exit_observation_preflight_identity=$(evidence_identity "$daemon_exit_observation")
        daemon_exit_observation_preflight_sha=$(sha256 "$daemon_exit_observation")
        daemon_exit_observation_expected_name=$(basename -- "$daemon_exit_observation")
    else
        assert_evidence_permissions 'Linux bootstrap frozen evidence' \
            "$bootstrap_linux_evidence"
        assert_evidence_permissions 'Windows force-release receipt' \
            "$bootstrap_windows_force_receipt"
        assert_evidence_permissions 'Windows install-success receipt' \
            "$bootstrap_windows_install_receipt"
        linux_evidence_canonical=$(readlink -f -- "$bootstrap_linux_evidence")
        windows_force_canonical=$(readlink -f -- "$bootstrap_windows_force_receipt")
        windows_install_canonical=$(readlink -f -- "$bootstrap_windows_install_receipt")
        [[ $linux_evidence_canonical != "$windows_force_canonical" &&
           $linux_evidence_canonical != "$windows_install_canonical" &&
           $windows_force_canonical != "$windows_install_canonical" ]] ||
            die 'bootstrap evidence paths must be three distinct files'
        bootstrap_linux_preflight_identity=$(evidence_identity "$bootstrap_linux_evidence")
        bootstrap_linux_preflight_sha=$(sha256 "$bootstrap_linux_evidence")
        bootstrap_force_preflight_identity=$(evidence_identity "$bootstrap_windows_force_receipt")
        bootstrap_force_preflight_sha=$(sha256 "$bootstrap_windows_force_receipt")
        bootstrap_install_preflight_identity=$(evidence_identity "$bootstrap_windows_install_receipt")
        bootstrap_install_preflight_sha=$(sha256 "$bootstrap_windows_install_receipt")
    fi
    require_absolute_regular_file 'installed Viewflow' "$VIEWFLOW_INSTALLED"
    assert_executable_artifact_metadata 'installed deployment marker tool' \
        "$DEPLOYMENT_MARKER_TOOL_INSTALLED"
    require_absolute_regular_file 'installed Deskflow' "$DESKFLOW_INSTALLED"
    require_absolute_regular_file 'installed deskflow-core' "$DESKFLOW_CORE_INSTALLED"
    require_absolute_regular_file 'installed Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED"
    require_absolute_regular_file 'installed Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED"
    require_absolute_regular_file 'Viewflow peer certificate' "$VIEWFLOW_CERT"
    require_absolute_regular_file 'Viewflow private key' "$VIEWFLOW_KEY"
    require_absolute_regular_file 'Viewflow certificate authority' "$VIEWFLOW_CA"
    for path in "$viewflow_candidate" "$deployment_marker_tool_candidate" \
        "$deskflow_candidate" "$deskflow_core_candidate"; do
        [[ -x $path ]] || die "candidate is not executable: $path"
        canonical=$(readlink -f -- "$path")
        for installed_canonical in \
            "$VIEWFLOW_INSTALLED" "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
            "$DESKFLOW_INSTALLED" "$DESKFLOW_CORE_INSTALLED"; do
            [[ $canonical != "$installed_canonical" ]] ||
                die "candidate must not be the installed file: $path"
        done
    done

    assert_hash 'Viewflow candidate' "$viewflow_candidate" "$viewflow_expected_sha"
    assert_hash 'deployment marker tool candidate' "$deployment_marker_tool_candidate" \
        "$deployment_marker_tool_expected_sha"
    assert_hash 'Deskflow candidate' "$deskflow_candidate" "$deskflow_expected_sha"
    assert_hash 'deskflow-core candidate' "$deskflow_core_candidate" "$deskflow_core_expected_sha"
    validate_deskflow_provenance_manifest "$deskflow_provenance_manifest"
    assert_hash 'Viewflow unit candidate' "$viewflow_unit_candidate" "$viewflow_unit_expected_sha"
    assert_hash 'Deskflow drop-in candidate' "$deskflow_dropin_candidate" \
        "$deskflow_dropin_expected_sha"
    assert_quarantine_dropin_contract "$deskflow_dropin_candidate" \
        'Deskflow drop-in candidate'
    assert_viewflow_unit_acceptance_contract "$viewflow_unit_candidate" \
        'Viewflow unit candidate'
    [[ $(readlink -f -- "$viewflow_unit_candidate") != "$VIEWFLOW_UNIT_INSTALLED" ]] ||
        die 'Viewflow unit candidate must not be the installed file'
    [[ $(readlink -f -- "$deskflow_dropin_candidate") != "$DESKFLOW_DROPIN_INSTALLED" ]] ||
        die 'Deskflow drop-in candidate must not be the installed file'

    old_viewflow_sha=$(sha256 "$VIEWFLOW_INSTALLED")
    old_deployment_marker_tool_sha=$(sha256 "$DEPLOYMENT_MARKER_TOOL_INSTALLED")
    old_deskflow_sha=$(sha256 "$DESKFLOW_INSTALLED")
    old_deskflow_core_sha=$(sha256 "$DESKFLOW_CORE_INSTALLED")
    old_viewflow_unit_sha=$(sha256 "$VIEWFLOW_UNIT_INSTALLED")
    old_deskflow_dropin_sha=$(sha256 "$DESKFLOW_DROPIN_INSTALLED")
    assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED" \
        'installed Deskflow drop-in'
    assert_viewflow_unit_acceptance_contract "$VIEWFLOW_UNIT_INSTALLED" \
        'installed Viewflow unit'
    assert_old_runtime_stopped
    if [[ -n $quiesced_marker ]]; then
        validate_marker "$quiesced_marker"
        validate_daemon_exit_bundle
        assert_evidence_unchanged 'quiescence receipt' "$quiesced_marker" \
            "$quiesced_marker_preflight_identity" "$quiesced_marker_preflight_sha"
        assert_evidence_unchanged 'daemon-exit evidence' "$daemon_exit_evidence" \
            "$daemon_exit_evidence_preflight_identity" "$daemon_exit_evidence_preflight_sha"
        assert_evidence_unchanged 'daemon-exit raw observation' "$daemon_exit_observation" \
            "$daemon_exit_observation_preflight_identity" \
            "$daemon_exit_observation_preflight_sha"
    else
        validate_bootstrap_bundle
        assert_evidence_unchanged 'Linux bootstrap frozen evidence' \
            "$bootstrap_linux_evidence" "$bootstrap_linux_preflight_identity" \
            "$bootstrap_linux_preflight_sha"
        assert_evidence_unchanged 'Windows force-release receipt' \
            "$bootstrap_windows_force_receipt" "$bootstrap_force_preflight_identity" \
            "$bootstrap_force_preflight_sha"
        assert_evidence_unchanged 'Windows install-success receipt' \
            "$bootstrap_windows_install_receipt" "$bootstrap_install_preflight_identity" \
            "$bootstrap_install_preflight_sha"
    fi
}

deploy_transaction() {
    preflight
    backup_current_runtime

    # Recheck every mutable input at the commit boundary.
    assert_hash 'Viewflow candidate' "$viewflow_candidate" "$viewflow_expected_sha"
    assert_hash 'deployment marker tool candidate' "$deployment_marker_tool_candidate" \
        "$deployment_marker_tool_expected_sha"
    assert_executable_artifact_metadata 'deployment marker tool candidate at commit boundary' \
        "$deployment_marker_tool_candidate"
    assert_hash 'Deskflow candidate' "$deskflow_candidate" "$deskflow_expected_sha"
    assert_hash 'deskflow-core candidate' "$deskflow_core_candidate" "$deskflow_core_expected_sha"
    assert_evidence_unchanged 'Deskflow provenance manifest' \
        "$deskflow_provenance_manifest" "$deskflow_provenance_preflight_identity" \
        "$deskflow_provenance_preflight_sha"
    validate_deskflow_provenance_manifest "$deskflow_provenance_manifest"
    assert_hash 'Viewflow unit candidate' "$viewflow_unit_candidate" "$viewflow_unit_expected_sha"
    assert_hash 'Deskflow drop-in candidate' "$deskflow_dropin_candidate" \
        "$deskflow_dropin_expected_sha"
    assert_quarantine_dropin_contract "$deskflow_dropin_candidate" \
        'Deskflow drop-in candidate at commit boundary'
    assert_viewflow_unit_acceptance_contract "$viewflow_unit_candidate" \
        'Viewflow unit candidate at commit boundary'
    assert_hash 'installed Viewflow' "$VIEWFLOW_INSTALLED" "$old_viewflow_sha"
    assert_hash 'installed deployment marker tool' "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
        "$old_deployment_marker_tool_sha"
    assert_executable_artifact_metadata 'installed deployment marker tool at commit boundary' \
        "$DEPLOYMENT_MARKER_TOOL_INSTALLED"
    assert_hash 'installed Deskflow' "$DESKFLOW_INSTALLED" "$old_deskflow_sha"
    assert_hash 'installed deskflow-core' "$DESKFLOW_CORE_INSTALLED" "$old_deskflow_core_sha"
    assert_hash 'installed Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED" "$old_viewflow_unit_sha"
    assert_hash 'installed Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" \
        "$old_deskflow_dropin_sha"
    assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED" \
        'installed Deskflow drop-in at commit boundary'
    assert_viewflow_unit_acceptance_contract "$VIEWFLOW_UNIT_INSTALLED" \
        'installed Viewflow unit at commit boundary'
    assert_acceptance_state_dir
    # QUARANTINE_BOUNDARY: commit
    assert_quarantine_storage_unchanged
    assert_old_runtime_stopped

    # TRANSACTION_PHASE: consume-single-use-quiescence-evidence
    if [[ -n $quiesced_marker ]]; then
        assert_evidence_on_backup_filesystem 'quiescence receipt' "$quiesced_marker"
        assert_evidence_on_backup_filesystem 'daemon-exit evidence' "$daemon_exit_evidence"
        assert_evidence_on_backup_filesystem 'daemon-exit raw observation' \
            "$daemon_exit_observation"
        assert_evidence_unchanged 'quiescence receipt' "$quiesced_marker" \
            "$quiesced_marker_preflight_identity" "$quiesced_marker_preflight_sha"
        assert_evidence_unchanged 'daemon-exit evidence' "$daemon_exit_evidence" \
            "$daemon_exit_evidence_preflight_identity" "$daemon_exit_evidence_preflight_sha"
        assert_evidence_unchanged 'daemon-exit raw observation' "$daemon_exit_observation" \
            "$daemon_exit_observation_preflight_identity" \
            "$daemon_exit_observation_preflight_sha"
        validate_marker "$quiesced_marker"
        validate_daemon_exit_bundle
        assert_old_runtime_stopped # normal-before-consumption
        transaction_started=1
        mv -T -- "$quiesced_marker" "$backup_dir/quiesced-marker.json"
        mv -T -- "$daemon_exit_evidence" "$backup_dir/viewflow-daemon-exited.json"
        mv -T -- "$daemon_exit_observation" \
            "$backup_dir/viewflow-daemon-exit-observation.json"
        assert_evidence_unchanged 'consumed quiescence receipt' \
            "$backup_dir/quiesced-marker.json" "$quiesced_marker_preflight_identity" \
            "$quiesced_marker_preflight_sha"
        assert_evidence_unchanged 'consumed daemon-exit evidence' \
            "$backup_dir/viewflow-daemon-exited.json" \
            "$daemon_exit_evidence_preflight_identity" "$daemon_exit_evidence_preflight_sha"
        assert_evidence_unchanged 'consumed daemon-exit raw observation' \
            "$backup_dir/viewflow-daemon-exit-observation.json" \
            "$daemon_exit_observation_preflight_identity" \
            "$daemon_exit_observation_preflight_sha"
        validate_marker "$backup_dir/quiesced-marker.json"
        validate_daemon_exit_bundle \
            "$backup_dir/quiesced-marker.json" \
            "$backup_dir/viewflow-daemon-exited.json" \
            "$backup_dir/viewflow-daemon-exit-observation.json"
        assert_old_runtime_stopped # normal-after-consumption
    else
        assert_evidence_on_backup_filesystem 'Linux bootstrap frozen evidence' \
            "$bootstrap_linux_evidence"
        assert_evidence_on_backup_filesystem 'Windows force-release receipt' \
            "$bootstrap_windows_force_receipt"
        assert_evidence_on_backup_filesystem 'Windows install-success receipt' \
            "$bootstrap_windows_install_receipt"
        assert_evidence_unchanged 'Linux bootstrap frozen evidence' \
            "$bootstrap_linux_evidence" "$bootstrap_linux_preflight_identity" \
            "$bootstrap_linux_preflight_sha"
        assert_evidence_unchanged 'Windows force-release receipt' \
            "$bootstrap_windows_force_receipt" "$bootstrap_force_preflight_identity" \
            "$bootstrap_force_preflight_sha"
        assert_evidence_unchanged 'Windows install-success receipt' \
            "$bootstrap_windows_install_receipt" "$bootstrap_install_preflight_identity" \
            "$bootstrap_install_preflight_sha"
        validate_bootstrap_bundle
        assert_old_runtime_stopped # bootstrap-before-consumption
        transaction_started=1
        mv -T -- "$bootstrap_linux_evidence" \
            "$backup_dir/viewflow-v13-bootstrap-frozen.json"
        mv -T -- "$bootstrap_windows_force_receipt" \
            "$backup_dir/viewflow-force-release-completed.json"
        mv -T -- "$bootstrap_windows_install_receipt" \
            "$backup_dir/viewflow-v2-windows-installed.json"
        assert_evidence_unchanged 'consumed Linux bootstrap evidence' \
            "$backup_dir/viewflow-v13-bootstrap-frozen.json" \
            "$bootstrap_linux_preflight_identity" "$bootstrap_linux_preflight_sha"
        assert_evidence_unchanged 'consumed Windows force-release receipt' \
            "$backup_dir/viewflow-force-release-completed.json" \
            "$bootstrap_force_preflight_identity" "$bootstrap_force_preflight_sha"
        assert_evidence_unchanged 'consumed Windows install-success receipt' \
            "$backup_dir/viewflow-v2-windows-installed.json" \
            "$bootstrap_install_preflight_identity" "$bootstrap_install_preflight_sha"
        validate_bootstrap_bundle \
            "$backup_dir/viewflow-v13-bootstrap-frozen.json" \
            "$backup_dir/viewflow-force-release-completed.json" \
            "$backup_dir/viewflow-v2-windows-installed.json"
        assert_old_runtime_stopped # bootstrap-after-consumption
    fi

    # TRANSACTION_PHASE: stop-deskflow-before-viewflow
    # QUARANTINE_BOUNDARY: before-stop-deskflow
    assert_quarantine_storage_unchanged
    stop_unit_and_wait "$DESKFLOW_UNIT" "$DESKFLOW_INSTALLED" "$DESKFLOW_CORE_INSTALLED"
    # QUARANTINE_BOUNDARY: after-stop-deskflow
    assert_quarantine_storage_unchanged

    # TRANSACTION_PHASE: stop-viewflow
    stop_unit_and_wait "$VIEWFLOW_UNIT" "$VIEWFLOW_INSTALLED"
    [[ ! -e $VIEWFLOW_SIDECAR ]] || die 'old Viewflow sidecar socket remains after shutdown'
    assert_acceptance_runtime_sockets_absent
    # QUARANTINE_BOUNDARY: after-stop-viewflow
    assert_quarantine_storage_unchanged

    # TRANSACTION_PHASE: install-viewflow-v2
    atomic_install "$viewflow_candidate" "$VIEWFLOW_INSTALLED" 0755
    assert_hash 'installed Viewflow v2 candidate' "$VIEWFLOW_INSTALLED" "$viewflow_expected_sha"

    # TRANSACTION_PHASE: install-deployment-marker-tool
    assert_deployment_marker_tool_stopped
    atomic_install "$deployment_marker_tool_candidate" \
        "$DEPLOYMENT_MARKER_TOOL_INSTALLED" 0755
    assert_hash 'installed deployment marker tool candidate' \
        "$DEPLOYMENT_MARKER_TOOL_INSTALLED" "$deployment_marker_tool_expected_sha"
    assert_executable_artifact_metadata 'installed deployment marker tool candidate' \
        "$DEPLOYMENT_MARKER_TOOL_INSTALLED"
    assert_deployment_marker_tool_stopped

    # TRANSACTION_PHASE: install-runtime-unit-configuration
    atomic_install "$viewflow_unit_candidate" "$VIEWFLOW_UNIT_INSTALLED" 0644
    atomic_install "$deskflow_dropin_candidate" "$DESKFLOW_DROPIN_INSTALLED" 0644
    assert_hash 'installed Viewflow unit candidate' "$VIEWFLOW_UNIT_INSTALLED" \
        "$viewflow_unit_expected_sha"
    assert_hash 'installed Deskflow drop-in candidate' "$DESKFLOW_DROPIN_INSTALLED" \
        "$deskflow_dropin_expected_sha"
    assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED" \
        'installed Deskflow drop-in candidate'
    assert_viewflow_unit_acceptance_contract "$VIEWFLOW_UNIT_INSTALLED" \
        'installed Viewflow unit candidate'
    assert_acceptance_state_dir
    # QUARANTINE_BOUNDARY: after-config-install
    assert_quarantine_storage_unchanged

    # TRANSACTION_PHASE: reload-runtime-unit-configuration
    systemctl --user daemon-reload
    assert_loaded_unit_configuration
    assert_acceptance_state_dir
    # QUARANTINE_BOUNDARY: after-reload
    assert_quarantine_storage_unchanged
    assert_acceptance_state_dir

    # TRANSACTION_PHASE: start-and-prove-viewflow-v2
    systemctl --user start "$VIEWFLOW_UNIT"
    assert_viewflow_ready "$viewflow_expected_sha" "$REQUIRED_VIEWFLOW_PROTOCOL"

    # TRANSACTION_PHASE: install-patched-deskflow
    atomic_install "$deskflow_candidate" "$DESKFLOW_INSTALLED" 0755
    atomic_install "$deskflow_core_candidate" "$DESKFLOW_CORE_INSTALLED" 0755
    assert_hash 'installed Deskflow candidate' "$DESKFLOW_INSTALLED" "$deskflow_expected_sha"
    assert_hash 'installed deskflow-core candidate' "$DESKFLOW_CORE_INSTALLED" "$deskflow_core_expected_sha"

    # TRANSACTION_PHASE: start-and-prove-patched-deskflow
    systemctl --user start "$DESKFLOW_UNIT"
    assert_deskflow_ready "$deskflow_expected_sha" "$deskflow_core_expected_sha"
    # QUARANTINE_BOUNDARY: after-deskflow-readiness
    assert_quarantine_storage_unchanged
    assert_acceptance_state_dir

    transaction_started=0
    trap - ERR INT TERM
    printf 'deployment complete\n'
    printf '  Viewflow SHA-256:      %s\n' "$viewflow_expected_sha"
    printf '  marker tool SHA-256:   %s\n' "$deployment_marker_tool_expected_sha"
    printf '  Deskflow SHA-256:      %s\n' "$deskflow_expected_sha"
    printf '  deskflow-core SHA-256: %s\n' "$deskflow_core_expected_sha"
    printf '  Viewflow unit SHA-256: %s\n' "$viewflow_unit_expected_sha"
    printf '  Deskflow drop-in SHA-256: %s\n' "$deskflow_dropin_expected_sha"
    printf '  rollback backup:       %s\n' "$backup_dir"
}

deploy_transaction
