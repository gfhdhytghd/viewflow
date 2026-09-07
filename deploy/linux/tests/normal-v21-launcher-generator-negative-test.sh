#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly FIXTURE="$HERE/normal-v21-launcher-generator-fixture-test.sh"
readonly OP=11111111111111111111111111111111
readonly COORD=792da663-4417-4674-a69c-0551a8a91a71
fixture_output=$(VIEWFLOW_FIXTURE_KEEP_ROOT=1 bash "$FIXTURE")
root=$(awk -F= '/^fixture-root=/{print $2}' <<<"$fixture_output")
[[ -d $root && ! -L $root ]] || { printf 'fixture root missing\n' >&2; exit 1; }
trap 'rm -rf -- "$root"' EXIT
readonly LAUNCHER="$root/launch-normal-v21.sh"
readonly GENERATOR="$root/generator.sh"
readonly FRESH="$root/fresh"
readonly CAND="$root/candidate"
reject() { local label=$1; shift; if "$@" >/dev/null 2>&1; then printf 'negative fixture accepted: %s\n' "$label" >&2; exit 1; fi; }
check_only() { env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$LAUNCHER" --check-only; }
execute() { env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$LAUNCHER" --execute; }
run_generator() {
    local out=$1 manifest
    manifest=$(sha256sum -- "$CAND/candidate-manifest.json" | awk '{print $1}')
    bash "$GENERATOR" --operation-id "$OP" --coordinator-uuid "$COORD" --candidate-manifest-sha256 "$manifest" --fresh-root "$FRESH" --handoff "$FRESH/marker-handoff.json" --frozen "$FRESH/linux-frozen.json" --publish "$FRESH/deployment-publish.json" --output "$out"
}
mutated_source="$root/generator-missing-runtime-artifact-check.sh"
python3 - "$HERE/../generate-normal-v21-launcher.sh" "$mutated_source" <<'PY'
import sys
src,dst=sys.argv[1:]; text=open(src,encoding='utf-8').read()
needle='check_file "$CAND/windows-viewflowd.exe" 87631e877811377f018d65dc5ca2b1d6b68e2b268d7d15b8d0646aac3d9f5b04'
assert text.count(needle)==2
head,tail=text.rsplit(needle,1)
open(dst,'w',encoding='utf-8').write(head+'true # removed generated-launcher Windows artifact recheck'+tail)
PY
chmod 700 "$mutated_source"
reject missing-runtime-artifact-recheck bash "$HERE/../check-normal-v21-launcher-generator.sh" "$mutated_source"
mutated_source="$root/generator-missing-derived-output-check.sh"
python3 - "$HERE/../generate-normal-v21-launcher.sh" "$mutated_source" <<'PY'
import sys
src,dst=sys.argv[1:]; text=open(src,encoding='utf-8').read()
needle=' coordinator-state.json.windows-restart-intent.json'
assert text.count(needle)==1
open(dst,'w',encoding='utf-8').write(text.replace(needle,'',1))
PY
chmod 700 "$mutated_source"
reject missing-derived-output-check bash "$HERE/../check-normal-v21-launcher-generator.sh" "$mutated_source"
for leaf in marker-handoff.json linux-frozen.json deployment-publish.json; do
    cp -- "$FRESH/$leaf" "$FRESH/$leaf.saved"
    printf ' ' >>"$FRESH/$leaf"
    reject "replaced-$leaf" check_only
    mv -- "$FRESH/$leaf.saved" "$FRESH/$leaf"
done
derived_outputs=(
    coordinator-state.json.recovery-bundle.json
    coordinator-state.json.windows-stop-evidence.json
    coordinator-state.json.windows-restart-intent.json
    coordinator-state.json.pre-mutation-retry.json
    coordinator-state.json.pre-mutation-start-intent.v1.json
    coordinator-state.json.pre-mutation-stop-claim.v1
    recovery-deployment-publish.json.intent.json
    linux-stage.json.backup
    linux-stage.json.backup/consume-intent.json
)
for i in "${!derived_outputs[@]}"; do
    leaf=${derived_outputs[$i]}
    rm -rf -- "$FRESH/linux-stage.json.backup"
    rm -rf -- "$FRESH/${leaf:?}"
    mkdir -p -- "$(dirname -- "$FRESH/$leaf")"
    case $((i % 3)) in
        0) printf 'occupied\n' >"$FRESH/$leaf" ;;
        1) mkdir -- "$FRESH/$leaf" ;;
        2) ln -s -- "$FRESH/nonexistent-derived-target" "$FRESH/$leaf" ;;
    esac
    reject "existing-derived-$leaf" check_only
    rm -rf -- "$FRESH/linux-stage.json.backup"
    rm -rf -- "$FRESH/${leaf:?}"
done
cp -- "$CAND/windows-viewflowd.exe" "$CAND/windows-viewflowd.exe.saved"
printf 'tamper' >>"$CAND/windows-viewflowd.exe"
reject replaced-windows-viewflowd check_only
mv -- "$CAND/windows-viewflowd.exe.saved" "$CAND/windows-viewflowd.exe"
reject resume-missing-state env -i HOME=/home/wilf PATH=/usr/bin:/bin bash "$LAUNCHER" --resume
touch "$FRESH/windows-install.json"
reject execute-existing-output execute
rm -f -- "$FRESH/windows-install.json"
cp -- "$FRESH/deployment-publish.json" "$FRESH/deployment-publish.json.saved"
printf '{}\n' >"$FRESH/deployment-publish.json"
chmod 600 "$FRESH/deployment-publish.json"
reject empty-publish-json run_generator "$root/empty-publish-launcher"
mv -- "$FRESH/deployment-publish.json.saved" "$FRESH/deployment-publish.json"
cp -- "$FRESH/candidate-retirement-terminal.json" "$FRESH/candidate-retirement-terminal.json.saved"
printf ' ' >>"$FRESH/candidate-retirement-terminal.json"
reject replaced-retirement-terminal check_only
mv -- "$FRESH/candidate-retirement-terminal.json.saved" "$FRESH/candidate-retirement-terminal.json"
cp -- "$CAND/candidate-manifest.json" "$CAND/candidate-manifest.json.saved"
python3 - "$CAND/candidate-manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; x=json.load(open(p,encoding='utf-8')); x['schema_version']=1
open(p,'w',encoding='utf-8').write(json.dumps(x,separators=(',',':'))+'\n')
PY
chmod 600 "$CAND/candidate-manifest.json"
reject schema1-with-replacement run_generator "$root/schema1-with-replacement-launcher"
mv -- "$CAND/candidate-manifest.json.saved" "$CAND/candidate-manifest.json"
cp -- "$FRESH/candidate-replacement-commit.json" "$FRESH/candidate-replacement-commit.json.saved"
printf ' ' >>"$FRESH/candidate-replacement-commit.json"
reject replaced-candidate-replacement-commit check_only
mv -- "$FRESH/candidate-replacement-commit.json.saved" "$FRESH/candidate-replacement-commit.json"
cp -- "$CAND/candidate-manifest.json" "$CAND/candidate-manifest.json.saved"
python3 - "$CAND/candidate-manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; x=json.load(open(p,encoding='utf-8')); x['candidate_replacement']['retirement_terminal_path']='/tmp/wrong-retirement-terminal.json'
open(p,'w',encoding='utf-8').write(json.dumps(x,separators=(',',':'))+'\n')
PY
chmod 600 "$CAND/candidate-manifest.json"
reject wrong-retirement-terminal-path run_generator "$root/wrong-retirement-terminal-path-launcher"
mv -- "$CAND/candidate-manifest.json.saved" "$CAND/candidate-manifest.json"
cp -- "$root/old-candidate-archive/candidate-manifest.json" "$root/old-candidate-archive/candidate-manifest.json.saved"
printf 'tamper' >>"$root/old-candidate-archive/candidate-manifest.json"
reject replaced-retired-archive check_only
mv -- "$root/old-candidate-archive/candidate-manifest.json.saved" "$root/old-candidate-archive/candidate-manifest.json"
printf extra >"$CAND/extra-artifact"
chmod 600 "$CAND/extra-artifact"
reject extra-candidate-artifact check_only
rm -f -- "$CAND/extra-artifact"
mkdir -- "$CAND/extra-directory"
reject extra-candidate-directory check_only
rmdir -- "$CAND/extra-directory"
ln -s -- "$CAND/candidate-manifest.json" "$CAND/extra-symlink"
reject extra-candidate-symlink check_only
rm -f -- "$CAND/extra-symlink"
printf extra >"$root/old-candidate-archive/extra-artifact"
chmod 600 "$root/old-candidate-archive/extra-artifact"
reject extra-retired-artifact check_only
rm -f -- "$root/old-candidate-archive/extra-artifact"
cp -- "$CAND/candidate-manifest.json" "$CAND/candidate-manifest.json.saved"
python3 - "$CAND/candidate-manifest.json" <<'PY'
import json,sys
p=sys.argv[1]; x=json.load(open(p,encoding='utf-8')); x['fresh_boundary']['root']='/wrong/fresh/root'
open(p,'w',encoding='utf-8').write(json.dumps(x,separators=(',',':'))+'\n')
PY
chmod 600 "$CAND/candidate-manifest.json"
reject wrong-manifest-fresh-binding run_generator "$root/wrong-manifest-launcher"
mv -- "$CAND/candidate-manifest.json.saved" "$CAND/candidate-manifest.json"
for needle in 'object_pairs_hook=pairs' 'parse_float=bad_number' 'O_NOFOLLOW' 'trailing JSON data' 'candidate P/H/F closure' 'marker file hash closure' 'candidate_replacement' 'retirement_terminal_path' 'candidate-replacement-commit.json' 'retired candidate tree SHA mismatch' 'candidate replacement commit closure' 'HANDOFF_SHA' 'FROZEN_SHA' 'PUBLISH_SHA' 'REPLACEMENT_TERMINAL_SHA' 'REPLACEMENT_COMMIT_SHA' 'fresh-boundary evidence changed or no longer closes' 'candidate replacement evidence changed or no longer closes' 'resume_state_validator' 'state operation binding' 'coordinator_mode+=(--resume)' '--candidate-retirement-terminal' '--candidate-replacement-commit'; do
    rg -Fq -- "$needle" "$HERE/../generate-normal-v21-launcher.sh" || { printf 'missing hardened contract: %s\n' "$needle" >&2; exit 1; }
done
printf 'normal v2.1 launcher generator negative test passed\n'
