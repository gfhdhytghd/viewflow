#!/usr/bin/env bash

# Gracefully deactivate the installed Linux Viewflow/Deskflow runtime and
# publish point-in-time, fail-closed evidence. This command never installs,
# replaces, starts, restarts, or force-kills a process.

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
readonly DESKFLOW_QUARANTINE_SIZE=152
readonly DESKFLOW_QUARANTINE_MAGIC=VFQST002
readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2
readonly DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly DEPLOYMENT_QUARANTINE_SIZE=256
readonly DEPLOYMENT_QUARANTINE_MAGIC=VFDQT001
readonly DEPLOYMENT_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1
readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock
readonly VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/post-release-acceptance.sock
readonly DESKFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock
readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/home/wilf/.local/state/viewflow/post-release-acceptance
readonly VIEWFLOW_PORT=44119
readonly DESKFLOW_PORT=24800
readonly STOP_TIMEOUT_SECONDS=30
readonly LEGACY_V13_VIEWFLOW_EXECSTART='ExecStart=/home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119 --cert /home/wilf/.local/share/viewflow/identity/peer.pem --key /home/wilf/.local/share/viewflow/identity/peer.key --ca /home/wilf/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002'
readonly LEGACY_V13_DROPIN_SIDECAR='Environment=DESKFLOW_VIEWFLOW_SIDECAR_SOCKET=/run/user/1000/viewflow/deskflow.sock'
readonly LEGACY_V13_DROPIN_SCREEN='Environment=DESKFLOW_VIEWFLOW_SCREEN=WindowsVM'
readonly LEGACY_V13_DROPIN_SOURCE='Environment=DESKFLOW_VIEWFLOW_SOURCE_DISPLAY=00000000000000000000000000000101'
readonly LEGACY_V13_DROPIN_ROUTE='Environment=DESKFLOW_VIEWFLOW_ROUTE_TO=00000000000000000000000000000002'

viewflow_expected_sha=
deployment_marker_tool_expected_sha=
deskflow_expected_sha=
deskflow_core_expected_sha=
viewflow_unit_expected_sha=
deskflow_dropin_expected_sha=
deskflow_quarantine_preflight_identity=
deskflow_quarantine_preflight_sha=
deployment_quarantine_preflight_identity=
deployment_quarantine_preflight_sha=
operation_id=
proof_output=
transcript_output=
runtime_marker_state=retained
bootstrap_v13_legacy_config=0

loaded_viewflow_fragment=
loaded_deskflow_dropins=
deactivation_started=0
transcript_published=0
proof_linked=0
proof_published=0
temporary_files=()

usage() {
    cat <<'EOF'
Usage:
  deactivate-viewflow-deskflow.sh \
    --viewflow-sha256 <installed viewflowd SHA-256> \
    --deployment-marker-sha256 <installed viewflow-deployment-marker SHA-256> \
    --deskflow-sha256 <installed deskflow SHA-256> \
    --deskflow-core-sha256 <installed deskflow-core SHA-256> \
    --viewflow-unit-sha256 <installed viewflow-peer.service SHA-256> \
    --deskflow-dropin-sha256 <installed deskflow viewflow.conf SHA-256> \
    [--runtime-marker-state retained|absent] \
    [--bootstrap-v1.3-legacy-config] \
    --operation-id <unique 16-128 character operation ID> \
    --transcript-output /absolute/new/path/viewflow-linux-deactivated.txt \
    --proof-output /absolute/new/path/viewflow-linux-deactivated.json

All six expected hashes are mandatory. The command validates the current
installed identity and loaded systemd configuration before stopping Deskflow
then Viewflow. It publishes proof only after both units, all four exact
executables, both listeners, and the sidecar socket are absent and a
daemon-reload has revalidated the same files and loaded paths.
The Deskflow runtime quarantine marker defaults to retained. In absent mode,
its path must remain completely absent, including as a dangling symlink; the
deployment quarantine marker remains mandatory in both modes. The transcript
and proof outputs must be different new files in the same owner-only directory.
The schema-3 proof binds the exact transcript basename and SHA-256. The
bootstrap-v1.3 legacy-config mode is reserved for the coordinator's bootstrap
recovery branch. It accepts only the frozen v1.3 unit/drop-in configuration,
requires an absent runtime marker, and never relaxes the normal-v2 contract.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    return 1
}

cleanup() {
    local path
    for path in "${temporary_files[@]}"; do
        [[ -n $path ]] && rm -f -- "$path"
    done
    if ((proof_linked && !proof_published)); then
        rm -f -- "$proof_output"
    fi
    if ((transcript_published && !proof_published)); then
        rm -f -- "$transcript_output"
    fi
}

handle_failure() {
    local status=$1
    trap - ERR INT TERM
    if ((deactivation_started)); then
        # Fail closed without escalating to a signal or reactivating anything.
        systemctl --user stop "$DESKFLOW_UNIT" >/dev/null 2>&1 || true
        systemctl --user stop "$VIEWFLOW_UNIT" >/dev/null 2>&1 || true
        printf '%s\n' \
            'deactivation failed after shutdown began; services were not restarted and no proof was published' >&2
    fi
    exit "$status"
}

trap cleanup EXIT
trap 'handle_failure $?' ERR
trap 'handle_failure 130' INT
trap 'handle_failure 143' TERM

require_value() {
    [[ -n ${2-} ]] || die "$1 requires a value"
}

while (($#)); do
    case $1 in
        --viewflow-sha256)
            require_value "$1" "${2-}"
            viewflow_expected_sha=${2,,}
            shift 2
            ;;
        --deployment-marker-sha256)
            require_value "$1" "${2-}"
            deployment_marker_tool_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-sha256)
            require_value "$1" "${2-}"
            deskflow_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-core-sha256)
            require_value "$1" "${2-}"
            deskflow_core_expected_sha=${2,,}
            shift 2
            ;;
        --viewflow-unit-sha256)
            require_value "$1" "${2-}"
            viewflow_unit_expected_sha=${2,,}
            shift 2
            ;;
        --deskflow-dropin-sha256)
            require_value "$1" "${2-}"
            deskflow_dropin_expected_sha=${2,,}
            shift 2
            ;;
        --runtime-marker-state)
            require_value "$1" "${2-}"
            runtime_marker_state=$2
            case $runtime_marker_state in
                retained|absent) ;;
                *) die '--runtime-marker-state must be retained or absent' ;;
            esac
            shift 2
            ;;
        --bootstrap-v1.3-legacy-config)
            ((bootstrap_v13_legacy_config == 0)) ||
                die '--bootstrap-v1.3-legacy-config may be supplied only once'
            bootstrap_v13_legacy_config=1
            shift
            ;;
        --operation-id)
            require_value "$1" "${2-}"
            operation_id=$2
            shift 2
            ;;
        --proof-output)
            require_value "$1" "${2-}"
            proof_output=$2
            shift 2
            ;;
        --transcript-output)
            require_value "$1" "${2-}"
            transcript_output=$2
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

sha256() {
    sha256sum -- "$1" | awk '{print tolower($1)}'
}

require_sha256() {
    [[ $2 =~ ^[0-9a-f]{64}$ ]] ||
        die "$1 must be exactly 64 hexadecimal characters"
}

require_installed_file() {
    local label=$1 path=$2 owner mode
    [[ -f $path && ! -L $path ]] ||
        die "$label must be a regular, non-symlink file: $path"
    owner=$(stat -c '%u' -- "$path")
    mode=$(stat -c '%a' -- "$path")
    [[ $owner == "$EXPECTED_UID" ]] || die "$label must be owned by uid $EXPECTED_UID"
    (( (8#$mode & 8#022) == 0 )) ||
        die "$label must not be group- or world-writable"
}

assert_quarantine_marker() {
    local label=$1 path=$2 expected_size=$3 expected_magic=$4
    local marker_owner marker_mode marker_links marker_size marker_magic
    [[ -e $path || -L $path ]] || die "$label must exist before deactivation preflight"
    [[ -f $path && ! -L $path ]] || die "$label must be a regular non-symlink file"
    read -r marker_owner marker_mode marker_links marker_size < <(
        stat -c '%u %a %h %s' -- "$path"
    )
    [[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&
       $marker_links == 1 && $marker_size == "$expected_size" ]] ||
        die "$label must be uid 1000, mode 0600, link count 1, and $expected_size bytes"
    marker_magic=$(LC_ALL=C head -c 8 -- "$path")
    [[ $marker_magic == "$expected_magic" ]] || die "$label magic must be $expected_magic"
}

assert_quarantine_storage() {
    local parent_owner parent_mode
    [[ -d $DESKFLOW_QUARANTINE_PARENT && ! -L $DESKFLOW_QUARANTINE_PARENT ]] ||
        die 'quarantine parent must be a real directory'
    read -r parent_owner parent_mode < <(
        stat -c '%u %a' -- "$DESKFLOW_QUARANTINE_PARENT"
    )
    [[ $parent_owner == "$EXPECTED_UID" && $parent_mode == 700 ]] ||
        die 'quarantine parent must be owned by uid 1000 with mode 0700'
    case $runtime_marker_state in
        retained)
            assert_quarantine_marker 'Deskflow runtime quarantine marker' \
                "$DESKFLOW_QUARANTINE_MARKER" "$DESKFLOW_QUARANTINE_SIZE" \
                "$DESKFLOW_QUARANTINE_MAGIC"
            ;;
        absent)
            [[ ! -e $DESKFLOW_QUARANTINE_MARKER && \
               ! -L $DESKFLOW_QUARANTINE_MARKER ]] ||
                die 'Deskflow runtime quarantine marker must remain completely absent'
            ;;
        *)
            die 'internal runtime marker state is invalid'
            ;;
    esac
    assert_quarantine_marker 'deployment quarantine marker' \
        "$DEPLOYMENT_QUARANTINE_MARKER" "$DEPLOYMENT_QUARANTINE_SIZE" \
        "$DEPLOYMENT_QUARANTINE_MAGIC"
}

# This directory contains runtime acceptance receipts.  Deactivation validates
# it but deliberately does not back it up, replace it, or remove any receipt.
assert_acceptance_state_dir() {
    local owner mode
    [[ -d $VIEWFLOW_ACCEPTANCE_STATE_DIR && ! -L $VIEWFLOW_ACCEPTANCE_STATE_DIR ]] ||
        die 'post-release acceptance state directory must be a real directory'
    read -r owner mode < <(stat -c '%u %a' -- "$VIEWFLOW_ACCEPTANCE_STATE_DIR")
    [[ $owner == "$EXPECTED_UID" && $mode == 700 ]] ||
        die 'post-release acceptance state directory must be owned by uid 1000 with mode 0700'
}

evidence_identity() {
    stat -c '%d:%i' -- "$1"
}

freeze_quarantine_storage() {
    assert_quarantine_storage
    case $runtime_marker_state in
        retained)
            deskflow_quarantine_preflight_identity=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")
            deskflow_quarantine_preflight_sha=$(sha256 "$DESKFLOW_QUARANTINE_MARKER")
            ;;
        absent)
            deskflow_quarantine_preflight_identity=absent
            deskflow_quarantine_preflight_sha=absent
            ;;
    esac
    deployment_quarantine_preflight_identity=$(evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER")
    deployment_quarantine_preflight_sha=$(sha256 "$DEPLOYMENT_QUARANTINE_MARKER")
    assert_quarantine_storage_unchanged
}

assert_quarantine_storage_unchanged() {
    local deskflow_identity_before deskflow_identity_after
    local deployment_identity_before deployment_identity_after
    [[ -n $deployment_quarantine_preflight_identity &&
       $deployment_quarantine_preflight_sha =~ ^[0-9a-f]{64}$ ]] ||
        die 'deployment quarantine marker identity must be frozen at preflight'
    assert_quarantine_storage
    case $runtime_marker_state in
        retained)
            [[ -n $deskflow_quarantine_preflight_identity &&
               $deskflow_quarantine_preflight_sha =~ ^[0-9a-f]{64}$ ]] ||
                die 'Deskflow runtime quarantine marker identity must be frozen at preflight'
            deskflow_identity_before=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")
            [[ $deskflow_identity_before == "$deskflow_quarantine_preflight_identity" ]] ||
                die 'Deskflow runtime quarantine marker inode changed after preflight'
            assert_hash 'Deskflow runtime quarantine marker' "$DESKFLOW_QUARANTINE_MARKER" \
                "$deskflow_quarantine_preflight_sha"
            deskflow_identity_after=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")
            [[ $deskflow_identity_after == "$deskflow_identity_before" ]] ||
                die 'Deskflow runtime quarantine marker inode changed while hashing'
            ;;
        absent)
            [[ $deskflow_quarantine_preflight_identity == absent &&
               $deskflow_quarantine_preflight_sha == absent ]] ||
                die 'Deskflow runtime quarantine marker absence must be frozen at preflight'
            ;;
    esac

    deployment_identity_before=$(evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER")
    [[ $deployment_identity_before == "$deployment_quarantine_preflight_identity" ]] ||
        die 'deployment quarantine marker inode changed after preflight'
    assert_hash 'deployment quarantine marker' "$DEPLOYMENT_QUARANTINE_MARKER" \
        "$deployment_quarantine_preflight_sha"
    deployment_identity_after=$(evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER")
    [[ $deployment_identity_after == "$deployment_identity_before" ]] ||
        die 'deployment quarantine marker inode changed while hashing'
    assert_quarantine_storage
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

assert_bootstrap_v13_legacy_dropin_contract() {
    local path=$1 label=$2
    [[ $(wc -l <"$path") == 5 &&
       $(grep -Fxc '[Service]' "$path") == 1 &&
       $(grep -Fxc "$LEGACY_V13_DROPIN_SIDECAR" "$path") == 1 &&
       $(grep -Fxc "$LEGACY_V13_DROPIN_SCREEN" "$path") == 1 &&
       $(grep -Fxc "$LEGACY_V13_DROPIN_SOURCE" "$path") == 1 &&
       $(grep -Fxc "$LEGACY_V13_DROPIN_ROUTE" "$path") == 1 ]] ||
        die "$label must be the exact four-setting bootstrap-v1.3 drop-in"
    [[ $(grep -Fc 'DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=' "$path") == 0 &&
       $(grep -Fc 'DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=' "$path") == 0 &&
       $(grep -Fc 'DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=' "$path") == 0 ]] ||
        die "$label must not contain normal-v2 quarantine or acceptance settings"
}

assert_bootstrap_v13_legacy_unit_contract() {
    local path=$1 label=$2 option
    [[ $(grep -Fc 'ExecStart' "$path") == 1 &&
       $(grep -Fxc "$LEGACY_V13_VIEWFLOW_EXECSTART" "$path") == 1 ]] ||
        die "$label must contain the exact bootstrap-v1.3 Viewflow ExecStart"
    for option in --quiesce-proof --quiesce-arm-file --acceptance-socket \
        --acceptance-state-dir; do
        [[ $(grep -Fc -- "$option" "$path") == 0 ]] ||
            die "$label must not contain normal-v2 option $option"
    done
}

assert_installed_configuration_contract() {
    case $bootstrap_v13_legacy_config in
        0)
            assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED" \
                'installed Deskflow drop-in'
            assert_viewflow_unit_acceptance_contract "$VIEWFLOW_UNIT_INSTALLED" \
                'installed Viewflow unit'
            assert_acceptance_state_dir
            ;;
        1)
            [[ $runtime_marker_state == absent ]] ||
                die 'bootstrap-v1.3 legacy-config requires --runtime-marker-state absent'
            assert_bootstrap_v13_legacy_dropin_contract "$DESKFLOW_DROPIN_INSTALLED" \
                'installed Deskflow drop-in'
            assert_bootstrap_v13_legacy_unit_contract "$VIEWFLOW_UNIT_INSTALLED" \
                'installed Viewflow unit'
            ;;
        *)
            die 'internal installed configuration mode is invalid'
            ;;
    esac
}

assert_configuration_runtime_evidence() {
    assert_acceptance_runtime_sockets_absent
    if ((bootstrap_v13_legacy_config == 0)); then
        assert_acceptance_state_dir
    fi
}

assert_acceptance_runtime_sockets_absent() {
    [[ ! -e $VIEWFLOW_ACCEPTANCE_SOCKET && ! -L $VIEWFLOW_ACCEPTANCE_SOCKET ]] ||
        die 'Viewflow post-release acceptance socket remains after shutdown'
    [[ ! -e $DESKFLOW_ACCEPTANCE_SOCKET && ! -L $DESKFLOW_ACCEPTANCE_SOCKET ]] ||
        die 'Deskflow post-release acceptance socket remains after shutdown'
}

assert_hash() {
    local label=$1 path=$2 expected=$3 actual
    actual=$(sha256 "$path")
    [[ $actual == "$expected" ]] ||
        die "$label SHA-256 mismatch: expected $expected, got $actual"
}

assert_installed_hashes() {
    assert_hash 'installed Viewflow' "$VIEWFLOW_INSTALLED" "$viewflow_expected_sha"
    assert_hash 'installed deployment marker tool' "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
        "$deployment_marker_tool_expected_sha"
    assert_hash 'installed Deskflow' "$DESKFLOW_INSTALLED" "$deskflow_expected_sha"
    assert_hash 'installed deskflow-core' "$DESKFLOW_CORE_INSTALLED" \
        "$deskflow_core_expected_sha"
    assert_hash 'installed Viewflow unit' "$VIEWFLOW_UNIT_INSTALLED" \
        "$viewflow_unit_expected_sha"
    assert_hash 'installed Deskflow drop-in' "$DESKFLOW_DROPIN_INSTALLED" \
        "$deskflow_dropin_expected_sha"
}

exact_executable_pids() {
    local expected=$1 proc exe
    for proc in /proc/[0-9]*; do
        [[ -e $proc/exe ]] || continue
        exe=$(readlink -f -- "$proc/exe" 2>/dev/null || true)
        [[ $exe == "$expected" ]] && printf '%s\n' "${proc##*/}"
    done
    return 0
}

assert_deployment_marker_tool_stopped() {
    [[ -z $(exact_executable_pids "$DEPLOYMENT_MARKER_TOOL_INSTALLED") ]] ||
        die 'viewflow-deployment-marker is running; coordinator lifecycle must be quiescent'
}

count_nonempty_lines() {
    awk 'NF { count += 1 } END { print count + 0 }'
}

unit_property() {
    systemctl --user show --property "$2" --value "$1"
}

assert_loaded_unit_configuration() {
    local fragment fragment_canonical dropins
    fragment=$(unit_property "$VIEWFLOW_UNIT" FragmentPath)
    [[ -n $fragment ]] || die 'systemd returned an empty Viewflow FragmentPath'
    fragment_canonical=$(readlink -f -- "$fragment")
    [[ $fragment_canonical == "$VIEWFLOW_UNIT_INSTALLED" ]] ||
        die 'systemd did not load the fixed Viewflow unit path'

    dropins=$(unit_property "$DESKFLOW_UNIT" DropInPaths)
    [[ " $dropins " == *" $DESKFLOW_DROPIN_INSTALLED "* ]] ||
        die 'systemd did not load the fixed Deskflow drop-in path'

    loaded_viewflow_fragment=$fragment_canonical
    loaded_deskflow_dropins=$dropins
}

deskflow_is_fully_stopped() {
    local state main_pid deskflow_pids core_pids tcp_output
    state=$(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true)
    main_pid=$(unit_property "$DESKFLOW_UNIT" MainPID 2>/dev/null || true)
    deskflow_pids=$(exact_executable_pids "$DESKFLOW_INSTALLED")
    core_pids=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    tcp_output=$(ss -H -ltn "sport = :$DESKFLOW_PORT")
    [[ $state == inactive && ${main_pid:-0} == 0 && -z $deskflow_pids &&
       -z $core_pids && -z $tcp_output ]]
}

viewflow_is_fully_stopped() {
    local state main_pid viewflow_pids udp_output
    state=$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true)
    main_pid=$(unit_property "$VIEWFLOW_UNIT" MainPID 2>/dev/null || true)
    viewflow_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
    udp_output=$(ss -H -lun "sport = :$VIEWFLOW_PORT")
    [[ $state == inactive && ${main_pid:-0} == 0 && -z $viewflow_pids &&
       -z $udp_output && ! -e $VIEWFLOW_SIDECAR && ! -L $VIEWFLOW_SIDECAR ]] &&
        assert_configuration_runtime_evidence
}

wait_for_deskflow_stopped() {
    local deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
    while ((SECONDS < deadline)); do
        deskflow_is_fully_stopped && return 0
        sleep 0.1
    done
    die 'Deskflow did not reach inactive/MainPID=0 with exact processes and TCP listener absent'
}

wait_for_viewflow_stopped() {
    local deadline=$((SECONDS + STOP_TIMEOUT_SECONDS))
    while ((SECONDS < deadline)); do
        viewflow_is_fully_stopped && return 0
        sleep 0.1
    done
    die 'Viewflow did not reach inactive/MainPID=0 with its exact process, UDP listener, and sidecar absent'
}

preflight() {
    local proof_parent proof_parent_mode transcript_parent path
    [[ $(id -u) == "$EXPECTED_UID" && $HOME == "$EXPECTED_HOME" ]] ||
        die "run as uid $EXPECTED_UID with HOME=$EXPECTED_HOME"
    for command in awk basename chmod date dirname grep head id jq ln mktemp readlink rm sha256sum sleep ss stat systemctl wc; do
        command -v "$command" >/dev/null || die "required command is unavailable: $command"
    done
    # QUARANTINE_BOUNDARY: preflight
    freeze_quarantine_storage

    require_sha256 '--viewflow-sha256' "$viewflow_expected_sha"
    require_sha256 '--deployment-marker-sha256' "$deployment_marker_tool_expected_sha"
    require_sha256 '--deskflow-sha256' "$deskflow_expected_sha"
    require_sha256 '--deskflow-core-sha256' "$deskflow_core_expected_sha"
    require_sha256 '--viewflow-unit-sha256' "$viewflow_unit_expected_sha"
    require_sha256 '--deskflow-dropin-sha256' "$deskflow_dropin_expected_sha"
    [[ ${#operation_id} -ge 16 && ${#operation_id} -le 128 &&
       $operation_id =~ ^[A-Za-z0-9_-]+$ ]] ||
        die 'operation ID must be 16-128 ASCII letters, digits, hyphens, or underscores'

    [[ $proof_output == /* ]] || die '--proof-output must be an absolute path'
    [[ $transcript_output == /* ]] || die '--transcript-output must be an absolute path'
    [[ $proof_output != "$transcript_output" ]] ||
        die 'proof and transcript outputs must be different paths'
    [[ ! -e $proof_output && ! -L $proof_output ]] ||
        die 'proof output already exists; deactivation proof is one-shot'
    [[ ! -e $transcript_output && ! -L $transcript_output ]] ||
        die 'transcript output already exists; deactivation transcript is one-shot'
    proof_parent=$(dirname -- "$proof_output")
    transcript_parent=$(dirname -- "$transcript_output")
    [[ $proof_parent == "$transcript_parent" ]] ||
        die 'proof and transcript outputs must share the same directory'
    [[ -d $proof_parent && ! -L $proof_parent ]] ||
        die 'proof output parent must be a real directory'
    [[ $(stat -c '%u' -- "$proof_parent") == "$EXPECTED_UID" ]] ||
        die "proof output parent must be owned by uid $EXPECTED_UID"
    proof_parent_mode=$(stat -c '%a' -- "$proof_parent")
    (( (8#$proof_parent_mode & 8#077) == 0 )) ||
        die 'proof output parent must not be accessible by group or other users'

    for path in "$VIEWFLOW_INSTALLED" "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
        "$DESKFLOW_INSTALLED" \
        "$DESKFLOW_CORE_INSTALLED" "$VIEWFLOW_UNIT_INSTALLED" \
        "$DESKFLOW_DROPIN_INSTALLED"; do
        require_installed_file 'installed artifact' "$path"
    done
    [[ -x $VIEWFLOW_INSTALLED && -x $DEPLOYMENT_MARKER_TOOL_INSTALLED && \
       -x $DESKFLOW_INSTALLED && -x $DESKFLOW_CORE_INSTALLED ]] ||
        die 'all four installed executables must be executable'
    [[ $(stat -c '%u:%a:%h' -- "$DEPLOYMENT_MARKER_TOOL_INSTALLED") == \
       "$EXPECTED_UID:755:1" ]] ||
        die 'installed deployment marker tool must be uid 1000 mode 0755 link count 1'
    assert_deployment_marker_tool_stopped
    assert_installed_configuration_contract
}

publish_proof() {
    local transcript_temp proof_temp completed_at_ms boot_id transcript_sha
    local published_transcript_sha transcript_file_name
    local deskflow_state deskflow_main_pid deskflow_pids core_pids tcp_output
    local viewflow_state viewflow_main_pid viewflow_pids udp_output sidecar_present
    local deployment_marker_tool_pids
    local deskflow_count core_count viewflow_count deployment_marker_tool_count tcp_count udp_count

    # QUARANTINE_BOUNDARY: proof-observation
    assert_quarantine_storage_unchanged
    deskflow_state=$(systemctl --user is-active "$DESKFLOW_UNIT" 2>/dev/null || true)
    deskflow_main_pid=$(unit_property "$DESKFLOW_UNIT" MainPID)
    deskflow_pids=$(exact_executable_pids "$DESKFLOW_INSTALLED")
    core_pids=$(exact_executable_pids "$DESKFLOW_CORE_INSTALLED")
    tcp_output=$(ss -H -ltn "sport = :$DESKFLOW_PORT")
    viewflow_state=$(systemctl --user is-active "$VIEWFLOW_UNIT" 2>/dev/null || true)
    viewflow_main_pid=$(unit_property "$VIEWFLOW_UNIT" MainPID)
    viewflow_pids=$(exact_executable_pids "$VIEWFLOW_INSTALLED")
    deployment_marker_tool_pids=$(exact_executable_pids "$DEPLOYMENT_MARKER_TOOL_INSTALLED")
    udp_output=$(ss -H -lun "sport = :$VIEWFLOW_PORT")
    [[ -e $VIEWFLOW_SIDECAR ]] && sidecar_present=true || sidecar_present=false

    deskflow_count=$(printf '%s\n' "$deskflow_pids" | count_nonempty_lines)
    core_count=$(printf '%s\n' "$core_pids" | count_nonempty_lines)
    viewflow_count=$(printf '%s\n' "$viewflow_pids" | count_nonempty_lines)
    deployment_marker_tool_count=$(printf '%s\n' "$deployment_marker_tool_pids" | \
        count_nonempty_lines)
    tcp_count=$(printf '%s\n' "$tcp_output" | count_nonempty_lines)
    udp_count=$(printf '%s\n' "$udp_output" | count_nonempty_lines)

    [[ $deskflow_state == inactive && $deskflow_main_pid == 0 &&
       $deskflow_count == 0 && $core_count == 0 && $tcp_count == 0 ]] ||
        die 'Deskflow changed after final stopped-state verification'
    [[ $viewflow_state == inactive && $viewflow_main_pid == 0 &&
       $viewflow_count == 0 && $udp_count == 0 && $sidecar_present == false ]] ||
        die 'Viewflow changed after final stopped-state verification'
    assert_configuration_runtime_evidence
    [[ $deployment_marker_tool_count == 0 ]] ||
        die 'deployment marker tool started during deactivation proof observation'

    transcript_temp=$(mktemp --tmpdir="$(dirname -- "$transcript_output")" \
        '.viewflow-linux-deactivate-transcript.XXXXXX')
    temporary_files+=("$transcript_temp")
    chmod 0600 "$transcript_temp"
    {
        printf 'deskflow_systemctl_is_active=%s\n' "$deskflow_state"
        printf 'runtime_marker_state=%s\n' "$runtime_marker_state"
        printf 'deskflow_systemctl_main_pid=%s\n' "$deskflow_main_pid"
        printf 'deskflow_exact_pids=%s\n' "$deskflow_pids"
        printf 'deskflow_core_exact_pids=%s\n' "$core_pids"
        printf 'tcp_24800_listeners=%s\n' "$tcp_output"
        printf 'viewflow_systemctl_is_active=%s\n' "$viewflow_state"
        printf 'viewflow_systemctl_main_pid=%s\n' "$viewflow_main_pid"
        printf 'viewflow_exact_pids=%s\n' "$viewflow_pids"
        printf 'deployment_marker_tool_exact_pids=%s\n' "$deployment_marker_tool_pids"
        printf 'udp_44119_listeners=%s\n' "$udp_output"
        printf 'sidecar_socket_present=%s\n' "$sidecar_present"
        printf 'daemon_reload_completed=true\n'
        printf 'viewflow_fragment_path=%s\n' "$loaded_viewflow_fragment"
        printf 'deskflow_dropin_paths=%s\n' "$loaded_deskflow_dropins"
        printf 'viewflow_sha256=%s\n' "$viewflow_expected_sha"
        printf 'deployment_marker_tool_sha256=%s\n' "$deployment_marker_tool_expected_sha"
        printf 'deskflow_sha256=%s\n' "$deskflow_expected_sha"
        printf 'deskflow_core_sha256=%s\n' "$deskflow_core_expected_sha"
        printf 'viewflow_unit_sha256=%s\n' "$viewflow_unit_expected_sha"
        printf 'deskflow_dropin_sha256=%s\n' "$deskflow_dropin_expected_sha"
    } >"$transcript_temp"
    [[ $(stat -c '%u:%a' -- "$transcript_temp") == "$EXPECTED_UID:600" ]] ||
        die 'temporary transcript owner or mode is not uid 1000 mode 0600'
    transcript_sha=$(sha256 "$transcript_temp")
    ln -- "$transcript_temp" "$transcript_output" ||
        die 'transcript output appeared concurrently'
    transcript_published=1
    [[ $(stat -c '%u:%a' -- "$transcript_output") == "$EXPECTED_UID:600" ]] ||
        die 'published transcript owner or mode is not uid 1000 mode 0600'
    published_transcript_sha=$(sha256 "$transcript_output")
    [[ $published_transcript_sha == "$transcript_sha" ]] ||
        die 'published transcript SHA-256 differs from the verified temporary transcript'
    transcript_file_name=$(basename -- "$transcript_output")
    boot_id=$(tr -d '\r\n' </proc/sys/kernel/random/boot_id)
    [[ $boot_id =~ ^[0-9a-f]{8}-[0-9a-f-]{27,}$ ]] || die 'Linux boot ID is invalid'
    completed_at_ms=$(date -u +%s%3N)

    proof_temp=$(mktemp --tmpdir="$(dirname -- "$proof_output")" \
        '.viewflow-linux-deactivated.XXXXXX')
    temporary_files+=("$proof_temp")
    chmod 0600 "$proof_temp"
    jq -n \
        --arg operation_id "$operation_id" --arg boot_id "$boot_id" \
        --arg viewflow_path "$VIEWFLOW_INSTALLED" --arg viewflow_sha "$viewflow_expected_sha" \
        --arg marker_tool_path "$DEPLOYMENT_MARKER_TOOL_INSTALLED" \
        --arg marker_tool_sha "$deployment_marker_tool_expected_sha" \
        --arg deskflow_path "$DESKFLOW_INSTALLED" --arg deskflow_sha "$deskflow_expected_sha" \
        --arg core_path "$DESKFLOW_CORE_INSTALLED" --arg core_sha "$deskflow_core_expected_sha" \
        --arg unit_path "$VIEWFLOW_UNIT_INSTALLED" --arg unit_sha "$viewflow_unit_expected_sha" \
        --arg dropin_path "$DESKFLOW_DROPIN_INSTALLED" --arg dropin_sha "$deskflow_dropin_expected_sha" \
        --arg fragment_path "$loaded_viewflow_fragment" --arg dropin_paths "$loaded_deskflow_dropins" \
        --arg transcript_file_name "$transcript_file_name" \
        --arg transcript_sha "$published_transcript_sha" \
        --argjson completed_at_unix_ms "$completed_at_ms" \
        '{schema_version: 3, state: "viewflow-linux-deactivated",
          operation_id: $operation_id,
          identity: {uid: 1000, home: "/home/wilf", boot_id: $boot_id},
          installed_artifacts: {
            viewflowd: {path: $viewflow_path, sha256: $viewflow_sha},
            deployment_marker_tool: {path: $marker_tool_path, sha256: $marker_tool_sha},
            deskflow: {path: $deskflow_path, sha256: $deskflow_sha},
            deskflow_core: {path: $core_path, sha256: $core_sha},
            viewflow_unit: {path: $unit_path, sha256: $unit_sha},
            deskflow_dropin: {path: $dropin_path, sha256: $dropin_sha}},
          loaded_configuration: {
            daemon_reload_completed: true,
            viewflow_fragment_path: $fragment_path,
            deskflow_dropin_paths: $dropin_paths},
          stopped_runtime: {
            deployment_marker_tool: {exact_process_count: 0},
            deskflow: {unit_active_state: "inactive", main_pid: 0,
                       exact_process_count: 0, core_exact_process_count: 0,
                       tcp_24800_listener_count: 0},
            viewflow: {unit_active_state: "inactive", main_pid: 0,
                       exact_process_count: 0, udp_44119_listener_count: 0,
                       sidecar_socket_present: false}},
          observation: {
            command_output_format: "key=value newline-delimited UTF-8 in displayed order",
            command_output_file_name: $transcript_file_name,
            command_output_sha256: $transcript_sha,
            completed_at_unix_ms: $completed_at_unix_ms}}' >"$proof_temp"
    [[ $(stat -c '%a' -- "$proof_temp") == 600 ]] ||
        die 'temporary proof mode is not 0600'

    # Recheck mutable files and stopped state at the publication boundary.
    assert_installed_hashes
    assert_loaded_unit_configuration
    assert_installed_configuration_contract
    assert_quarantine_storage_unchanged
    assert_configuration_runtime_evidence
    assert_deployment_marker_tool_stopped
    deskflow_is_fully_stopped || die 'Deskflow changed at proof publication boundary'
    viewflow_is_fully_stopped || die 'Viewflow changed at proof publication boundary'
    assert_configuration_runtime_evidence
    [[ $(stat -c '%u:%a' -- "$transcript_output") == "$EXPECTED_UID:600" ]] ||
        die 'transcript owner or mode changed at proof publication boundary'
    [[ $(sha256 "$transcript_output") == "$published_transcript_sha" ]] ||
        die 'transcript changed at proof publication boundary'
    # QUARANTINE_BOUNDARY: proof-commit
    assert_quarantine_storage_unchanged
    ln -- "$proof_temp" "$proof_output" || die 'proof output appeared concurrently'
    proof_linked=1
    # QUARANTINE_BOUNDARY: proof-publication
    assert_quarantine_storage_unchanged
    proof_published=1
    # The no-clobber hard link is the proof commit point; cleanup and status
    # output after it must not turn a committed proof into a reported failure.
    rm -f -- "$proof_temp" || true
    printf 'Linux Viewflow/Deskflow deactivation proof written: %s\n' "$proof_output" || true
}

deactivate_runtime() {
    preflight

    # DEACTIVATION_PHASE: verify-installed-identity
    assert_installed_hashes
    assert_loaded_unit_configuration
    assert_deployment_marker_tool_stopped
    # QUARANTINE_BOUNDARY: before-shutdown
    assert_quarantine_storage_unchanged

    deactivation_started=1
    # DEACTIVATION_PHASE: stop-deskflow-before-viewflow
    systemctl --user stop "$DESKFLOW_UNIT"
    wait_for_deskflow_stopped
    # QUARANTINE_BOUNDARY: after-stop-deskflow
    assert_quarantine_storage_unchanged

    # DEACTIVATION_PHASE: stop-viewflow
    systemctl --user stop "$VIEWFLOW_UNIT"
    wait_for_viewflow_stopped
    # QUARANTINE_BOUNDARY: after-stop-viewflow
    assert_quarantine_storage_unchanged

    # DEACTIVATION_PHASE: reload-and-reverify
    systemctl --user daemon-reload
    assert_installed_hashes
    assert_loaded_unit_configuration
    assert_deployment_marker_tool_stopped
    # QUARANTINE_BOUNDARY: after-reload
    assert_quarantine_storage_unchanged
    deskflow_is_fully_stopped || die 'Deskflow is not fully stopped after daemon-reload'
    viewflow_is_fully_stopped || die 'Viewflow is not fully stopped after daemon-reload'

    # DEACTIVATION_PHASE: publish-fail-closed-proof
    publish_proof

    deactivation_started=0
    trap - ERR INT TERM
}

deactivate_runtime
