#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source=$here/../normal-v21-operation-pipeline.sh
helper=$here/../prepare-normal-v21-fresh-first-candidate.sh
bash -n "$source"
shellcheck -s bash "$source"
[[ -f $helper && ! -L $helper ]] || { echo 'fresh-first helper missing' >&2; exit 1; }
bash -n "$helper"; shellcheck -s bash "$helper"
for token in 'PREPARE_SHA=' 'GENERATE_SHA=' 'USER_RUNTIME_DIR=/run/user/1000' 'USER_BUS_ADDRESS=unix:path=/run/user/1000/bus' 'assert_user_bus' 'real owner-only /run/user/1000 runtime directory' 'uid-1000 D-Bus socket' 'v4-inactive-terminal-to-fresh-v21.json' 'bridge final schema' 'bridge old operation identity' 'bridge inactive-source closure' 'bridge persistent-v13 closure' 'candidate operation binding' 'candidate exact six leaves' 'first-candidate commit closure' 'commit_keys=' '--bridge-final-receipt' '--allow-live-execute' '--resume' 'marker is ${marker_age}s old' 'Linux frozen evidence is ${frozen_age}s old' 'frozen completion timestamp' 'age_ms > int(max_age)*1000' 'frozen_age_ms > int(max_age)*1000' 'freshness must be 1..300' 'bash "$launcher" --check-only' 'exec "$launcher" --execute' 'exec "$launcher" --resume'; do
  rg -Fq -- "$token" "$source" || { echo "missing pipeline contract: $token" >&2; exit 1; }
done
[[ $(rg -c '^[[:space:]]+assert_user_bus$' "$source") == 2 ]] || {
  echo 'execute/resume must each cross the user-bus gate exactly once' >&2
  exit 1
}
python3 - "$source" <<'PY'
import sys
s=open(sys.argv[1]).read()
gate='[[ $frozen_state == fresh ]] || die "Linux frozen evidence is ${frozen_age}s old; bridge a new operation instead of extending freshness"'
check='bash "$launcher" --check-only'
assert s.count(gate)==2 and s.index(gate)<s.index(check), 'frozen evidence gate must precede launcher check'
PY
! rg -n 'ssh[[:space:]]|systemctl|scp[[:space:]]|TODO|PLACEHOLDER' "$source" >/dev/null || { echo 'pipeline contains live/placeholder token' >&2; exit 1; }
for token in 'candidate exists; use --resume only for strict first-candidate recovery' 'candidate exact six leaves' 'if not ((a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns)==' 'bridge old operation identity' 'bridge inactive-source closure' 'bridge persistent-v13 closure' 'bridge fresh boundary' 'viewflow-normal-v21-first-candidate-committed' 'renameat2' 'O_NOFOLLOW' 'os.fsync(dfd)'; do
  rg -Fq -- "$token" "$helper" || { echo "missing fresh-first helper contract: $token" >&2; exit 1; }
done
! rg -n 'ssh[[:space:]]|systemctl|scp[[:space:]]|TODO|PLACEHOLDER|candidate-retirement-terminal' "$helper" >/dev/null || { echo 'fresh-first helper contains invalid live/replacement token' >&2; exit 1; }
tmp=$(mktemp -d --tmpdir normal-v21-pipeline-negative.XXXXXX); trap 'rm -rf -- "$tmp"' EXIT
cp -- "$source" "$tmp/pipeline"
python3 - "$tmp/pipeline" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); old="if m.get('schema_version')!=1 or m.get('operation_id')!=op or m.get('coordinator_instance_id')!=coord or 'candidate_replacement' in m: die('candidate operation binding')"; assert old in s; open(p,'w').write(s.replace(old,"if m.get('schema_version')!=1: pass # broken",1))
PY
! rg -Fq 'candidate operation binding' "$tmp/pipeline" || { echo 'negative mutation did not apply' >&2; exit 1; }
cp -- "$source" "$tmp/bus-bypass"
python3 - "$tmp/bus-bypass" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); old='    assert_user_bus\n    exec "$launcher" --execute'; assert old in s; open(p,'w').write(s.replace(old,'    exec "$launcher" --execute',1))
PY
[[ $(rg -c '^[[:space:]]+assert_user_bus$' "$tmp/bus-bypass") != 2 ]] || {
  echo 'user-bus bypass mutation was not detected' >&2
  exit 1
}
cp -- "$helper" "$tmp/helper"
python3 - "$tmp/helper" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); old="if not ((a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns)==(z.st_dev,z.st_ino,z.st_size,z.st_mtime_ns)==(b.st_dev,b.st_ino,b.st_size,b.st_mtime_ns)): die('changed '+str(p))"; assert old in s; open(p,'w').write(s.replace(old,"if (a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns)!=(z.st_dev,z.st_ino,z.st_size,z.st_mtime_ns)!=(b.st_dev,b.st_ino,b.st_size,b.st_mtime_ns): pass # path-swap bypass",1))
PY
! rg -Fq 'not ((a.st_dev,a.st_ino,a.st_size,a.st_mtime_ns)==' "$tmp/helper" || { echo 'path-swap mutation was not applied' >&2; exit 1; }
printf 'normal v21 operation pipeline static-negative test passed\n'
