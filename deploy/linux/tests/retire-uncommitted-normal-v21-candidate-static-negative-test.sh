#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE=${1:-$HERE/../retire-uncommitted-normal-v21-candidate.sh}
CHECKER=${2:-$HERE/../check-retire-uncommitted-normal-v21-candidate.sh}
TMP=$(mktemp -d --tmpdir viewflow-retire-static-negative.XXXXXXXX)
trap 'rm -rf -- "$TMP"' EXIT

bash "$CHECKER" "$SOURCE" >/dev/null

mutate_reject() {
    local label=$1 old=$2 new=$3 candidate
    candidate=$TMP/$label.sh
    python3 - "$SOURCE" "$candidate" "$old" "$new" <<'PY'
from pathlib import Path
import sys
source,target,old,new=sys.argv[1:]
text=Path(source).read_text(encoding='utf-8')
if old not in text:
    raise SystemExit('mutation anchor absent: '+repr(old))
Path(target).write_text(text.replace(old,new),encoding='utf-8')
PY
    chmod 0755 "$candidate"
    if bash "$CHECKER" "$candidate" >/dev/null 2>&1; then
        printf 'checker accepted unsafe mutation: %s\n' "$label" >&2
        exit 1
    fi
}

mutate_reject mode-union '--check-only|--execute|--resume|--replay' '--check-only|--execute|--resume'
mutate_reject runtime-mode 'MODE in ("--check-only", "--execute", "--resume", "--replay")' 'MODE in ("--check-only", "--execute")'
mutate_reject operation-root 'OP_ROOT == STATE + "/deployments/" + OP' 'OP_ROOT.startswith(STATE + "/deployments/")'
mutate_reject candidate-root 'CANDIDATE == CANDIDATES + "/" + SOURCE_LEAF' 'CANDIDATE.startswith(CANDIDATES + "/")'
mutate_reject coordinator-canonical 'UUID.fullmatch(COORD) is not None' 'True # coordinator UUID bypassed'
mutate_reject archive-address 'ARCHIVE_LEAF = SOURCE_LEAF + ".rejected-" + MANIFEST_SHA' 'ARCHIVE_LEAF = SOURCE_LEAF + ".rejected"'
mutate_reject terminal-leaf 'TERMINAL_LEAF = "candidate-retirement-terminal.json"' 'TERMINAL_LEAF = "normal-v21-candidate-retired.json"'
mutate_reject nofollow 'os.O_NOFOLLOW' '0 # nofollow removed'
mutate_reject anonymous-temp 'os.O_TMPFILE' 'os.O_CREAT'
mutate_reject empty-path 'AT_EMPTY_PATH = 0x1000' 'AT_EMPTY_PATH = 0'
mutate_reject rename-noreplace 'RENAME_NOREPLACE = 1' 'RENAME_NOREPLACE = 0'
mutate_reject fsync-source 'os.fsync(candidates_fd)' 'pass # source parent not durable'
mutate_reject fsync-target 'os.fsync(rejected_fd)' 'pass # archive parent not durable'
mutate_reject same-inode 'meta_tuple(archive_st) == meta_tuple(candidate_st)' 'True # inode check bypassed'
mutate_reject acl 'ACL_NAMES = {"system.posix_acl_access", "system.posix_acl_default"}' 'ACL_NAMES = set()'
mutate_reject operation-leaves 'names == allowed' 'True # unknown outputs accepted'
mutate_reject prestate-leaves 'BASE_OPERATION_LEAVES = {"deployment-publish.json", "linux-frozen.json", "marker-handoff.json"}' 'BASE_OPERATION_LEAVES = {"deployment-publish.json"}'
mutate_reject coordinator-absence '"coordinator_state_absent": True' '"coordinator_state_absent": False'
mutate_reject output-absence '"standard_normal_outputs_absent": True' '"standard_normal_outputs_absent": False'
mutate_reject marker-magic 'marker_data[:8] == b"VFDQT001"' 'True # marker magic bypassed'
mutate_reject marker-size 'marker_st.st_size == 256' 'marker_st.st_size >= 0'
mutate_reject tree-framing 'name + "\0" + f"{mode:04o}" + "\0" + str(st.st_size) +' 'name + ":" + f"{mode:04o}" + ":" + str(st.st_size) +'
mutate_reject mode-format 'f"{mode:04o}"' 'oct(mode)'
mutate_reject unix-ms-type 'type(value["created_at_unix_ms"]) is int' 'True # timestamp type bypassed'
mutate_reject utc-canonical 'UTC.fullmatch(value["created_at_utc"])' 'True # UTC bypassed'
mutate_reject duplicate-json 'duplicate JSON key in input' 'duplicate key ignored'
mutate_reject seed-binding 'authorized seed manifest SHA-256 differs' 'seed accepted without hash'
mutate_reject both-state 'source and archive names both exist' 'dual state accepted'
mutate_reject missing-state 'neither source nor archived candidate exists' 'missing state accepted'
mutate_reject replay-state 'replay requires the committed archive state' 'replay accepts source state'
mutate_reject terminal-state 'terminal receipt may exist only after the candidate rename committed' 'terminal accepted before rename'
mutate_reject intent-publication 'publish_create_once(operation_fd, INTENT_LEAF, canonical_bytes(intent), "retirement intent")' 'intent_present = True # intent publication bypassed'
mutate_reject terminal-publication 'publish_create_once(operation_fd, TERMINAL_LEAF, canonical_bytes(terminal), "terminal receipt")' 'terminal_present = True # terminal publication bypassed'
mutate_reject resume-content 'resume archive content differs' 'resume archive accepted'
mutate_reject destructive-rename 'rename_candidate(candidates_fd, rejected_fd, candidate_fd, candidate_st)' 'os.rename(CANDIDATE, ARCHIVE)'

printf 'uncommitted normal v2.1 candidate retirement static negatives passed\n'
