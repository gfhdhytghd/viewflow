#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/prepare-normal-v21-operation-candidate.sh}
fail(){ echo "error: candidate preparation checker: $*" >&2; exit 1; }
[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || fail "source must be regular non-symlink"
bash -n "$SOURCE" || fail "bash syntax"
shellcheck -s bash "$SOURCE" || fail "shellcheck"
need(){ rg -Fq -- "$1" "$SOURCE" || fail "missing contract: $2"; }
for pair in  'set -Eeuo pipefail|strict shell mode'  'os.O_NOFOLLOW|nofollow opens'  'os.O_EXCL|create-once leaves'  'renameat2|atomic no-replace publication'  'deployment_publish_receipt_sha256|publish binding'  'marker_handoff_sha256|handoff binding'  'linux_frozen_sha256|frozen binding'  'runtime_marker_present|runtime marker gate'  'unknown/reordered keys|schema rejection'  'object_pairs_hook|duplicate-key rejection'  'parse_float|float rejection'  'parse_constant|NaN/Infinity rejection'  'raw_decode|single JSON document'  'decode("utf-8","strict")|invalid UTF-8 rejection'  'trailing JSON data|trailing-garbage rejection'  'x=strict_json_object(p,label)|fresh strict parser'  'seed=strict_json_object(SEED/"candidate-manifest.json","seed manifest")|seed strict parser'  'shutil.rmtree(stage,ignore_errors=True)|failed staging cleanup'  'target.exists() or target.is_symlink()|candidate no-clobber'  'sidecar_protocol_version|sidecar schema'  'windows-source.tar.gz|source package copy'  'candidate-manifest.json|manifest publication'  '--candidate-retirement-terminal|retirement terminal CLI'  '--candidate-retirement-terminal-sha256|retirement terminal hash CLI'  'validate_term|terminal validation'  'old_candidate|retired old candidate'  'archive_path|archive tree'  'candidate_replacement|schema2 manifest'  'COMMIT_KEYS|commit schema'  'candidate-replacement-commit.json|commit receipt'  '--resume|deterministic resume'  'tree(root,rows)|candidate tree hash'  'replacement_ordinal|replacement ordinal'  'authorized_seed_manifest_sha256|seed binding'; do
need 'created_at_unix_ms' 'integer timestamp validation'
need 'canonical UTC milliseconds' 'canonical timestamp validation'
need 'retired canonical candidate is not absent' 'retired canonical absence'
need 'term!=fresh/"candidate-retirement-terminal.json"' 'canonical retirement terminal path'
need 'os.scandir(root)' 'complete tree enumeration'
need 'is_symlink() or not stat.S_ISREG' 'symlink/non-regular tree rejection'
need 'm["schema_version"]!=(2 if schema2 else 1)' 'schema1 rejection with terminal'
need '"schema_version":1,"state":"viewflow-normal-v21-candidate-replacement-committed"' 'commit schema1'
 token=${pair%%|*}; label=${pair#*|}; need "$token" "$label"
done
for token in v21-normal-seed-v3-20260904T123027Z-oZ1vdq 07bbb719e07ae03a9591a8dc0bf2603bf8a9538ea42774c31bd050bca2004be0 'seed manifest hash mismatch' 87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04 fc4cb5cff71ad859f113cd2ad21cfff90217401772cba08f21c0394735bac17d 7ecccb607a166c847aa1293905f8fd14909803734751b6ca71549470fc6f95e2 da3014217499fc7deb5eac1fa07fb85e9cbfcecb0bff9fd14df54530d3367131 aea8ec8fe6232e0883b97e58cd027e735b1e2a39b2c3761b5a3fcadbff7139ee; do need "$token" "current seed pin"; done
need 'od(CANDS,0o700)' 'owner-only candidate root'
need 'if not v["resume"]: die("operation candidate exists; use --resume for deterministic recovery")' 'existing candidate requires resume'
need 'if commit.exists() or commit.is_symlink(): die("commit receipt exists without candidate")' 'commit orphan rejection'
! rg -n 'systemctl|ssh[[:space:]]|TODO|PLACEHOLDER' "$SOURCE" >/dev/null || fail "live/placeholder token"
! rg -n 'v21-operation-a18635e6e23f4304afaca816333f3455|v21-refreeze|early-abort-v3|v21-deskflow-clean-source|v21-normal-seed-20260904T105252Z-a3f96889' "$SOURCE" >/dev/null || fail "stale candidate token"
printf 'normal candidate preparation checker passed\n'
