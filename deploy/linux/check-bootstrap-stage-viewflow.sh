#!/usr/bin/env bash
# shellcheck disable=SC2016
# Static contract audit for the Linux half of the one-time bootstrap.
# This checker is deliberately side-effect free; the optional argument is used
# by the source-mutation tests and is never executed.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly STAGE=${1:-$SCRIPT_DIR/bootstrap-stage-viewflow.sh}
readonly COMMON=${2:-$SCRIPT_DIR/bootstrap-two-phase-common.sh}

fail() { printf 'bootstrap stage static check failed: %s\n' "$*" >&2; exit 1; }
require_fixed() { grep -Fq -- "$1" "$STAGE" || fail "missing $2"; }
require_common() { grep -Fq -- "$1" "$COMMON" || fail "missing $2"; }
require_regex() { grep -Eq -- "$1" "$STAGE" || fail "missing $2"; }

[[ -f $STAGE ]] || fail "stage script not found: $STAGE"
[[ -f $COMMON ]] || fail "shared helper not found: $COMMON"
bash -n "$STAGE"
bash -n "$COMMON"

# The implementation must use the shared validation/publication contract.
require_fixed 'source "$SCRIPT_DIR/bootstrap-two-phase-common.sh"' 'shared bootstrap helper'
require_fixed 'schema_version:1' 'schema-1 receipt schema'

# This entry point owns only the Viewflow daemon, deployment-marker CLI, and
# its unit.  Deskflow is an invariant of the stage (and is checked inactive).
require_fixed '[[ $command == stage || $command == query || $command == rollback ]]' \
    'stage/query/rollback dispatcher'
require_fixed 'viewflowd' 'Viewflow daemon artifact'
require_regex 'viewflow-deployment-marker|deployment.marker' 'deployment marker CLI artifact'
require_fixed 'viewflow-peer.service' 'Viewflow unit artifact'
install_phase=$(awk '/TRANSACTION_PHASE: BOOTSTRAP_STAGE_INSTALL_VIEWFLOW_ONLY/{on=1; next} /TRANSACTION_PHASE: BOOTSTRAP_STAGE_START_VIEWFLOW_AND_MEET_WINDOWS/{on=0} on' "$STAGE")
if grep -Eq 'atomic_install.*(deskflow|DESKFLOW)' <<<"$install_phase"; then
    fail 'stage install phase must not mutate Deskflow artifacts'
fi
require_regex 'DESKFLOW_UNIT|deskflow\.service' 'Deskflow unit invariant'
require_regex 'is-active "\$DESKFLOW_UNIT"|deskflow_state.*inactive|deskflow.*inactive' \
    'Deskflow inactive gate'
require_common 'REQUIRED_PROTOCOL=2.1' 'protocol 2.1 gate'
require_fixed 'protocol_version:"2.1"' 'protocol 2.1 evidence'
require_fixed '[[ $marker_generation == 1 ]]' 'one-time bootstrap generation-1 gate'
require_fixed 'source_display_id=$2' 'source ID validated before any normalization'
require_fixed 'target_device_id=$2' 'target ID validated before any normalization'
require_fixed 'coordinator_instance_id=$2' 'coordinator ID validated before any normalization'
require_fixed "require_uuid32 '--operation-id' \"\$operation_id\"" 'canonical lowercase operation ID gate'
if grep -Eq '(source_display_id|target_device_id|coordinator_instance_id)=\$\{2,,\}' "$STAGE"; then
    fail 'stage must reject rather than lowercase uppercase ID arguments'
fi
if grep -Eq 'operation_id=\$\{2,,\}' "$STAGE"; then
    fail 'stage must reject rather than lowercase uppercase operation IDs'
fi
require_common 'def canonical_uuid:' 'canonical receipt UUID validator'
require_common 'test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")' \
    'canonical hyphenated receipt UUID syntax'
require_common '(gsub("-"; "") != "00000000000000000000000000000000")' \
    'nonzero canonical receipt UUID gate'
require_common '((.source_display_id | gsub("-"; "")) == $source)' \
    'canonical H/publish source UUID to 32hex comparison'
require_common '((.coordinator_instance_id | gsub("-"; "")) == $coordinator)' \
    'canonical H/publish coordinator UUID to 32hex comparison'

# Every cross-host input is an exact, owner-only JSON object.  Keep the
# complete H -> request -> P -> permit -> F chain visible here so a future
# simplification cannot turn a path/sha binding into an advisory field.
require_fixed '--bootstrap-handoff-receipt' 'H handoff input'
require_fixed '--windows-bootstrap-request' 'Windows bootstrap request input'
require_fixed '--windows-prepared-receipt' 'P prepared receipt input'
require_fixed '--windows-mutation-permit' 'mutation permit input'
require_fixed '--windows-force-release-envelope' 'force envelope input'
require_fixed 'assert_evidence '\''bootstrap handoff receipt'\''' 'H owner-only evidence check'
require_fixed 'assert_evidence '\''Windows bootstrap request'\''' 'bootstrap request owner-only evidence check'
require_fixed 'assert_evidence '\''Windows prepared receipt'\''' 'P owner-only evidence check'
require_fixed 'assert_evidence '\''Windows mutation permit'\''' 'permit owner-only evidence check'
require_fixed 'assert_evidence '\''Windows force-release envelope'\''' 'F envelope owner-only evidence check'
require_fixed 'validate_handoff_receipt' 'exact H validation'
require_fixed 'validate_bootstrap_request_receipt' 'exact bootstrap-request validation'
require_fixed 'validate_windows_prepared_receipt' 'exact P validation'
require_fixed 'validate_mutation_permit_receipt' 'exact permit validation'
require_fixed 'validate_force_envelope_receipt' 'exact F-envelope validation'
require_common '.marker_handoff_receipt_sha256 == $handoff' 'request H SHA binding'
require_common '.linux_frozen_evidence_sha256 == $linux' 'request B SHA binding'
require_common '.bootstrap_request_sha256 == $request' 'P/request SHA binding'
require_common '.windows_prepared_receipt_sha256 == $prepared' 'permit/P SHA binding'
require_common '(.coordinator_instance_id | canonical_uuid)' 'permit canonical coordinator UUID gate'
require_common '((.coordinator_instance_id | gsub("-"; "")) == $coordinator)' \
    'permit compact-coordinator binding'
require_common '.mutation_permit_sha256 == $permit' 'F/permit SHA binding'
require_common '.linux_viewflowd_sha256 == $linux_vf' 'permit/Ls viewflow SHA binding'
require_common '.linux_deployment_marker_sha256 == $linux_marker' 'permit/Ls marker SHA binding'
require_common '.linux_viewflow_unit_sha256 == $linux_unit' 'permit/Ls unit SHA binding'
require_common '(.marker_handoff_receipt | keys == ["path","sha256"])' 'P marker handoff exact nested keys'
require_common '(.candidate | keys == ["path","sha256"])' 'P candidate exact nested keys'
require_common '(.wrapper | keys == ["installed_path","sha256","source_path"])' 'P wrapper exact nested keys'
require_common '(.rollback_script | keys == ["path","sha256"])' 'P rollback script exact nested keys'
require_common '(.rollback_authorization | keys == ["manifest_path","manifest_sha256","token_path","token_sha256"])' \
    'P rollback authorization exact nested keys'
require_common '(.old_task | keys == ["name","state","xml_backup_path","xml_sha256"])' 'P old task exact nested keys'
require_common '(.old_executable | keys == ["owner_sid","path","process_id","process_start_filetime",' \
    'P old executable exact nested keys'
require_fixed '"$windows_viewflow_sha" "$bootstrap_request" "$viewflow_sha" "$marker_tool_sha" "$unit_sha"' \
    'permit invocation binds each Ls artifact hash'
require_common '"marker_handoff_receipt_sha256"' 'request H path/sha schema key'
require_common '"linux_stage_receipt_path"' 'request Ls path schema key'
require_common '"force_release_envelope_path"' 'request F-envelope path schema key'

# Ls itself is deliberately schema-locked: all upstream evidence is retained
# under evidence_hashes and the three staged artifacts are what the permit
# authorized, not merely similarly-named candidate files.
require_fixed 'keys == ["artifact_hashes","backup_directory","backup_manifest_sha256","completed_at_unix_ms",' \
    'exact Ls top-level key set'
require_fixed '.evidence_hashes == {bootstrap_request:$request,linux_frozen_evidence:$linux,' \
    'exact Ls evidence-hash object'
require_fixed 'marker_handoff_receipt:$handoff,mutation_permit:$permit,' \
    'Ls H/permit evidence bindings'
require_fixed 'windows_force_release_envelope:$envelope,windows_prepared_receipt:$prepared,' \
    'Ls F/P evidence bindings'
require_fixed 'deployment_publish_receipt:$publish}' 'Ls deployment-publish evidence binding'
require_fixed '(.runtime | keys == ["authenticated_at_unix_ms","authenticated_peer_ip",' \
    'Ls runtime exact nested key set'
require_fixed 'old_viewflow_unit:$old_unit,staged_viewflowd:$new_vf,' 'Ls staged Viewflow SHA binding'
require_fixed 'staged_deployment_marker_tool:$new_marker,staged_viewflow_unit:$new_unit,' \
    'Ls staged marker/unit SHA binding'
[[ $(grep -Fc 'marker_handoff_receipt:$handoff,mutation_permit:$permit,' "$STAGE") -eq 2 ]] ||
    fail 'Ls H/permit evidence must appear identically in validator and producer'
[[ $(grep -Fc 'deployment_publish_receipt:$publish}' "$STAGE") -eq 2 ]] ||
    fail 'Ls evidence object must be identical in validator and producer'

# Frozen marker semantics: retain VFDQT001 and reject any legacy runtime marker.
require_common 'DEPLOYMENT_MARKER_MAGIC=VFDQT001' 'VFDQT001 retention'
if grep -Eq 'rm[[:space:]].*(VFQST002|RUNTIME_MARKER|deskflow-quarantine)|unlink.*(VFQST002|RUNTIME_MARKER)' "$STAGE"; then
    fail 'stage must not remove the frozen runtime marker'
fi
require_regex 'VFQST002.*absent|legacy bootstrap requires VFQST002|assert_runtime_marker_absent|!.*RUNTIME_MARKER|! -e.*RUNTIME_MARKER' \
    'VFQST002 absence gate'
[[ $(grep -Fc 'assert_runtime_marker_absent' "$STAGE") -ge 5 ]] ||
    fail 'runtime marker absence must be rechecked at every stage boundary'

# Stage must snapshot the old installation and provide fail-closed restoration
# while both Linux units remain inactive on the failure path.
require_regex 'old_(viewflow|deployment_marker|viewflow_unit)' 'old installation snapshot'
require_regex 'restore_stage|rollback_stage|restore_old' 'failure restoration routine'
require_regex 'systemctl --user stop "\$VIEWFLOW_UNIT"|stop_both_units' 'Viewflow failure stop'
require_regex 'systemctl --user stop "\$DESKFLOW_UNIT"|Deskflow.*inactive' 'Deskflow failure inactivity'
require_regex 'inactive.*MainPID|MainPID.*inactive|wait_stopped|assert_both_units_stopped' 'inactive/MainPID proof'

# The stage starts 2.1 and observes a newly authenticated Windows peer before
# publishing a durable receipt.
require_fixed 'systemctl --user start "$VIEWFLOW_UNIT"' 'Viewflow start'
require_regex 'authenticated.*peer|peer.*authenticated|mTLS.*peer|authenticated_peer' \
    'new authenticated Windows peer observation'
require_fixed '--arg prefix "viewflowd server authenticated peer $EXPECTED_WINDOWS_PEER_IP:"' \
    'authenticated peer journal binding'
require_regex '172\.16\.105\.70|EXPECTED_WINDOWS_PEER_IP' 'Windows peer binding'
require_regex 'new.*peer|peer.*new|session.*1|new_process_session_id' 'new-peer/session observation'

# Query is exact/idempotent and publication is owner-only, atomic, and
# no-clobber.  Shell redirection to a receipt is explicitly forbidden.
require_regex 'query_exact|query.*receipt|receipt.*query' 'exact receipt query'
require_regex 'operation_id' 'operation-bound receipt'
require_fixed 'publish_no_clobber' 'owner-only no-clobber publication helper'
require_common 'ln -- "$temporary" "$destination"' 'atomic no-clobber link publication'
require_fixed 'chmod 0600 "$receipt_temp"' 'owner-only receipt creation'
require_regex '0600|owner-only|assert_owner_file' 'owner-only receipt mode'
if grep -Eq '>[[:space:]]*"?\$receipt_output"?' "$STAGE"; then
    fail 'receipt publication may not use overwrite redirection'
fi

printf 'bootstrap stage static checks passed\n'
