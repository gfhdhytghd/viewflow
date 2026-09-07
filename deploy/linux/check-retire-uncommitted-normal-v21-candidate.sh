#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/retire-uncommitted-normal-v21-candidate.sh}
fail() { printf 'error: retirement checker: %s\n' "$*" >&2; exit 1; }
[[ -f $SOURCE && ! -L $SOURCE ]] || fail 'producer must be a regular non-symlink file'
bash -n "$SOURCE" || fail 'bash syntax failed'
shellcheck --severity=error "$SOURCE" || fail 'ShellCheck failed'

python3 - "$SOURCE" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")

def fail(message):
    raise SystemExit("error: retirement checker: " + message)

def need(token, label):
    if token not in text:
        fail("missing contract: " + label)

for token, label in [
    ('--check-only|--execute|--resume|--replay', 'exact mode dispatcher'),
    ('MODE in ("--check-only", "--execute", "--resume", "--replay")', 'runtime mode union'),
    ('OP_ROOT == STATE + "/deployments/" + OP', 'canonical operation root'),
    ('CANDIDATE == CANDIDATES + "/" + SOURCE_LEAF', 'canonical candidate root'),
    ('UUID.fullmatch(COORD) is not None', 'canonical coordinator UUID'),
    ('ARCHIVE_LEAF = SOURCE_LEAF + ".rejected-" + MANIFEST_SHA', 'content addressed archive'),
    ('normal-v21-candidate-retirement.intent.json', 'fixed durable intent'),
    ('candidate-retirement-terminal.json', 'fixed terminal receipt'),
    ('fcntl.LOCK_EX | fcntl.LOCK_NB', 'per-operation transaction lock'),
    ('os.O_NOFOLLOW', 'nofollow descriptors'),
    ('os.O_TMPFILE', 'anonymous receipt construction'),
    ('AT_EMPTY_PATH = 0x1000', 'create-once link publication'),
    ('create-once publication refused', 'receipt no-clobber'),
    ('RENAME_NOREPLACE = 1', 'candidate no-replace rename'),
    ('os.fsync(candidates_fd)', 'source parent durability'),
    ('os.fsync(rejected_fd)', 'archive parent durability'),
    ('meta_tuple(archive_st) == meta_tuple(candidate_st)', 'same inode verification'),
    ('ACL_NAMES = {"system.posix_acl_access", "system.posix_acl_default"}', 'ACL rejection'),
    ('names == allowed', 'exact operation-root leaf gate'),
    ('BASE_OPERATION_LEAVES = {"deployment-publish.json", "linux-frozen.json", "marker-handoff.json"}', 'P/H/F-only prestate'),
    ('"coordinator_state_absent": True', 'coordinator state absence receipt'),
    ('"standard_normal_outputs_absent": True', 'normal output absence receipt'),
    ('marker_data[:8] == b"VFDQT001"', 'deployment marker magic'),
    ('marker_st.st_size == 256', 'deployment marker size'),
    ('deployment_publish_receipt_sha256', 'P binding'),
    ('marker_handoff_sha256', 'H binding'),
    ('linux_frozen_sha256', 'F binding'),
    ('authorized seed manifest SHA-256 differs', 'authorized seed hash binding'),
    ('duplicate JSON key in input', 'duplicate-key rejection'),
    ('floating or non-finite JSON number', 'non-integral number rejection'),
    ('has trailing JSON data', 'single JSON object parser'),
    ('data.decode("utf-8", "strict")', 'strict UTF-8 parser'),
    ('"candidate-manifest.json",\n    "windows-native-provenance.json",\n    "windows-source.manifest.sha256",\n    "windows-source.tar.gz",\n    "windows-source.tar.gz.sha256",\n    "windows-viewflowd.exe",', 'exact six candidate leaves'),
    ('name + "\\0" + f"{mode:04o}" + "\\0" + str(st.st_size) +\n                       "\\0" + sha + "\\n"', 'frozen tree-hash algorithm'),
    ('f"{mode:04o}"', 'four-digit octal modes'),
    ('"replacement_ordinal": 1', 'replacement ordinal'),
    ('type(value["created_at_unix_ms"]) is int', 'integer Unix milliseconds'),
    ('UTC.fullmatch(value["created_at_utc"])', 'canonical millisecond UTC'),
    ('source and archive names both exist', 'partial state fail closed'),
    ('neither source nor archived candidate exists', 'missing state fail closed'),
    ('replay requires the committed archive state', 'replay state gate'),
    ('terminal receipt may exist only after the candidate rename committed', 'terminal state gate'),
    ('resume archive content differs', 'resume content revalidation'),
]:
    need(token, label)

terminal_order = ('["schema_version", "state", "operation_id", "coordinator_instance_id",\n'
                  '               "replacement_ordinal", "created_at_unix_ms", "created_at_utc", "operation_root",\n'
                  '               "candidate_root", "old_candidate", "fresh_boundary", "authorized_seed",\n'
                  '               "pre_retirement"]')
need(terminal_order, 'terminal ordered root schema')
need('["canonical_path", "archive_path", "manifest_sha256",\n               "tree_sha256", "files"]',
     'old_candidate ordered schema')
need('["deployment_publish_path", "deployment_publish_sha256",\n               "marker_handoff_path", "marker_handoff_sha256", "linux_frozen_path",\n               "linux_frozen_sha256", "deployment_marker_path", "deployment_marker_sha256"]',
     'fresh_boundary ordered schema')
need('["root", "candidate_manifest_path",\n               "candidate_manifest_sha256"]',
     'authorized_seed ordered schema')
need('["coordinator_state_path", "coordinator_state_absent",\n               "standard_normal_outputs_absent"]',
     'pre_retirement ordered schema')
need('["name", "mode", "size_bytes", "sha256"]', 'file record ordered schema')

intent_publish = text.rfind('publish_create_once(operation_fd, INTENT_LEAF')
candidate_rename = text.rfind('rename_candidate(candidates_fd, rejected_fd')
terminal_publish = text.rfind('publish_create_once(operation_fd, TERMINAL_LEAF')
if not (0 <= intent_publish < candidate_rename < terminal_publish):
    fail('intent/rename/terminal transaction ordering differs')

for forbidden in ('systemctl ', 'ssh ', 'subprocess.', 'shutil.rmtree', 'os.replace(', 'os.rename(',
                  'unlink(', 'remove('):
    if forbidden in text:
        fail('forbidden live/destructive primitive: ' + forbidden)

print('uncommitted normal v2.1 candidate retirement checker passed')
PY
