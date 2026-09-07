#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
    cat >&2 <<'EOF'
Usage: retire-uncommitted-normal-v21-candidate.sh MODE \
  --operation-id HEX32 --coordinator-instance-id UUID \
  --operation-root DIR --candidate-root DIR \
  --candidate-manifest-sha256 LOWER64 \
  --authorized-seed-root DIR --authorized-seed-manifest-sha256 LOWER64

MODE is exactly one of: --check-only --execute --resume --replay
EOF
}

mode=''
operation_id=''
coordinator_id=''
operation_root=''
candidate_root=''
candidate_manifest_sha=''
seed_root=''
seed_manifest_sha=''

while (($#)); do
    case $1 in
        --check-only|--execute|--resume|--replay)
            [[ -z $mode ]] || { usage; exit 64; }
            mode=$1
            shift
            ;;
        --operation-id) operation_id=${2-}; shift 2 ;;
        --coordinator-instance-id) coordinator_id=${2-}; shift 2 ;;
        --operation-root) operation_root=${2-}; shift 2 ;;
        --candidate-root) candidate_root=${2-}; shift 2 ;;
        --candidate-manifest-sha256) candidate_manifest_sha=${2-}; shift 2 ;;
        --authorized-seed-root) seed_root=${2-}; shift 2 ;;
        --authorized-seed-manifest-sha256) seed_manifest_sha=${2-}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 64 ;;
    esac
done

[[ -n $mode && -n $operation_id && -n $coordinator_id && -n $operation_root &&
   -n $candidate_root && -n $candidate_manifest_sha && -n $seed_root &&
   -n $seed_manifest_sha ]] || { usage; exit 64; }

exec python3 - "$mode" "$operation_id" "$coordinator_id" "$operation_root" \
    "$candidate_root" "$candidate_manifest_sha" "$seed_root" "$seed_manifest_sha" <<'PY'
import ctypes
import datetime
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import time

MODE, OP, COORD, OP_ROOT, CANDIDATE, MANIFEST_SHA, SEED_ROOT, SEED_SHA = sys.argv[1:]
UID = 1000
STATE = "/home/wilf/.local/state/viewflow"
CANDIDATES = STATE + "/candidates"
REJECTED = CANDIDATES + "/rejected"
SOURCE_LEAF = "v21-operation-" + OP
ARCHIVE_LEAF = SOURCE_LEAF + ".rejected-" + MANIFEST_SHA
ARCHIVE = REJECTED + "/" + ARCHIVE_LEAF
INTENT_LEAF = "normal-v21-candidate-retirement.intent.json"
TERMINAL_LEAF = "candidate-retirement-terminal.json"
INTENT_PATH = OP_ROOT + "/" + INTENT_LEAF
TERMINAL_PATH = OP_ROOT + "/" + TERMINAL_LEAF
HEX32 = re.compile(r"[0-9a-f]{32}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")
EXPECTED_FILES = [
    "candidate-manifest.json",
    "windows-native-provenance.json",
    "windows-source.manifest.sha256",
    "windows-source.tar.gz",
    "windows-source.tar.gz.sha256",
    "windows-viewflowd.exe",
]
BASE_OPERATION_LEAVES = {"deployment-publish.json", "linux-frozen.json", "marker-handoff.json"}
ACL_NAMES = {"system.posix_acl_access", "system.posix_acl_default"}


def die(message):
    raise SystemExit("error: candidate retirement: " + message)


def req(condition, message):
    if not condition:
        die(message)


def exact_keys(value, ordered, label):
    req(type(value) is dict and list(value.keys()) == ordered, label + " exact ordered keys differ")


def exact_members(value, names, label):
    req(type(value) is dict and set(value.keys()) == set(names), label + " exact keys differ")


def pairs(items):
    out = {}
    for key, value in items:
        if key in out:
            die("duplicate JSON key in input: " + repr(key))
        out[key] = value
    return out


def bad_number(token):
    die("floating or non-finite JSON number: " + token)


def strict_json(data, label):
    try:
        text = data.decode("utf-8", "strict")
        decoder = json.JSONDecoder(
            object_pairs_hook=pairs, parse_float=bad_number, parse_constant=bad_number
        )
        value, end = decoder.raw_decode(text)
    except (UnicodeError, json.JSONDecodeError) as error:
        die(label + " is not strict JSON: " + str(error))
    req(text[end:].strip() == "", label + " has trailing JSON data")
    req(type(value) is dict, label + " must be one JSON object")
    return value


def has_acl(fd, label):
    try:
        names = set(os.listxattr(fd))
    except OSError as error:
        die(label + " xattr inspection failed: " + str(error))
    req(not (names & ACL_NAMES), label + " must not have a POSIX ACL")


def meta_tuple(st):
    return (st.st_dev, st.st_ino, st.st_uid, stat.S_IMODE(st.st_mode), st.st_nlink, st.st_size)


def validate_meta(fd, label, kind, mode, nlink=1):
    st = os.fstat(fd)
    req(stat.S_ISDIR(st.st_mode) if kind == "dir" else stat.S_ISREG(st.st_mode),
        label + " has wrong type")
    req(st.st_uid == UID and stat.S_IMODE(st.st_mode) == mode and st.st_nlink == nlink,
        label + " owner/mode/link identity differs")
    has_acl(fd, label)
    return st


def canonical_absolute(path, label):
    req(path.startswith("/") and os.path.normpath(path) == path and "//" not in path,
        label + " is not a canonical absolute path")


def open_dir(path, mode, label):
    canonical_absolute(path, label)
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.split("/")[1:]:
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=fd,
            )
            os.close(fd)
            fd = next_fd
        st = validate_meta(fd, label, "dir", mode)
        named = os.stat(path, follow_symlinks=False)
        req(meta_tuple(named) == meta_tuple(st), label + " pathname changed while opening")
        return fd
    except BaseException:
        os.close(fd)
        raise


def revalidate_dir_path(path, fd, label, mode=0o700):
    st = validate_meta(fd, label, "dir", mode)
    try:
        named = os.stat(path, follow_symlinks=False)
    except OSError as error:
        die(label + " pathname disappeared: " + str(error))
    req(meta_tuple(named) == meta_tuple(st), label + " pathname/inode changed")


def exists_at(parent_fd, name):
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def read_file_at(parent_fd, name, mode, label):
    req("/" not in name and name not in ("", ".", ".."), label + " unsafe leaf")
    try:
        fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent_fd)
    except OSError as error:
        die(label + " cannot be opened: " + str(error))
    try:
        before = validate_meta(fd, label, "file", mode)
        data = bytearray()
        while True:
            chunk = os.read(fd, 131072)
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        req(meta_tuple(before) == meta_tuple(after), label + " changed while read")
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        req(meta_tuple(named) == meta_tuple(after), label + " pathname changed while read")
        req(len(data) == after.st_size, label + " size changed while read")
        return bytes(data), hashlib.sha256(data).hexdigest(), after
    finally:
        os.close(fd)


def read_absolute_file(path, mode, label):
    canonical_absolute(path, label)
    parent_path, leaf = os.path.split(path)
    parent_fd = open_dir(parent_path, 0o700, label + " parent")
    try:
        return read_file_at(parent_fd, leaf, mode, label)
    finally:
        os.close(parent_fd)


def canonical_bytes(value):
    return (json.dumps(value, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def publish_create_once(parent_fd, leaf, data, label):
    flags = os.O_TMPFILE | os.O_RDWR | os.O_CLOEXEC
    try:
        temp_fd = os.open(".", flags, 0o600, dir_fd=parent_fd)
    except OSError as error:
        die(label + " O_TMPFILE creation failed: " + str(error))
    try:
        os.fchmod(temp_fd, 0o600)
        view = memoryview(data)
        while view:
            written = os.write(temp_fd, view)
            req(written > 0, label + " short write")
            view = view[written:]
        os.fsync(temp_fd)
        libc = ctypes.CDLL(None, use_errno=True)
        linkat = libc.linkat
        linkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                           ctypes.c_char_p, ctypes.c_int]
        linkat.restype = ctypes.c_int
        AT_EMPTY_PATH = 0x1000
        if linkat(temp_fd, b"", parent_fd, os.fsencode(leaf), AT_EMPTY_PATH) != 0:
            error = ctypes.get_errno()
            if error == errno.EEXIST:
                die(label + " already exists (create-once publication refused)")
            raise OSError(error, os.strerror(error))
        os.fsync(parent_fd)
    finally:
        os.close(temp_fd)
    got, _, _ = read_file_at(parent_fd, leaf, 0o600, label)
    req(got == data, label + " publication bytes differ")


def file_tree(directory_fd, label):
    try:
        os.lseek(directory_fd, 0, os.SEEK_SET)
        names = os.listdir(directory_fd)
    except OSError as error:
        die(label + " cannot be listed: " + str(error))
    try:
        ordered = sorted(names, key=lambda value: value.encode("ascii"))
    except UnicodeEncodeError:
        die(label + " contains a non-ASCII leaf")
    req(ordered == EXPECTED_FILES, label + " must contain exactly the six reviewed leaves")
    records = []
    digest = hashlib.sha256()
    blobs = {}
    for name in ordered:
        mode = 0o700 if name == "windows-viewflowd.exe" else 0o600
        data, sha, st = read_file_at(directory_fd, name, mode, label + "/" + name)
        record = {"name": name, "mode": f"{mode:04o}", "size_bytes": st.st_size, "sha256": sha}
        records.append(record)
        blobs[name] = data
        digest.update((name + "\0" + f"{mode:04o}" + "\0" + str(st.st_size) +
                       "\0" + sha + "\n").encode("ascii"))
    return records, digest.hexdigest(), blobs


def validate_candidate(files, blobs):
    manifest = strict_json(blobs["candidate-manifest.json"], "candidate manifest")
    exact_members(manifest, ["schema_version", "kind", "protocol_version", "sidecar_protocol_version",
               "operation_id", "coordinator_instance_id", "marker_generation",
               "recovery_marker_generation", "source_display_id", "target_device_id",
               "fresh_boundary", "coordinator", "linux_rust", "linux_deskflow", "windows"],
               "candidate manifest")
    req(manifest["schema_version"] == 1 and manifest["kind"] == "viewflow-v21-cross-host-candidate-set" and
        manifest["protocol_version"] == "2.1" and manifest["sidecar_protocol_version"] == 3,
        "candidate protocol contract differs")
    req(manifest["operation_id"] == OP and manifest["coordinator_instance_id"] == COORD and
        manifest["marker_generation"] == 1 and manifest["recovery_marker_generation"] == 2,
        "candidate operation identity differs")
    exact_members(manifest["fresh_boundary"], ["root", "deployment_marker", "deployment_marker_sha256",
               "deployment_publish_receipt_sha256", "marker_handoff_sha256", "linux_frozen_sha256"],
               "candidate fresh boundary")
    req(manifest["fresh_boundary"]["root"] == OP_ROOT,
        "candidate operation root binding differs")
    exact_members(manifest["windows"], ["viewflowd", "viewflowd_sha256", "wrapper", "wrapper_sha256",
               "launcher", "launcher_sha256", "installer", "installer_sha256", "rollback_sha256",
               "native_provenance", "native_provenance_sha256", "session_1_user_sid",
               "old_task_xml_sha256", "new_task_xml_override"], "candidate Windows contract")
    win = manifest["windows"]
    req(win["viewflowd"] == CANDIDATE + "/windows-viewflowd.exe" and
        win["native_provenance"] == CANDIDATE + "/windows-native-provenance.json",
        "candidate Windows canonical paths differ")
    req(win["viewflowd_sha256"] == files[5]["sha256"] and
        win["native_provenance_sha256"] == files[1]["sha256"],
        "candidate Windows digest binding differs")
    provenance = strict_json(blobs["windows-native-provenance.json"], "Windows provenance")
    exact_members(provenance, ["artifact", "build", "kind", "protocol_version", "schema_version",
               "sidecar_protocol_version", "source"], "Windows provenance")
    exact_members(provenance["artifact"], ["remote_path", "sha256", "size_bytes"],
               "Windows provenance artifact")
    exact_members(provenance["source"], ["archive_checksum_sidecar_sha256", "archive_path",
               "archive_sha256", "external_manifest_path", "external_manifest_sha256",
               "manifest_entries", "reviewed_readme_sha256"], "Windows provenance source")
    req(provenance["schema_version"] == 1 and
        provenance["kind"] == "viewflow-windows-native-release-provenance" and
        provenance["protocol_version"] == "2.1" and provenance["sidecar_protocol_version"] == 3,
        "Windows provenance protocol contract differs")
    req(provenance["artifact"]["sha256"] == files[5]["sha256"] and
        provenance["artifact"]["size_bytes"] == files[5]["size_bytes"],
        "Windows provenance artifact closure differs")
    source = provenance["source"]
    req(source["archive_checksum_sidecar_sha256"] == files[4]["sha256"] and
        source["archive_sha256"] == files[3]["sha256"] and
        source["external_manifest_sha256"] == files[2]["sha256"],
        "Windows source package closure differs")
    req(blobs["windows-source.tar.gz.sha256"] ==
        (files[3]["sha256"] + "  viewflow-windows-source.tar.gz\n").encode("ascii"),
        "Windows source checksum sidecar content differs")
    return manifest


def validate_seed():
    req(SEED_ROOT != CANDIDATE and SEED_ROOT.startswith(CANDIDATES + "/"),
        "authorized seed root is outside the candidate namespace or aliases the old candidate")
    seed_fd = open_dir(SEED_ROOT, 0o700, "authorized seed root")
    try:
        data, digest, _ = read_file_at(seed_fd, "candidate-manifest.json", 0o600,
                                       "authorized seed candidate manifest")
        req(digest == SEED_SHA, "authorized seed manifest SHA-256 differs")
        seed = strict_json(data, "authorized seed candidate manifest")
        req(seed.get("schema_version") == 1 and
            seed.get("kind") == "viewflow-v21-cross-host-candidate-set" and
            seed.get("protocol_version") == "2.1" and seed.get("sidecar_protocol_version") == 3,
            "authorized seed protocol contract differs")
    finally:
        os.close(seed_fd)


def validate_fresh_boundary(manifest, op_fd):
    publish_path = OP_ROOT + "/deployment-publish.json"
    handoff_path = OP_ROOT + "/marker-handoff.json"
    frozen_path = OP_ROOT + "/linux-frozen.json"
    p_data, p_sha, _ = read_file_at(op_fd, "deployment-publish.json", 0o600, "deployment publish")
    h_data, h_sha, _ = read_file_at(op_fd, "marker-handoff.json", 0o600, "marker handoff")
    f_data, f_sha, _ = read_file_at(op_fd, "linux-frozen.json", 0o600, "Linux frozen evidence")
    p = strict_json(p_data, "deployment publish")
    h = strict_json(h_data, "marker handoff")
    f = strict_json(f_data, "Linux frozen evidence")
    exact_members(p, ["coordinator_instance_id", "created_at_unix_ms", "created_at_utc",
               "marker_generation", "marker_path", "marker_sha256", "operation_id",
               "protocol_version", "schema_version", "source_display_id", "state",
               "target_device_id"], "deployment publish")
    req(p["schema_version"] == 1 and p["state"] == "deployment-quarantine-published" and
        p["protocol_version"] == "2.1" and p["operation_id"] == OP and
        p["coordinator_instance_id"] == COORD and p["marker_generation"] == "1",
        "deployment publish identity differs")
    exact_members(h, ["schema_version", "state", "protocol_version", "operation_id",
               "source_display_id", "target_device_id", "coordinator_instance_id",
               "marker_generation", "marker_cli_path", "marker_cli_sha256",
               "deployment_marker_path", "deployment_marker_sha256",
               "deployment_publish_receipt_path", "deployment_publish_receipt_sha256",
               "deskflow_unit", "deskflow_unit_active_state", "deskflow_unit_main_pid",
               "deskflow_executable_path", "deskflow_executable_sha256",
               "deskflow_exact_process_count", "deskflow_core_executable_path",
               "deskflow_core_executable_sha256", "deskflow_core_exact_process_count",
               "deskflow_tcp_port", "deskflow_tcp_listener_count", "runtime_marker_path",
               "runtime_marker_present", "observed_at_utc"], "marker handoff")
    req(h["schema_version"] == 1 and h["state"] == "viewflow-v13-marker-handoff-prepared" and
        h["protocol_version"] == "2.1" and h["operation_id"] == OP and
        h["coordinator_instance_id"] == COORD and h["marker_generation"] == "1" and
        h["deployment_publish_receipt_path"] == publish_path and
        h["deployment_publish_receipt_sha256"] == p_sha and
        h["deployment_marker_path"] == p["marker_path"] and
        h["deployment_marker_sha256"] == p["marker_sha256"] and
        h["runtime_marker_present"] is False and h["deskflow_unit_active_state"] == "inactive" and
        h["deskflow_unit_main_pid"] == 0 and h["deskflow_exact_process_count"] == 0 and
        h["deskflow_core_exact_process_count"] == 0 and h["deskflow_tcp_listener_count"] == 0,
        "marker handoff closure or quiescence differs")
    exact_members(f, ["schema_version", "state", "operation_id", "daemon", "journal",
               "pre_stop", "post_stop", "completed_at_unix_ms"], "Linux frozen evidence")
    req(f["schema_version"] == 1 and f["state"] == "viewflow-v13-bootstrap-frozen" and
        f["operation_id"] == OP, "Linux frozen identity differs")
    post = f.get("post_stop")
    req(type(post) is dict and post.get("unit_active_state") == "inactive" and
        post.get("main_pid") == 0 and post.get("exact_process_count") == 0 and
        post.get("original_daemon_pid_present") is False and
        post.get("sidecar_socket_present") is False and
        post.get("udp_44119_listener_count") == 0,
        "Linux frozen post-stop boundary differs")
    fb = manifest["fresh_boundary"]
    req(fb["deployment_publish_receipt_sha256"] == p_sha and
        fb["marker_handoff_sha256"] == h_sha and fb["linux_frozen_sha256"] == f_sha and
        fb["deployment_marker"] == p["marker_path"] and
        fb["deployment_marker_sha256"] == p["marker_sha256"],
        "candidate fresh-boundary hash closure differs")
    marker_data, marker_sha, marker_st = read_absolute_file(p["marker_path"], 0o600,
                                                            "deployment marker")
    req(marker_sha == p["marker_sha256"] and marker_st.st_size == 256 and
        marker_data[:8] == b"VFDQT001", "deployment marker identity differs")
    return {
        "deployment_publish_path": publish_path,
        "deployment_publish_sha256": p_sha,
        "marker_handoff_path": handoff_path,
        "marker_handoff_sha256": h_sha,
        "linux_frozen_path": frozen_path,
        "linux_frozen_sha256": f_sha,
        "deployment_marker_path": p["marker_path"],
        "deployment_marker_sha256": marker_sha,
    }


def validate_operation_leaves(op_fd, allow_intent, allow_terminal):
    allowed = set(BASE_OPERATION_LEAVES)
    if allow_intent:
        allowed.add(INTENT_LEAF)
    if allow_terminal:
        allowed.add(TERMINAL_LEAF)
    os.lseek(op_fd, 0, os.SEEK_SET)
    names = set(os.listdir(op_fd))
    req(names == allowed,
        "operation root must contain only P/H/F and the current retirement transaction receipts " +
        "(observed=" + repr(sorted(names)) + ", allowed=" + repr(sorted(allowed)) + ")")


def open_named_candidate(parent_fd, leaf, path, label):
    try:
        fd = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                     dir_fd=parent_fd)
    except OSError as error:
        die(label + " cannot be opened: " + str(error))
    try:
        st = validate_meta(fd, label, "dir", 0o700)
        named = os.stat(leaf, dir_fd=parent_fd, follow_symlinks=False)
        req(meta_tuple(named) == meta_tuple(st), label + " pathname/inode changed")
        canonical_absolute(path, label)
        return fd, st
    except BaseException:
        os.close(fd)
        raise


def make_terminal(created_ms, created_utc, files, tree_sha, fresh):
    return {
        "schema_version": 1,
        "state": "viewflow-normal-v21-candidate-retired",
        "operation_id": OP,
        "coordinator_instance_id": COORD,
        "replacement_ordinal": 1,
        "created_at_unix_ms": created_ms,
        "created_at_utc": created_utc,
        "operation_root": OP_ROOT,
        "candidate_root": CANDIDATE,
        "old_candidate": {
            "canonical_path": CANDIDATE,
            "archive_path": ARCHIVE,
            "manifest_sha256": MANIFEST_SHA,
            "tree_sha256": tree_sha,
            "files": files,
        },
        "fresh_boundary": fresh,
        "authorized_seed": {
            "root": SEED_ROOT,
            "candidate_manifest_path": SEED_ROOT + "/candidate-manifest.json",
            "candidate_manifest_sha256": SEED_SHA,
        },
        "pre_retirement": {
            "coordinator_state_path": OP_ROOT + "/coordinator-state.json",
            "coordinator_state_absent": True,
            "standard_normal_outputs_absent": True,
        },
    }


def make_intent(created_ms, created_utc, terminal):
    return {
        "schema_version": 1,
        "state": "viewflow-normal-v21-candidate-retirement-intent",
        "operation_id": OP,
        "coordinator_instance_id": COORD,
        "replacement_ordinal": 1,
        "created_at_unix_ms": created_ms,
        "created_at_utc": created_utc,
        "operation_root": OP_ROOT,
        "candidate_root": CANDIDATE,
        "archive_path": ARCHIVE,
        "terminal_path": TERMINAL_PATH,
        "terminal_receipt": terminal,
    }


def validate_terminal_shape(value):
    exact_keys(value, ["schema_version", "state", "operation_id", "coordinator_instance_id",
               "replacement_ordinal", "created_at_unix_ms", "created_at_utc", "operation_root",
               "candidate_root", "old_candidate", "fresh_boundary", "authorized_seed",
               "pre_retirement"], "terminal receipt")
    exact_keys(value["old_candidate"], ["canonical_path", "archive_path", "manifest_sha256",
               "tree_sha256", "files"], "terminal old candidate")
    exact_keys(value["fresh_boundary"], ["deployment_publish_path", "deployment_publish_sha256",
               "marker_handoff_path", "marker_handoff_sha256", "linux_frozen_path",
               "linux_frozen_sha256", "deployment_marker_path", "deployment_marker_sha256"],
               "terminal fresh boundary")
    exact_keys(value["authorized_seed"], ["root", "candidate_manifest_path",
               "candidate_manifest_sha256"], "terminal authorized seed")
    exact_keys(value["pre_retirement"], ["coordinator_state_path", "coordinator_state_absent",
               "standard_normal_outputs_absent"], "terminal pre-retirement")
    req(type(value["old_candidate"]["files"]) is list and len(value["old_candidate"]["files"]) == 6,
        "terminal file table length differs")
    for record in value["old_candidate"]["files"]:
        exact_keys(record, ["name", "mode", "size_bytes", "sha256"], "terminal file record")
    req([record["name"] for record in value["old_candidate"]["files"]] == EXPECTED_FILES,
        "terminal file table is not ASCII ordered")
    req(value["state"] == "viewflow-normal-v21-candidate-retired" and
        value["replacement_ordinal"] == 1 and
        value["pre_retirement"]["coordinator_state_absent"] is True and
        value["pre_retirement"]["standard_normal_outputs_absent"] is True,
        "terminal fixed values differ")
    req(type(value["created_at_unix_ms"]) is int and not isinstance(value["created_at_unix_ms"], bool) and
        type(value["created_at_utc"]) is str and UTC.fullmatch(value["created_at_utc"]),
        "terminal timestamp is not canonical")


def validate_intent_shape(value):
    exact_keys(value, ["schema_version", "state", "operation_id", "coordinator_instance_id",
               "replacement_ordinal", "created_at_unix_ms", "created_at_utc", "operation_root",
               "candidate_root", "archive_path", "terminal_path", "terminal_receipt"],
               "retirement intent")
    req(value["schema_version"] == 1 and
        value["state"] == "viewflow-normal-v21-candidate-retirement-intent" and
        value["operation_id"] == OP and value["coordinator_instance_id"] == COORD and
        value["replacement_ordinal"] == 1 and value["operation_root"] == OP_ROOT and
        value["candidate_root"] == CANDIDATE and value["archive_path"] == ARCHIVE and
        value["terminal_path"] == TERMINAL_PATH,
        "retirement intent fixed binding differs")
    validate_terminal_shape(value["terminal_receipt"])


def rename_candidate(candidates_fd, rejected_fd, candidate_fd, candidate_st):
    revalidate_dir_path(CANDIDATES, candidates_fd, "candidate namespace")
    revalidate_dir_path(REJECTED, rejected_fd, "rejected candidate namespace")
    named = os.stat(SOURCE_LEAF, dir_fd=candidates_fd, follow_symlinks=False)
    req(meta_tuple(named) == meta_tuple(candidate_st), "source candidate changed before rename")
    req(not exists_at(rejected_fd, ARCHIVE_LEAF), "archive destination already exists")
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = libc.renameat2
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                          ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    RENAME_NOREPLACE = 1
    if renameat2(candidates_fd, os.fsencode(SOURCE_LEAF), rejected_fd,
                 os.fsencode(ARCHIVE_LEAF), RENAME_NOREPLACE) != 0:
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            die("archive destination appeared before no-replace commit")
        raise OSError(error, os.strerror(error))
    os.fsync(candidates_fd)
    os.fsync(rejected_fd)
    req(not exists_at(candidates_fd, SOURCE_LEAF), "source remains after candidate rename")
    archive_fd, archive_st = open_named_candidate(rejected_fd, ARCHIVE_LEAF, ARCHIVE,
                                                  "archived candidate")
    try:
        req(meta_tuple(archive_st) == meta_tuple(candidate_st),
            "archived candidate inode identity differs")
        files, tree_sha, _ = file_tree(archive_fd, "archived candidate")
        req(tree_sha == EXPECTED_TREE_SHA and files == EXPECTED_FILES_TABLE,
            "archived candidate content differs after rename")
    finally:
        os.close(archive_fd)
    revalidate_dir_path(CANDIDATES, candidates_fd, "candidate namespace")
    revalidate_dir_path(REJECTED, rejected_fd, "rejected candidate namespace")


req(MODE in ("--check-only", "--execute", "--resume", "--replay"), "invalid mode")
req(os.geteuid() == UID, "must run as uid 1000")
req(HEX32.fullmatch(OP) is not None and UUID.fullmatch(COORD) is not None and
    HEX64.fullmatch(MANIFEST_SHA) is not None and HEX64.fullmatch(SEED_SHA) is not None,
    "operation/coordinator/SHA argument is not canonical")
req(OP_ROOT == STATE + "/deployments/" + OP, "operation root is not canonical")
req(CANDIDATE == CANDIDATES + "/" + SOURCE_LEAF, "candidate root is not canonical")

operation_fd = open_dir(OP_ROOT, 0o700, "operation root")
candidates_fd = open_dir(CANDIDATES, 0o700, "candidate namespace")
rejected_fd = None
candidate_fd = None
try:
    try:
        fcntl.flock(operation_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        die("operation root is locked by another retirement process")
    validate_seed()
    source_present = exists_at(candidates_fd, SOURCE_LEAF)
    rejected_present = exists_at(candidates_fd, "rejected")
    if rejected_present:
        rejected_fd = os.open("rejected", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                              dir_fd=candidates_fd)
        validate_meta(rejected_fd, "rejected candidate namespace", "dir", 0o700)
        revalidate_dir_path(REJECTED, rejected_fd, "rejected candidate namespace")
    elif MODE in ("--execute", "--resume"):
        os.mkdir("rejected", 0o700, dir_fd=candidates_fd)
        os.fsync(candidates_fd)
        rejected_fd = os.open("rejected", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                              dir_fd=candidates_fd)
        validate_meta(rejected_fd, "rejected candidate namespace", "dir", 0o700)
        revalidate_dir_path(REJECTED, rejected_fd, "rejected candidate namespace")
    target_present = rejected_fd is not None and exists_at(rejected_fd, ARCHIVE_LEAF)
    req(not (source_present and target_present), "source and archive names both exist")
    if MODE in ("--check-only", "--execute"):
        req(source_present and not target_present, "fresh retirement requires source present and archive absent")
    else:
        req(source_present or target_present, "neither source nor archived candidate exists")
    if MODE == "--replay":
        req(target_present and not source_present, "replay requires the committed archive state")
    if source_present:
        candidate_fd, candidate_st = open_named_candidate(candidates_fd, SOURCE_LEAF, CANDIDATE,
                                                          "source candidate")
    else:
        req(rejected_fd is not None, "rejected namespace is absent")
        candidate_fd, candidate_st = open_named_candidate(rejected_fd, ARCHIVE_LEAF, ARCHIVE,
                                                          "archived candidate")
    EXPECTED_FILES_TABLE, EXPECTED_TREE_SHA, blobs = file_tree(candidate_fd, "candidate tree")
    req(EXPECTED_FILES_TABLE[0]["sha256"] == MANIFEST_SHA,
        "candidate manifest argument differs from the candidate tree")
    manifest = validate_candidate(EXPECTED_FILES_TABLE, blobs)
    fresh = validate_fresh_boundary(manifest, operation_fd)
    intent_present = exists_at(operation_fd, INTENT_LEAF)
    terminal_present = exists_at(operation_fd, TERMINAL_LEAF)
    validate_operation_leaves(operation_fd, intent_present, terminal_present)
    if terminal_present:
        req(target_present and not source_present,
            "terminal receipt may exist only after the candidate rename committed")
    if MODE == "--check-only":
        req(not intent_present and not terminal_present and not target_present,
            "check-only requires an unstarted retirement transaction")
        print("normal v2.1 candidate retirement checks passed " +
              "(archive=" + ARCHIVE + ", tree_sha256=" + EXPECTED_TREE_SHA + ")")
        raise SystemExit(0)
    if MODE == "--execute":
        req(not intent_present and not terminal_present,
            "execute requires fresh intent and terminal paths")
        now_ms = time.time_ns() // 1_000_000
        now_utc = datetime.datetime.fromtimestamp(now_ms / 1000, datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%S.") + f"{now_ms % 1000:03d}Z"
        terminal = make_terminal(now_ms, now_utc, EXPECTED_FILES_TABLE, EXPECTED_TREE_SHA, fresh)
        intent = make_intent(now_ms, now_utc, terminal)
        publish_create_once(operation_fd, INTENT_LEAF, canonical_bytes(intent), "retirement intent")
        intent_present = True
    else:
        req(intent_present, MODE[2:] + " requires the durable retirement intent")
        intent_data, _, _ = read_file_at(operation_fd, INTENT_LEAF, 0o600, "retirement intent")
        intent = strict_json(intent_data, "retirement intent")
        validate_intent_shape(intent)
        terminal = make_terminal(intent["created_at_unix_ms"], intent["created_at_utc"],
                                 EXPECTED_FILES_TABLE, EXPECTED_TREE_SHA, fresh)
        req(intent == make_intent(intent["created_at_unix_ms"], intent["created_at_utc"], terminal) and
            intent_data == canonical_bytes(intent), "retirement intent does not exactly bind current inputs")
    validate_terminal_shape(terminal)
    req(terminal == make_terminal(terminal["created_at_unix_ms"], terminal["created_at_utc"],
                                  EXPECTED_FILES_TABLE, EXPECTED_TREE_SHA, fresh),
        "terminal preimage does not exactly bind current inputs")
    validate_operation_leaves(operation_fd, True, terminal_present)
    revalidate_dir_path(OP_ROOT, operation_fd, "operation root")
    if source_present:
        req(rejected_fd is not None, "rejected candidate namespace was not created")
        rename_candidate(candidates_fd, rejected_fd, candidate_fd, candidate_st)
        source_present = False
        target_present = True
    else:
        req(target_present, "resume archive is absent")
        files_after, tree_after, _ = file_tree(candidate_fd, "archived candidate")
        req(files_after == EXPECTED_FILES_TABLE and tree_after == EXPECTED_TREE_SHA,
            "resume archive content differs")
    validate_operation_leaves(operation_fd, True, terminal_present)
    revalidate_dir_path(OP_ROOT, operation_fd, "operation root")
    if terminal_present:
        terminal_data, terminal_sha, _ = read_file_at(operation_fd, TERMINAL_LEAF, 0o600,
                                                       "terminal receipt")
        observed = strict_json(terminal_data, "terminal receipt")
        validate_terminal_shape(observed)
        req(observed == terminal and terminal_data == canonical_bytes(terminal),
            "terminal receipt differs from the durable intent and current archive")
    else:
        req(MODE != "--replay", "replay requires the terminal receipt")
        publish_create_once(operation_fd, TERMINAL_LEAF, canonical_bytes(terminal), "terminal receipt")
        terminal_data, terminal_sha, _ = read_file_at(operation_fd, TERMINAL_LEAF, 0o600,
                                                       "terminal receipt")
    validate_operation_leaves(operation_fd, True, True)
    revalidate_dir_path(OP_ROOT, operation_fd, "operation root")
    revalidate_dir_path(CANDIDATES, candidates_fd, "candidate namespace")
    revalidate_dir_path(REJECTED, rejected_fd, "rejected candidate namespace")
    req(not exists_at(candidates_fd, SOURCE_LEAF) and exists_at(rejected_fd, ARCHIVE_LEAF),
        "terminal archive namespace state differs")
    archive_fd, archive_st = open_named_candidate(rejected_fd, ARCHIVE_LEAF, ARCHIVE,
                                                  "terminal archived candidate")
    try:
        req(meta_tuple(archive_st) == meta_tuple(candidate_st),
            "terminal archived inode identity differs")
        files_after, tree_after, _ = file_tree(archive_fd, "terminal archived candidate")
        req(files_after == EXPECTED_FILES_TABLE and tree_after == EXPECTED_TREE_SHA,
            "terminal archived content differs")
    finally:
        os.close(archive_fd)
    print("normal v2.1 candidate retirement " + MODE[2:] + " complete " +
          "(terminal=" + TERMINAL_PATH + ", sha256=" + terminal_sha + ")")
finally:
    if candidate_fd is not None:
        os.close(candidate_fd)
    if rejected_fd is not None:
        os.close(rejected_fd)
    os.close(candidates_fd)
    os.close(operation_fd)
PY
