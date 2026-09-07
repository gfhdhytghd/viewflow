#!/usr/bin/env bash
set -Eeuo pipefail
readonly PATH=/usr/bin:/bin
export PATH
umask 077

launcher=/home/wilf/data/viewflow/deploy/launch-early-bootstrap-gate-abort-4fba4c83.sh
launcher_checker=/home/wilf/data/viewflow/deploy/check-launch-early-bootstrap-gate-abort-4fba4c83.sh
helper=/home/wilf/data/viewflow/deploy/early-bootstrap-gate-runtime-helper-4fba4c83.py
helper_checker=/home/wilf/data/viewflow/deploy/check-early-bootstrap-gate-runtime-helper-4fba4c83.sh
core=/home/wilf/data/viewflow/deploy/early-bootstrap-gate-abort-core-4fba4c83.py
core_checker=/home/wilf/data/viewflow/deploy/check-early-bootstrap-gate-abort-core-4fba4c83.sh
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT

mutate_rejected() {
    local label=$1 checker=$2 source=$3 old=$4 new=$5
    local target="$root/$label"
    /usr/bin/python3 -I - "$source" "$target" "$old" "$new" <<'PY'
from pathlib import Path
import sys
source,target,old,new=sys.argv[1:]
data=Path(source).read_text(encoding='utf-8')
if data.count(old)<1: raise SystemExit('mutation anchor missing: '+old)
Path(target).write_text(data.replace(old,new,1),encoding='utf-8')
Path(target).chmod(0o755)
PY
    if "$checker" "$target" >/dev/null 2>&1; then
        printf 'negative mutation accepted: %s\n' "$label" >&2
        exit 1
    fi
}

mutate_rejected wrong_op "$launcher_checker" "$launcher" \
    4fba4c832389436ba980efaa4540f6bf 0fba4c832389436ba980efaa4540f6bf
mutate_rejected wrong_op_count "$launcher_checker" "$launcher" \
    "'4fba4c832389436ba980efaa4540f6bf',2" "'4fba4c832389436ba980efaa4540f6bf',1"
mutate_rejected wrong_manifest "$launcher_checker" "$launcher" \
    early-bootstrap-gate-abort-manifest.4fba.v1.json early-bootstrap-gate-abort-manifest.reused.json
mutate_rejected wrong_core "$launcher_checker" "$launcher" \
    early-bootstrap-gate-abort-core-4fba4c83.py early-bootstrap-gate-abort.py
mutate_rejected wrong_core_sha "$launcher_checker" "$launcher" \
    613624f4fafb4a6cc9227cefb525dd758dde4b7e5c7d13e0610983e744d4b95f 013624f4fafb4a6cc9227cefb525dd758dde4b7e5c7d13e0610983e744d4b95f
mutate_rejected wrong_helper "$launcher_checker" "$launcher" \
    early-bootstrap-gate-runtime-helper-4fba4c83.py early-bootstrap-gate-runtime-helper.py
mutate_rejected wrong_helper_sha "$launcher_checker" "$launcher" \
    5f160911c6ea894daca7dfe103b560c53e6d60fd5633673169158f93c921cba5 0f160911c6ea894daca7dfe103b560c53e6d60fd5633673169158f93c921cba5
mutate_rejected state_drift "$launcher_checker" "$launcher" \
    1b737f18e97f0b9e4a4601febd0d301fcfa0eb222ab2a0995ec4fecfc62f92b2 0b737f18e97f0b9e4a4601febd0d301fcfa0eb222ab2a0995ec4fecfc62f92b2
mutate_rejected handoff_drift "$launcher_checker" "$launcher" \
    72dbf31cb148267afa6c7066ec0271af54f807ac1b9c4623f753875d85c9ee03 02dbf31cb148267afa6c7066ec0271af54f807ac1b9c4623f753875d85c9ee03
mutate_rejected frozen_drift "$launcher_checker" "$launcher" \
    923ffe9ca469b16555f10659dc8cdad60ad2841e82a81b69c35cff93ee712cbb 023ffe9ca469b16555f10659dc8cdad60ad2841e82a81b69c35cff93ee712cbb
mutate_rejected publish_drift "$launcher_checker" "$launcher" \
    61c47e7fce77247ac9c5f4be3ca0cf059c77d23e61175050371b13b3c444bbac 01c47e7fce77247ac9c5f4be3ca0cf059c77d23e61175050371b13b3c444bbac
mutate_rejected request_drift "$launcher_checker" "$launcher" \
    1587817d4f0e589e5d1c931df345b16002892ad658386bb23f98d21de5dac085 0587817d4f0e589e5d1c931df345b16002892ad658386bb23f98d21de5dac085
mutate_rejected stop_drift "$launcher_checker" "$launcher" \
    e3bd88a07453f54607eedbb398c31175ce77548b7d574f94359e7bdc1888ce81 03bd88a07453f54607eedbb398c31175ce77548b7d574f94359e7bdc1888ce81
mutate_rejected marker_drift "$launcher_checker" "$launcher" \
    7b8744179ac3cdcecf01a4d7a85ac5f655b217f3b4828866681bc6775ad8ab04 0b8744179ac3cdcecf01a4d7a85ac5f655b217f3b4828866681bc6775ad8ab04
mutate_rejected coordinator_drift "$launcher_checker" "$launcher" \
    e306c15a-2a70-4fd3-9ca6-5a03ac23adfb 0306c15a-2a70-4fd3-9ca6-5a03ac23adfb
mutate_rejected candidate_drift "$launcher_checker" "$launcher" \
    8d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54 0d0945c582d249eb12b27f0e2eea109cc5fe20fe45358eacb3a43ff0d3880c54
mutate_rejected provenance_drift "$launcher_checker" "$launcher" \
    995e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d 095e2a7940de17f82ef33e48ea165a8df8ba44a641c80072d711a4b0dcaefc4d
mutate_rejected unsafe_follow "$launcher_checker" "$launcher" \
    'os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW' 'os.O_RDONLY|os.O_CLOEXEC'
mutate_rejected unsealed_launcher "$launcher_checker" "$launcher" \
    'fcntl.fcntl(memfd,fcntl.F_ADD_SEALS,seals)' 'pass # no seals'

mutate_rejected helper_wrong_op "$helper_checker" "$helper" \
    'OPERATION_ID = "4fba4c832389436ba980efaa4540f6bf"' 'OPERATION_ID = "2ca3f46635b65615a1cffc1970d73911"'
mutate_rejected helper_wrong_source "$helper_checker" "$helper" \
    'GENERIC_HELPER_SHA256 = "bd562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7"' 'GENERIC_HELPER_SHA256 = "0d562f25214cf337bd09c5b82c4ed866fdc8ac79ffb9da22ac8f5b380d659ac7"'
mutate_rejected helper_wrong_count "$helper_checker" "$helper" \
    'EXPECTED_OPERATION_OCCURRENCES = 2' 'EXPECTED_OPERATION_OCCURRENCES = 1'
mutate_rejected helper_follows_symlink "$helper_checker" "$helper" \
    'os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW' 'os.O_RDONLY | os.O_CLOEXEC'
mutate_rejected helper_disk_write "$helper_checker" "$helper" \
    'source = operation_source()' 'Path("/tmp/helper").write_bytes(operation_source()); source = operation_source()'

mutate_rejected core_wrong_source "$core_checker" "$core" \
    'GENERIC_CORE_SHA256 = "feb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6"' 'GENERIC_CORE_SHA256 = "0eb107342827abc813f5262829a77ddecb6ca1cc19e30cde2710dff540ce87f6"'
mutate_rejected core_wrong_empty_semantics "$core_checker" "$core" \
    'windows_task_xml_sha256_override"] != ""' 'windows_task_xml_sha256_override"] == ""'
mutate_rejected core_broadens_override "$core_checker" "$core" \
    'source.count(old) != 1' 'source.count(old) < 1'
mutate_rejected core_follows_symlink "$core_checker" "$core" \
    'os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW' 'os.O_RDONLY | os.O_CLOEXEC'
mutate_rejected core_disk_write "$core_checker" "$core" \
    'source = operation_source()' 'Path("/tmp/core").write_bytes(operation_source()); source = operation_source()'

printf '4fba early bootstrap gate static-negative matrix passed\n'
