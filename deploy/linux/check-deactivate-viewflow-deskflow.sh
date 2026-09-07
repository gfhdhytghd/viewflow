#!/usr/bin/env bash
# shellcheck disable=SC2016

# Static audit for the standalone Linux deactivation contract. An optional
# script path is accepted only so the source-mutation test can exercise it.
# The explicit --proof/--transcript mode validates a published artifact pair
# offline and never invokes systemctl or the deactivator.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
DEACTIVATOR=$SCRIPT_DIR/deactivate-viewflow-deskflow.sh
artifact_proof=
artifact_transcript=

fail() {
    printf 'Linux deactivation static check failed: %s\n' "$*" >&2
    exit 1
}

require_fixed() {
    grep -Fq -- "$1" "$DEACTIVATOR" || fail "missing $2"
}

usage() {
    cat <<EOF
Usage:
  ${0##*/} [path/to/deactivate-viewflow-deskflow.sh]
  ${0##*/} --proof /absolute/path/proof.json --transcript /absolute/path/transcript.txt
EOF
}

validate_private_artifact() {
    local label=$1 path=$2
    [[ $path == /* ]] || fail "$label path must be absolute"
    [[ -f $path && ! -L $path ]] ||
        fail "$label must be a regular, non-symlink file"
    [[ $(stat -c '%u:%a' -- "$path") == '1000:600' ]] ||
        fail "$label must be owned by uid 1000 with mode 0600"
}

validate_artifact_pair() {
    local proof_parent transcript_parent
    validate_private_artifact 'proof' "$artifact_proof"
    validate_private_artifact 'transcript' "$artifact_transcript"
    proof_parent=$(readlink -f -- "$(dirname -- "$artifact_proof")")
    transcript_parent=$(readlink -f -- "$(dirname -- "$artifact_transcript")")
    [[ $proof_parent == "$transcript_parent" ]] ||
        fail 'proof and transcript must be in the same directory'
    [[ $(readlink -f -- "$artifact_proof") != $(readlink -f -- "$artifact_transcript") ]] ||
        fail 'proof and transcript must be different files'

    python3 - "$artifact_proof" "$artifact_transcript" <<'PY'
import hashlib
import json
import os
import re
import sys


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def exact_keys(value, expected, label):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise ValueError(f"{label} does not have the exact key set")


def require_sha(value, label):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise ValueError(f"{label} is not a lowercase SHA-256")


proof_path, transcript_path = sys.argv[1:]
try:
    with open(proof_path, "r", encoding="utf-8") as proof_file:
        proof = json.load(proof_file, object_pairs_hook=reject_duplicate_keys)
    with open(transcript_path, "rb") as transcript_file:
        transcript_bytes = transcript_file.read()
    transcript_text = transcript_bytes.decode("utf-8")

    exact_keys(
        proof,
        ["schema_version", "state", "operation_id", "identity",
         "installed_artifacts", "loaded_configuration", "stopped_runtime",
         "observation"],
        "proof",
    )
    if type(proof["schema_version"]) is not int or proof["schema_version"] != 3:
        raise ValueError("proof schema_version is not integer 3")
    if proof["state"] != "viewflow-linux-deactivated":
        raise ValueError("proof state is invalid")
    if not isinstance(proof["operation_id"], str) or re.fullmatch(
        r"[A-Za-z0-9_-]{16,128}", proof["operation_id"]
    ) is None:
        raise ValueError("proof operation_id is invalid")

    identity = proof["identity"]
    exact_keys(identity, ["uid", "home", "boot_id"], "identity")
    if type(identity["uid"]) is not int or identity["uid"] != 1000 or (
        identity["home"] != "/home/wilf"
    ):
        raise ValueError("proof uid/home identity is invalid")
    if not isinstance(identity["boot_id"], str) or re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f-]{27,}", identity["boot_id"]
    ) is None:
        raise ValueError("proof boot_id is invalid")

    artifacts = proof["installed_artifacts"]
    artifact_paths = {
        "viewflowd": "/home/wilf/.local/lib/viewflow/viewflowd",
        "deployment_marker_tool": "/home/wilf/.local/lib/viewflow/viewflow-deployment-marker",
        "deskflow": "/home/wilf/.local/lib/deskflow-scale-fix/deskflow",
        "deskflow_core": "/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core",
        "viewflow_unit": "/home/wilf/.config/systemd/user/viewflow-peer.service",
        "deskflow_dropin": "/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf",
    }
    exact_keys(artifacts, artifact_paths, "installed_artifacts")
    for key, expected_path in artifact_paths.items():
        exact_keys(artifacts[key], ["path", "sha256"], f"installed_artifacts.{key}")
        if artifacts[key]["path"] != expected_path:
            raise ValueError(f"installed_artifacts.{key}.path is invalid")
        require_sha(artifacts[key]["sha256"], f"installed_artifacts.{key}.sha256")

    loaded = proof["loaded_configuration"]
    exact_keys(
        loaded,
        ["daemon_reload_completed", "viewflow_fragment_path", "deskflow_dropin_paths"],
        "loaded_configuration",
    )
    if loaded["daemon_reload_completed"] is not True:
        raise ValueError("daemon_reload_completed is not true")
    if loaded["viewflow_fragment_path"] != artifact_paths["viewflow_unit"]:
        raise ValueError("loaded Viewflow fragment is invalid")
    if not isinstance(loaded["deskflow_dropin_paths"], str) or (
        artifact_paths["deskflow_dropin"] not in loaded["deskflow_dropin_paths"].split()
    ):
        raise ValueError("loaded Deskflow drop-in list is invalid")

    stopped = proof["stopped_runtime"]
    exact_keys(
        stopped,
        ["deployment_marker_tool", "deskflow", "viewflow"],
        "stopped_runtime",
    )
    exact_keys(
        stopped["deployment_marker_tool"],
        ["exact_process_count"],
        "stopped_runtime.deployment_marker_tool",
    )
    marker_tool_count = stopped["deployment_marker_tool"]["exact_process_count"]
    if type(marker_tool_count) is not int or marker_tool_count != 0:
        raise ValueError("deployment marker tool stopped runtime is invalid")
    exact_keys(
        stopped["deskflow"],
        ["unit_active_state", "main_pid", "exact_process_count",
         "core_exact_process_count", "tcp_24800_listener_count"],
        "stopped_runtime.deskflow",
    )
    exact_keys(
        stopped["viewflow"],
        ["unit_active_state", "main_pid", "exact_process_count",
         "udp_44119_listener_count", "sidecar_socket_present"],
        "stopped_runtime.viewflow",
    )
    if stopped["deskflow"] != {
        "unit_active_state": "inactive", "main_pid": 0,
        "exact_process_count": 0, "core_exact_process_count": 0,
        "tcp_24800_listener_count": 0,
    }:
        raise ValueError("Deskflow stopped runtime is invalid")
    if stopped["viewflow"] != {
        "unit_active_state": "inactive", "main_pid": 0,
        "exact_process_count": 0, "udp_44119_listener_count": 0,
        "sidecar_socket_present": False,
    }:
        raise ValueError("Viewflow stopped runtime is invalid")
    for label, runtime, integer_fields in [
        ("deskflow", stopped["deskflow"], ["main_pid", "exact_process_count",
                                           "core_exact_process_count",
                                           "tcp_24800_listener_count"]),
        ("viewflow", stopped["viewflow"], ["main_pid", "exact_process_count",
                                           "udp_44119_listener_count"]),
    ]:
        if any(type(runtime[field]) is not int for field in integer_fields):
            raise ValueError(f"{label} stopped runtime count is not an integer")
    if type(stopped["viewflow"]["sidecar_socket_present"]) is not bool:
        raise ValueError("sidecar_socket_present is not a boolean")

    observation = proof["observation"]
    exact_keys(
        observation,
        ["command_output_format", "command_output_file_name",
         "command_output_sha256", "completed_at_unix_ms"],
        "observation",
    )
    if observation["command_output_format"] != (
        "key=value newline-delimited UTF-8 in displayed order"
    ):
        raise ValueError("observation format is invalid")
    if observation["command_output_file_name"] != os.path.basename(transcript_path):
        raise ValueError("proof does not bind the transcript basename")
    transcript_sha = hashlib.sha256(transcript_bytes).hexdigest()
    if observation["command_output_sha256"] != transcript_sha:
        raise ValueError("proof does not bind the exact transcript bytes")
    completed = observation["completed_at_unix_ms"]
    if type(completed) is not int or completed < 0:
        raise ValueError("completion timestamp is invalid")

    if not transcript_text.endswith("\n"):
        raise ValueError("transcript is not newline terminated")
    lines = transcript_text[:-1].split("\n")
    pairs = []
    for line in lines:
        if "=" not in line:
            raise ValueError("transcript contains a non key=value line")
        pairs.append(line.split("=", 1))
    expected_pairs = [
        ["deskflow_systemctl_is_active", "inactive"],
        ["runtime_marker_state", None],
        ["deskflow_systemctl_main_pid", "0"],
        ["deskflow_exact_pids", ""],
        ["deskflow_core_exact_pids", ""],
        ["tcp_24800_listeners", ""],
        ["viewflow_systemctl_is_active", "inactive"],
        ["viewflow_systemctl_main_pid", "0"],
        ["viewflow_exact_pids", ""],
        ["deployment_marker_tool_exact_pids", ""],
        ["udp_44119_listeners", ""],
        ["sidecar_socket_present", "false"],
        ["daemon_reload_completed", "true"],
        ["viewflow_fragment_path", loaded["viewflow_fragment_path"]],
        ["deskflow_dropin_paths", loaded["deskflow_dropin_paths"]],
        ["viewflow_sha256", artifacts["viewflowd"]["sha256"]],
        ["deployment_marker_tool_sha256", artifacts["deployment_marker_tool"]["sha256"]],
        ["deskflow_sha256", artifacts["deskflow"]["sha256"]],
        ["deskflow_core_sha256", artifacts["deskflow_core"]["sha256"]],
        ["viewflow_unit_sha256", artifacts["viewflow_unit"]["sha256"]],
        ["deskflow_dropin_sha256", artifacts["deskflow_dropin"]["sha256"]],
    ]
    if len(pairs) < 2 or pairs[1][0] != "runtime_marker_state" or (
        pairs[1][1] not in {"retained", "absent"}
    ):
        raise ValueError("transcript runtime marker state is invalid")
    expected_pairs[1][1] = pairs[1][1]
    if pairs != expected_pairs:
        raise ValueError("transcript content/order does not match the proof")
except (OSError, UnicodeError, ValueError, KeyError, json.JSONDecodeError) as error:
    print(f"artifact pair validation failed: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

if (($#)); then
    if [[ $1 == --proof ]]; then
        (($# == 4)) || { usage >&2; fail 'artifact mode requires exactly four arguments'; }
        artifact_proof=$2
        [[ $3 == --transcript ]] || { usage >&2; fail 'expected --transcript'; }
        artifact_transcript=$4
        validate_artifact_pair
        printf 'standalone Linux deactivation artifact pair is valid\n'
        exit 0
    fi
    (($# == 1)) || { usage >&2; fail 'static mode accepts at most one script path'; }
    DEACTIVATOR=$1
fi
readonly DEACTIVATOR

phase_line() {
    local phase=$1
    grep -nF -- "# DEACTIVATION_PHASE: $phase" "$DEACTIVATOR" | cut -d: -f1
}

[[ -f $DEACTIVATOR ]] || fail "deactivator not found: $DEACTIVATOR"
bash -n "$DEACTIVATOR"

require_fixed 'readonly EXPECTED_UID=1000' 'fixed uid'
require_fixed 'readonly EXPECTED_HOME=/home/wilf' 'fixed home'
require_fixed 'readonly VIEWFLOW_INSTALLED=/home/wilf/.local/lib/viewflow/viewflowd' \
    'fixed Viewflow executable'
require_fixed \
    'readonly DEPLOYMENT_MARKER_TOOL_INSTALLED=/home/wilf/.local/lib/viewflow/viewflow-deployment-marker' \
    'fixed deployment marker tool executable'
require_fixed 'readonly DESKFLOW_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow' \
    'fixed Deskflow executable'
require_fixed 'readonly DESKFLOW_CORE_INSTALLED=/home/wilf/.local/lib/deskflow-scale-fix/deskflow-core' \
    'fixed deskflow-core executable'
require_fixed 'readonly VIEWFLOW_UNIT_INSTALLED=/home/wilf/.config/systemd/user/viewflow-peer.service' \
    'fixed Viewflow unit'
require_fixed 'readonly DESKFLOW_DROPIN_INSTALLED=/home/wilf/.config/systemd/user/deskflow.service.d/viewflow.conf' \
    'fixed Deskflow drop-in'
require_fixed 'readonly DESKFLOW_QUARANTINE_PARENT=/home/wilf/.local/state/viewflow' \
    'fixed Deskflow quarantine parent'
require_fixed \
    'readonly DESKFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'fixed Deskflow runtime quarantine marker'
require_fixed 'readonly DESKFLOW_QUARANTINE_SIZE=152' \
    'Deskflow runtime quarantine exact size'
require_fixed 'readonly DESKFLOW_QUARANTINE_MAGIC=VFQST002' \
    'Deskflow runtime quarantine exact magic'
require_fixed \
    'readonly DESKFLOW_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deskflow-quarantine.v2' \
    'fixed Deskflow runtime quarantine environment assignment'
require_fixed \
    'readonly DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    'fixed deployment quarantine marker'
require_fixed 'readonly DEPLOYMENT_QUARANTINE_SIZE=256' \
    'deployment quarantine exact size'
require_fixed 'readonly DEPLOYMENT_QUARANTINE_MAGIC=VFDQT001' \
    'deployment quarantine exact magic'
require_fixed \
    'readonly DEPLOYMENT_QUARANTINE_ENV_LINE=Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=/home/wilf/.local/state/viewflow/deployment-quarantine.v1' \
    'fixed deployment quarantine environment assignment'
require_fixed 'readonly VIEWFLOW_SIDECAR=/run/user/1000/viewflow/deskflow.sock' \
    'fixed sidecar socket'
require_fixed 'readonly VIEWFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/post-release-acceptance.sock' \
    'fixed Viewflow acceptance socket'
require_fixed 'readonly DESKFLOW_ACCEPTANCE_SOCKET=/run/user/1000/viewflow/deskflow-acceptance.sock' \
    'fixed Deskflow acceptance socket'
require_fixed 'readonly VIEWFLOW_ACCEPTANCE_STATE_DIR=/home/wilf/.local/state/viewflow/post-release-acceptance' \
    'fixed acceptance state directory'
require_fixed 'assert_acceptance_state_dir() {' \
    'acceptance state directory validator'
require_fixed '[[ -d $VIEWFLOW_ACCEPTANCE_STATE_DIR && ! -L $VIEWFLOW_ACCEPTANCE_STATE_DIR ]]' \
    'real non-symlink acceptance state directory gate'
require_fixed '[[ $owner == "$EXPECTED_UID" && $mode == 700 ]]' \
    'uid-1000 mode-0700 acceptance state directory gate'
require_fixed 'assert_acceptance_runtime_sockets_absent() {' \
    'post-release acceptance socket shutdown validator'
require_fixed 'assert_viewflow_unit_acceptance_contract() {' \
    'Viewflow unit acceptance contract validator'
require_fixed 'bootstrap_v13_legacy_config=0' \
    'normal-v2 default configuration mode'
require_fixed '--bootstrap-v1.3-legacy-config' \
    'explicit bootstrap-v1.3 legacy configuration flag'
require_fixed 'assert_installed_configuration_contract() {' \
    'configuration-mode dispatcher'
require_fixed 'case $bootstrap_v13_legacy_config in' \
    'configuration-mode strict dispatch'
require_fixed 'assert_bootstrap_v13_legacy_dropin_contract() {' \
    'bootstrap-v1.3 legacy drop-in validator'
require_fixed 'assert_bootstrap_v13_legacy_unit_contract() {' \
    'bootstrap-v1.3 legacy unit validator'
require_fixed '[[ $runtime_marker_state == absent ]] ||' \
    'bootstrap-v1.3 absent runtime-marker gate'
require_fixed "readonly LEGACY_V13_VIEWFLOW_EXECSTART='ExecStart=/home/wilf/.local/lib/viewflow/viewflowd serve --bind 0.0.0.0:44119 --cert /home/wilf/.local/share/viewflow/identity/peer.pem --key /home/wilf/.local/share/viewflow/identity/peer.key --ca /home/wilf/.local/share/viewflow/identity/ca.pem --device-id 00000000000000000000000000000001 --sidecar-socket %t/viewflow/deskflow.sock --sidecar-peer 172.16.105.70 --sidecar-target-device 00000000000000000000000000000002'" \
    'bootstrap-v1.3 exact Viewflow ExecStart'
require_fixed "readonly LEGACY_V13_DROPIN_SIDECAR='Environment=DESKFLOW_VIEWFLOW_SIDECAR_SOCKET=/run/user/1000/viewflow/deskflow.sock'" \
    'bootstrap-v1.3 fixed sidecar setting'
require_fixed "readonly LEGACY_V13_DROPIN_SCREEN='Environment=DESKFLOW_VIEWFLOW_SCREEN=WindowsVM'" \
    'bootstrap-v1.3 fixed screen setting'
require_fixed "readonly LEGACY_V13_DROPIN_SOURCE='Environment=DESKFLOW_VIEWFLOW_SOURCE_DISPLAY=00000000000000000000000000000101'" \
    'bootstrap-v1.3 fixed source-display setting'
require_fixed "readonly LEGACY_V13_DROPIN_ROUTE='Environment=DESKFLOW_VIEWFLOW_ROUTE_TO=00000000000000000000000000000002'" \
    'bootstrap-v1.3 fixed route setting'
require_fixed '$(wc -l <"$path") == 5' \
    'bootstrap-v1.3 exact five-line drop-in gate'
require_fixed "\$(grep -Fc 'ExecStart' \"\$path\") == 1" \
    'bootstrap-v1.3 unique ExecStart gate'
require_fixed "for option in --quiesce-proof --quiesce-arm-file --acceptance-socket \\" \
    'bootstrap-v1.3 rejects normal-v2 unit options'
require_fixed 'assert_installed_configuration_contract' \
    'preflight configuration-mode validation'
require_fixed 'assert_configuration_runtime_evidence() {' \
    'configuration-mode runtime socket evidence'
require_fixed 'assert_acceptance_state_dir' \
    'acceptance state evidence validation'

require_fixed 'assert_quarantine_storage() {' 'Deskflow quarantine storage validator'
require_fixed 'assert_quarantine_marker() {' 'shared quarantine marker validator'
require_fixed 'runtime_marker_state=retained' \
    'default retained runtime marker state'
require_fixed \
    '[[ -d $DESKFLOW_QUARANTINE_PARENT && ! -L $DESKFLOW_QUARANTINE_PARENT ]]' \
    'real non-symlink quarantine parent gate'
require_fixed "stat -c '%u %a' -- \"\$DESKFLOW_QUARANTINE_PARENT\"" \
    'quarantine parent metadata query'
require_fixed \
    '[[ $parent_owner == "$EXPECTED_UID" && $parent_mode == 700 ]]' \
    'uid-1000 mode-0700 quarantine parent gate'
require_fixed '[[ -e $path || -L $path ]]' \
    'mandatory quarantine marker presence including dangling symlinks'
require_fixed '[[ -f $path && ! -L $path ]]' \
    'regular non-symlink quarantine marker gate'
require_fixed "stat -c '%u %a %h %s' -- \"\$path\"" \
    'quarantine marker metadata query'
require_fixed \
    '[[ $marker_owner == "$EXPECTED_UID" && $marker_mode == 600 &&' \
    'uid-1000 mode-0600 quarantine marker gate'
require_fixed '$marker_links == 1 && $marker_size == "$expected_size" ]]' \
    'single-link exact-size quarantine marker gate'
require_fixed 'marker_magic=$(LC_ALL=C head -c 8 -- "$path")' \
    'quarantine marker magic read'
require_fixed '[[ $marker_magic == "$expected_magic" ]]' \
    'quarantine marker exact magic gate'
require_fixed 'case $runtime_marker_state in' \
    'strict runtime marker state dispatch'
require_fixed 'retained|absent)' \
    'strict runtime marker state enumeration'
require_fixed '[[ ! -e $DESKFLOW_QUARANTINE_MARKER &&' \
    'runtime quarantine marker absence gate'
require_fixed '! -L $DESKFLOW_QUARANTINE_MARKER ]]' \
    'runtime quarantine dangling-symlink absence gate'
require_fixed \
    '"$DESKFLOW_QUARANTINE_MARKER" "$DESKFLOW_QUARANTINE_SIZE"' \
    'Deskflow runtime quarantine marker validation'
require_fixed '"$DESKFLOW_QUARANTINE_MAGIC"' \
    'Deskflow runtime quarantine marker magic binding'
require_fixed \
    '"$DEPLOYMENT_QUARANTINE_MARKER" "$DEPLOYMENT_QUARANTINE_SIZE"' \
    'deployment quarantine marker validation'
require_fixed '"$DEPLOYMENT_QUARANTINE_MAGIC"' \
    'deployment quarantine marker magic binding'
for global in deskflow_quarantine_preflight_identity deskflow_quarantine_preflight_sha \
    deployment_quarantine_preflight_identity deployment_quarantine_preflight_sha; do
    require_fixed "$global=" "frozen quarantine global $global"
    [[ $(grep -Fxc -- "$global=" "$DEACTIVATOR") == 1 ]] ||
        fail "quarantine preflight global must be declared exactly once: $global"
done
require_fixed 'freeze_quarantine_storage() {' 'dual quarantine preflight freezer'
require_fixed 'assert_quarantine_storage_unchanged() {' \
    'dual quarantine continuity validator'
require_fixed \
    'deskflow_quarantine_preflight_identity=$(evidence_identity "$DESKFLOW_QUARANTINE_MARKER")' \
    'Deskflow runtime quarantine inode capture'
require_fixed \
    'deskflow_quarantine_preflight_sha=$(sha256 "$DESKFLOW_QUARANTINE_MARKER")' \
    'Deskflow runtime quarantine hash capture'
require_fixed 'deskflow_quarantine_preflight_identity=absent' \
    'Deskflow runtime quarantine absence freeze'
require_fixed 'deskflow_quarantine_preflight_sha=absent' \
    'Deskflow runtime quarantine absence hash sentinel'
require_fixed '[[ $deskflow_quarantine_preflight_identity == absent &&' \
    'Deskflow runtime quarantine frozen absence validation'
require_fixed \
    'deployment_quarantine_preflight_identity=$(evidence_identity "$DEPLOYMENT_QUARANTINE_MARKER")' \
    'deployment quarantine inode capture'
require_fixed \
    'deployment_quarantine_preflight_sha=$(sha256 "$DEPLOYMENT_QUARANTINE_MARKER")' \
    'deployment quarantine hash capture'
require_fixed '[[ $deskflow_identity_before == "$deskflow_quarantine_preflight_identity" ]]' \
    'Deskflow runtime pre-hash inode continuity'
require_fixed \
    'assert_hash '\
"'Deskflow runtime quarantine marker' \"\$DESKFLOW_QUARANTINE_MARKER\"" \
    'Deskflow runtime byte-hash continuity'
require_fixed '[[ $deskflow_identity_after == "$deskflow_identity_before" ]]' \
    'Deskflow runtime post-hash inode continuity'
require_fixed \
    '[[ $deployment_identity_before == "$deployment_quarantine_preflight_identity" ]]' \
    'deployment pre-hash inode continuity'
require_fixed \
    'assert_hash '\
"'deployment quarantine marker' \"\$DEPLOYMENT_QUARANTINE_MARKER\"" \
    'deployment byte-hash continuity'
require_fixed '[[ $deployment_identity_after == "$deployment_identity_before" ]]' \
    'deployment post-hash inode continuity'
require_fixed 'assert_quarantine_dropin_contract() {' \
    'Deskflow quarantine drop-in validator'
require_fixed \
    "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_QUARANTINE_MARKER=' \"\$path\"" \
    'single quarantine environment assignment gate'
require_fixed 'grep -Fxc "$DESKFLOW_QUARANTINE_ENV_LINE" "$path"' \
    'exact Deskflow runtime quarantine environment assignment gate'
require_fixed \
    "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_DEPLOYMENT_QUARANTINE_MARKER=' \"\$path\"" \
    'single deployment quarantine environment assignment gate'
require_fixed 'grep -Fxc "$DEPLOYMENT_QUARANTINE_ENV_LINE" "$path"' \
    'exact deployment quarantine environment assignment gate'
require_fixed "grep -Fc 'Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=' \"\$path\"" \
    'single Deskflow acceptance environment assignment gate'
require_fixed 'grep -Fxc "Environment=DESKFLOW_VIEWFLOW_ACCEPTANCE_SOCKET=$DESKFLOW_ACCEPTANCE_SOCKET" "$path"' \
    'exact Deskflow acceptance environment assignment gate'

for option in --viewflow-sha256 --deployment-marker-sha256 \
    --deskflow-sha256 --deskflow-core-sha256 \
    --viewflow-unit-sha256 --deskflow-dropin-sha256 --operation-id \
    --runtime-marker-state --bootstrap-v1.3-legacy-config --transcript-output --proof-output; do
    require_fixed "$option" "mandatory option $option"
done
require_fixed 'require_sha256 '\''--viewflow-sha256'\'' "$viewflow_expected_sha"' \
    'mandatory Viewflow hash validation'
require_fixed \
    'require_sha256 '\''--deployment-marker-sha256'\'' "$deployment_marker_tool_expected_sha"' \
    'mandatory deployment marker tool hash validation'
require_fixed 'require_sha256 '\''--deskflow-sha256'\'' "$deskflow_expected_sha"' \
    'mandatory Deskflow hash validation'
require_fixed 'require_sha256 '\''--deskflow-core-sha256'\'' "$deskflow_core_expected_sha"' \
    'mandatory deskflow-core hash validation'
require_fixed 'require_sha256 '\''--viewflow-unit-sha256'\'' "$viewflow_unit_expected_sha"' \
    'mandatory Viewflow unit hash validation'
require_fixed 'require_sha256 '\''--deskflow-dropin-sha256'\'' "$deskflow_dropin_expected_sha"' \
    'mandatory Deskflow drop-in hash validation'

require_fixed 'assert_hash '\''installed Viewflow'\'' "$VIEWFLOW_INSTALLED" "$viewflow_expected_sha"' \
    'installed Viewflow hash binding'
require_fixed 'assert_hash '\''installed deployment marker tool'\''' \
    'installed deployment marker tool hash binding'
require_fixed '"$DEPLOYMENT_MARKER_TOOL_INSTALLED"' \
    'installed deployment marker tool fixed hash target'
require_fixed '"$deployment_marker_tool_expected_sha"' \
    'installed deployment marker tool CLI hash binding'
require_fixed "stat -c '%u:%a:%h' -- \"\$DEPLOYMENT_MARKER_TOOL_INSTALLED\"" \
    'deployment marker tool owner mode and link query'
require_fixed '"$EXPECTED_UID:755:1"' \
    'deployment marker tool exact uid mode and link gate'
require_fixed 'assert_deployment_marker_tool_stopped() {' \
    'deployment marker tool exact-process absence validator'
require_fixed 'exact_executable_pids "$DEPLOYMENT_MARKER_TOOL_INSTALLED"' \
    'deployment marker tool exact executable process query'
require_fixed 'assert_hash '\''installed Deskflow'\'' "$DESKFLOW_INSTALLED" "$deskflow_expected_sha"' \
    'installed Deskflow hash binding'
require_fixed 'assert_hash '\''installed deskflow-core'\'' "$DESKFLOW_CORE_INSTALLED"' \
    'installed deskflow-core hash binding'
require_fixed 'assert_hash '\''installed Viewflow unit'\'' "$VIEWFLOW_UNIT_INSTALLED"' \
    'installed Viewflow unit hash binding'
require_fixed 'assert_hash '\''installed Deskflow drop-in'\'' "$DESKFLOW_DROPIN_INSTALLED"' \
    'installed Deskflow drop-in hash binding'

require_fixed 'fragment=$(unit_property "$VIEWFLOW_UNIT" FragmentPath)' \
    'loaded FragmentPath query'
require_fixed 'fragment_canonical=$(readlink -f -- "$fragment")' \
    'loaded FragmentPath canonicalization'
require_fixed 'fragment_canonical == "$VIEWFLOW_UNIT_INSTALLED"' \
    'loaded FragmentPath identity gate'
require_fixed 'dropins=$(unit_property "$DESKFLOW_UNIT" DropInPaths)' \
    'loaded DropInPaths query'
require_fixed '" $dropins " == *" $DESKFLOW_DROPIN_INSTALLED "*' \
    'loaded Deskflow drop-in identity gate'

require_fixed 'systemctl --user stop "$DESKFLOW_UNIT"' 'graceful Deskflow stop'
require_fixed 'wait_for_deskflow_stopped' 'Deskflow stop wait'
require_fixed 'systemctl --user stop "$VIEWFLOW_UNIT"' 'graceful Viewflow stop'
require_fixed 'wait_for_viewflow_stopped' 'Viewflow stop wait'
require_fixed 'state == inactive && ${main_pid:-0} == 0 && -z $deskflow_pids' \
    'Deskflow inactive/MainPID/process gate'
require_fixed '-z $core_pids && -z $tcp_output' 'deskflow-core and TCP absence gate'
require_fixed 'state == inactive && ${main_pid:-0} == 0 && -z $viewflow_pids' \
    'Viewflow inactive/MainPID/process gate'
require_fixed '-z $udp_output && ! -e $VIEWFLOW_SIDECAR' 'UDP and sidecar absence gate'
require_fixed 'systemctl --user daemon-reload' 'post-stop daemon reload'
require_fixed 'assert_installed_hashes' 'pre/post installed hash verification'
require_fixed 'assert_loaded_unit_configuration' 'pre/post loaded configuration verification'

require_fixed '[[ $proof_output != "$transcript_output" ]]' \
    'distinct proof and transcript output gate'
require_fixed '[[ $proof_parent == "$transcript_parent" ]]' \
    'same owner-only output directory gate'
require_fixed '{schema_version: 3, state: "viewflow-linux-deactivated"' \
    'dedicated proof schema and state'
require_fixed 'installed_artifacts:' 'six-file identity proof'
require_fixed 'deployment_marker_tool: {path: $marker_tool_path, sha256: $marker_tool_sha}' \
    'deployment marker tool artifact identity proof'
require_fixed 'loaded_configuration:' 'loaded configuration proof'
require_fixed 'daemon_reload_completed: true' 'daemon-reload proof field'
require_fixed 'stopped_runtime:' 'stopped runtime proof'
require_fixed 'deployment_marker_tool: {exact_process_count: 0}' \
    'deployment marker tool stopped process proof'
require_fixed 'deployment_marker_tool_exact_pids=%s' \
    'deployment marker tool transcript process observation'
require_fixed 'deployment_marker_tool_sha256=%s' \
    'deployment marker tool transcript hash observation'
require_fixed 'runtime_marker_state=%s' \
    'selected runtime marker state transcript observation'
require_fixed 'transcript_sha=$(sha256 "$transcript_temp")' \
    'temporary transcript byte hash'
require_fixed 'ln -- "$transcript_temp" "$transcript_output"' \
    'atomic no-clobber transcript publication'
require_fixed 'published_transcript_sha=$(sha256 "$transcript_output")' \
    'published transcript hash recomputation'
require_fixed '[[ $published_transcript_sha == "$transcript_sha" ]]' \
    'published transcript hash binding'
require_fixed '--arg transcript_sha "$published_transcript_sha"' \
    'proof uses recomputed published transcript hash'
require_fixed 'command_output_file_name: $transcript_file_name' \
    'transcript basename proof binding'
require_fixed 'command_output_sha256: $transcript_sha' 'command-output hash proof'
require_fixed 'completed_at_unix_ms: $completed_at_unix_ms' 'completion timestamp proof'
require_fixed 'chmod 0600 "$transcript_temp"' 'owner-only temporary transcript'
require_fixed 'stat -c '\''%u:%a'\'' -- "$transcript_output"' \
    'published transcript owner and mode verification'
require_fixed 'chmod 0600 "$proof_temp"' 'owner-only temporary proof'
require_fixed 'ln -- "$proof_temp" "$proof_output"' 'atomic no-clobber proof publication'
require_fixed 'proof_linked=1' \
    'uncommitted proof-link publication tracking'
require_fixed 'if ((proof_linked && !proof_published)); then' \
    'failed proof-link cleanup guard'
require_fixed 'assert_installed_hashes' 'publication-boundary hash recheck'
require_fixed 'deskflow_is_fully_stopped || die '\''Deskflow changed at proof publication boundary' \
    'Deskflow publication-boundary gate'
require_fixed 'viewflow_is_fully_stopped || die '\''Viewflow changed at proof publication boundary' \
    'Viewflow publication-boundary gate'
require_fixed 'assert_acceptance_runtime_sockets_absent' \
    'acceptance sockets absent after service stop'
require_fixed '[[ $(sha256 "$transcript_output") == "$published_transcript_sha" ]]' \
    'transcript publication-boundary hash recheck'
require_fixed 'if ((transcript_published && !proof_published)); then' \
    'orphan transcript cleanup before proof commit'
require_fixed 'services were not restarted and no proof was published' \
    'fail-closed failure report'

transcript_publish_line=$(grep -nF 'ln -- "$transcript_temp" "$transcript_output"' \
    "$DEACTIVATOR" | cut -d: -f1)
proof_publish_line=$(grep -nF 'ln -- "$proof_temp" "$proof_output"' \
    "$DEACTIVATOR" | cut -d: -f1)
[[ $transcript_publish_line =~ ^[0-9]+$ && $proof_publish_line =~ ^[0-9]+$ &&
   $transcript_publish_line -lt $proof_publish_line ]] ||
    fail 'transcript must be published and verified before the proof commit point'

mapfile -t phases < <(
    for phase in verify-installed-identity stop-deskflow-before-viewflow stop-viewflow \
        reload-and-reverify publish-fail-closed-proof; do
        line=$(phase_line "$phase")
        [[ $line =~ ^[0-9]+$ ]] || fail "missing or duplicate deactivation phase: $phase"
        printf '%s\n' "$line"
    done
)
[[ ${#phases[@]} == 5 ]] || fail 'one or more deactivation phases are missing or duplicated'
for ((index = 1; index < ${#phases[@]}; index++)); do
    ((phases[index - 1] < phases[index])) || fail 'deactivation phases are out of order'
done

assert_next_line() {
    local phase=$1 offset=$2 expected=$3 line actual
    line=$(phase_line "$phase")
    actual=$(sed -n "$((line + offset))p" "$DEACTIVATOR")
    [[ $actual == "$expected" ]] ||
        fail "unexpected command at offset $offset after phase $phase"
}

assert_next_line verify-installed-identity 1 '    assert_installed_hashes'
assert_next_line verify-installed-identity 2 '    assert_loaded_unit_configuration'
assert_next_line verify-installed-identity 3 '    assert_deployment_marker_tool_stopped'
assert_next_line stop-deskflow-before-viewflow 1 '    systemctl --user stop "$DESKFLOW_UNIT"'
assert_next_line stop-deskflow-before-viewflow 2 '    wait_for_deskflow_stopped'
assert_next_line stop-viewflow 1 '    systemctl --user stop "$VIEWFLOW_UNIT"'
assert_next_line stop-viewflow 2 '    wait_for_viewflow_stopped'
assert_next_line reload-and-reverify 1 '    systemctl --user daemon-reload'
assert_next_line reload-and-reverify 2 '    assert_installed_hashes'
assert_next_line reload-and-reverify 3 '    assert_loaded_unit_configuration'
assert_next_line reload-and-reverify 4 '    assert_deployment_marker_tool_stopped'
assert_next_line publish-fail-closed-proof 1 '    publish_proof'

assert_quarantine_boundary() {
    local boundary=$1 expected=$2 line actual
    line=$(grep -nF -- "# QUARANTINE_BOUNDARY: $boundary" "$DEACTIVATOR" | cut -d: -f1)
    [[ $line =~ ^[0-9]+$ ]] || fail "missing or duplicate quarantine boundary: $boundary"
    actual=$(sed -n "$((line + 1))p" "$DEACTIVATOR")
    [[ $actual == "$expected" ]] ||
        fail "unexpected quarantine validation at boundary $boundary"
}

assert_quarantine_boundary preflight '    freeze_quarantine_storage'
assert_quarantine_boundary before-shutdown '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-stop-deskflow '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-stop-viewflow '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary after-reload '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary proof-observation '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary proof-commit '    assert_quarantine_storage_unchanged'
assert_quarantine_boundary proof-publication '    assert_quarantine_storage_unchanged'
require_fixed 'assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"' \
    'installed quarantine drop-in validation'
[[ $(grep -Fc -- \
    'assert_quarantine_dropin_contract "$DESKFLOW_DROPIN_INSTALLED"' \
    "$DEACTIVATOR") == 1 ]] ||
    fail 'installed quarantine drop-in must be validated exactly once during preflight'

if grep -Eq 'kill[[:space:]]+-9|pkill|killall|systemctl[[:space:]]+--user[[:space:]]+(start|restart)' \
    "$DEACTIVATOR"; then
    fail 'deactivator contains force-kill or service-start behavior'
fi
if grep -Eq \
    '((DEPLOYMENT_MARKER_TOOL_INSTALLED|/home/wilf/\.local/lib/viewflow/viewflow-deployment-marker).*\b(publish|release)\b|\b(publish|release)\b.*(DEPLOYMENT_MARKER_TOOL_INSTALLED|/home/wilf/\.local/lib/viewflow/viewflow-deployment-marker))' \
    "$DEACTIVATOR"; then
    fail 'deactivator must never publish or release deployment quarantine'
fi
if grep -Eq '(^|[;&|[:space:]])(install|cp|mv)[[:space:]]' "$DEACTIVATOR"; then
    fail 'deactivator contains an installed-file replacement command'
fi
if grep -Eq \
    '(^|[;&|[:space:]])(rm|unlink|mv|truncate|shred|touch|install|cp|dd|tee|chmod|chown|chgrp)([[:space:]]|$)[^#]*(DESKFLOW_QUARANTINE_(MARKER|PARENT)|DEPLOYMENT_QUARANTINE_MARKER|VIEWFLOW_ACCEPTANCE_STATE_DIR|deskflow-quarantine\.v2|deployment-quarantine\.v1|post-release-acceptance)' \
    "$DEACTIVATOR"; then
    fail 'deactivator may validate but must not mutate durable quarantine or acceptance evidence storage'
fi
if grep -Eq \
    '>[>]?[[:space:]]*"?(\$\{?(DESKFLOW|DEPLOYMENT)_QUARANTINE_MARKER|/home/wilf/\.local/state/viewflow/(deskflow-quarantine\.v2|deployment-quarantine\.v1))' \
    "$DEACTIVATOR"; then
    fail 'deactivator may not redirect output into the durable quarantine marker'
fi

printf 'standalone Linux deactivation static checks passed\n'
