#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pipeline=$here/../normal-v21-operation-pipeline.sh
tmp=$(mktemp -d --tmpdir normal-v21-pipeline.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
state=$tmp/state; op=0123456789abcdef0123456789abcdef; coord=11111111-2222-3333-8444-555555555555
root=$state/deployments/$op; mkdir -p "$root" "$state/candidates"; chmod 700 "$state" "$state/deployments" "$root" "$state/candidates"
python3 - "$root" "$op" "$coord" <<'PY'
import json,os,sys,time
r,op,c=sys.argv[1:]; now_ms=time.time_ns()//1000000; now=str(now_ms+25000); marker=r+'/marker'
open(marker,'w').write('marker'); os.chmod(marker,0o600)
def dump(n,x): open(r+'/'+n,'w').write(json.dumps(x,separators=(',',':'))); os.chmod(r+'/'+n,0o600)
p={'schema_version':1,'state':'deployment-quarantine-published','operation_id':op,'coordinator_instance_id':c,'protocol_version':'2.1','marker_generation':'1','marker_path':marker,'marker_sha256':'a'*64,'created_at_unix_ms':now}
dump('deployment-publish.json',p)
import hashlib
sha=lambda n:hashlib.sha256(open(r+'/'+n,'rb').read()).hexdigest()
h={'schema_version':1,'state':'viewflow-v13-marker-handoff-prepared','operation_id':op,'coordinator_instance_id':c,'protocol_version':'2.1','marker_generation':'1','deployment_publish_receipt_path':r+'/deployment-publish.json','deployment_publish_receipt_sha256':sha('deployment-publish.json')}; dump('marker-handoff.json',h)
# Keep publication fresh while making the independently captured Linux frozen
# evidence one millisecond beyond the Windows installer's 300-second default.
# This guards against reducing age to whole seconds before the comparison.
dump('linux-frozen.json',{'schema_version':1,'state':'viewflow-v13-bootstrap-frozen','operation_id':op,'completed_at_unix_ms':now_ms-300001})
b={'deployment_publish_sha256':sha('deployment-publish.json'),'marker_handoff_sha256':sha('marker-handoff.json'),'linux_frozen_sha256':sha('linux-frozen.json'),'deployment_marker_sha256':'a'*64,'protocol_version':'2.1'}
dump('v4-inactive-terminal-to-fresh-v21.json',{'schema_version':1,'state':'viewflow-v4-inactive-terminal-to-fresh-v21','old_operation_id':'f'*32,'new_operation_id':op,'new_coordinator_instance_id':c,'marker_generation':'1','inactive_source':{'source_validation_sha256':'0'*64,'terminal_sha256':'1'*64,'authorization_sha256':'2'*64,'abort_receipt_sha256':'3'*64,'abort_query_receipt_sha256':'4'*64,'vfdqa_sha256':'5'*64,'linux_initially_inactive':True,'windows_old_peer_unchanged':True},'persistent_v13':{'persistent_started_sha256':'6'*64,'authenticated_probe_record_sha256':'7'*64,'stopped_by_collector':True},'fresh_boundary':b})
PY
prepare=$here/../prepare-normal-v21-fresh-first-candidate.sh; generate=$tmp/generate
seed=$tmp/seed; mkdir -m 700 "$seed"
for leaf in candidate-manifest.json windows-viewflowd.exe windows-native-provenance.json windows-source.manifest.sha256 windows-source.tar.gz windows-source.tar.gz.sha256; do cp -- "/home/wilf/.local/state/viewflow/candidates/v21-normal-seed-v3-20260904T123027Z-oZ1vdq/$leaf" "$seed/$leaf"; done
chmod 600 "$seed"/*; chmod 700 "$seed/windows-viewflowd.exe"
cat >"$generate" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while (($#)); do case $1 in --output) out=$2; shift 2;; *) shift 2;; esac; done
printf '#!/usr/bin/env bash\n[[ ${1-} == --check-only || ${1-} == --execute || ${1-} == --resume ]]\n[[ -z ${PIPELINE_ARGV-} ]] || printf "%%s\\n" "${1-}" >"$PIPELINE_ARGV"\n[[ -z ${PIPELINE_ENV-} ]] || printf "%%s\\n%%s\\n" "$XDG_RUNTIME_DIR" "$DBUS_SESSION_BUS_ADDRESS" >"$PIPELINE_ENV"\n[[ ${1-} != --check-only || -z ${PIPELINE_CHECK_SLEEP-} ]] || sleep "$PIPELINE_CHECK_SLEEP"\n' >"$out"; chmod 500 "$out"
EOF
chmod 644 "$generate"
psha=$(sha256sum "$prepare"|awk '{print $1}'); gsha=$(sha256sum "$generate"|awk '{print $1}')
if VIEWFLOW_PIPELINE_STATE=$state PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha \
  bash "$pipeline" --check --freshness-seconds 301 --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >/dev/null 2>"$tmp/over-age.err"; then
  echo 'accepted freshness window beyond Windows installer default' >&2; exit 1
fi
rg -Fq 'freshness must be 1..300 seconds' "$tmp/over-age.err"
VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha \
  bash "$pipeline" --prepare-generate-check --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >"$tmp/out"
rg -Fq "candidate=$state/candidates/v21-operation-$op" "$tmp/out"
rg -Fq "operation=$op" "$tmp/out"
[[ -x $root/launch-normal-v21.sh ]]
# Simulate the exact crash window after rename_new(stage,candidate): a valid
# candidate remains but its first-candidate commit and launcher do not.
rm -f -- "$root/first-candidate-commit.json" "$root/launch-normal-v21.sh"
VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha \
  bash "$pipeline" --prepare-generate-check --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >"$tmp/recovered"
[[ -f $root/first-candidate-commit.json && -x $root/launch-normal-v21.sh ]]
rg -Fq 'candidate=' "$tmp/recovered"
# Resume cannot start without a durable coordinator state.
if VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha bash "$pipeline" --resume --allow-live-execute --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >/dev/null 2>&1; then
  echo 'resume accepted missing coordinator state' >&2; exit 1
fi
printf '{}' >"$root/coordinator-state.json"; chmod 600 "$root/coordinator-state.json"
if VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha bash "$pipeline" --execute --allow-live-execute --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >/dev/null 2>&1; then
  echo 'execute accepted existing coordinator state' >&2; exit 1
fi
PIPELINE_ARGV=$tmp/resume.argv PIPELINE_ENV=$tmp/resume.env XDG_RUNTIME_DIR=/tmp/not-the-user-runtime \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/not-the-user-bus \
  VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed \
  PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha \
  bash "$pipeline" --resume --allow-live-execute --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate"
[[ $(<"$tmp/resume.argv") == --resume ]]
mapfile -t resume_env <"$tmp/resume.env"
[[ ${resume_env[0]} == /run/user/1000 && ${resume_env[1]} == unix:path=/run/user/1000/bus ]]
rm -f -- "$root/coordinator-state.json"
# Fresh publication cannot compensate for stale Linux frozen evidence.  This
# must fail before the launcher --check-only barrier, which may contact SSH.
if PIPELINE_ARGV=$tmp/stale.argv VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha bash "$pipeline" --execute --allow-live-execute --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >/dev/null 2>"$tmp/stale.err"; then
  echo 'execute accepted fresh publication with stale Linux frozen evidence' >&2; exit 1
fi
rg -Fq 'Linux frozen evidence is' "$tmp/stale.err"
[[ ! -e $tmp/stale.argv ]] || { echo 'execute reached launcher check with stale Linux frozen evidence' >&2; exit 1; }
printf 'mutated artifact\n' >"$state/candidates/v21-operation-$op/windows-source.manifest.sha256"
chmod 600 "$state/candidates/v21-operation-$op/windows-source.manifest.sha256"
if VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha bash "$pipeline" --check --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >/dev/null 2>&1; then
  echo 'check accepted mutated candidate artifact' >&2; exit 1
fi
cp -- "$seed/windows-source.manifest.sha256" "$state/candidates/v21-operation-$op/windows-source.manifest.sha256"
chmod 600 "$state/candidates/v21-operation-$op/windows-source.manifest.sha256"
python3 - "$root/v4-inactive-terminal-to-fresh-v21.json" <<'PY'
import json,sys
p=sys.argv[1]; x=json.load(open(p)); x['new_operation_id']='f'*32; open(p,'w').write(json.dumps(x,separators=(',',':')))
PY
if VIEWFLOW_PIPELINE_STATE=$state VIEWFLOW_FRESH_FIRST_SEED=$seed PIPELINE_PREPARE_SHA=$psha PIPELINE_GENERATE_SHA=$gsha bash "$pipeline" --check --operation-id "$op" --coordinator-uuid "$coord" --fresh-root "$root" --bridge-final-receipt "$root/v4-inactive-terminal-to-fresh-v21.json" --bridge-final-receipt-sha256 "$(sha256sum "$root/v4-inactive-terminal-to-fresh-v21.json"|awk '{print $1}')" --prepare-script "$prepare" --generate-script "$generate" >/dev/null 2>&1; then
  echo 'accepted cross-operation bridge final' >&2; exit 1
fi
printf 'normal v21 operation pipeline hermetic test passed\n'
