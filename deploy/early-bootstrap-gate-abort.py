#!/usr/bin/env python3
"""Fail-closed abort for the pre-worker LINUX_RECOVERED bootstrap class.

The operation-specific runtime work is delegated to one hash-pinned helper that
is executed only from a sealed memfd.  The helper contract deliberately has no
Deskflow start action.  Its four snapshots prove that the old Windows peer is
stable and that Deskflow/input producers remain absent before and after the
authorization publication boundary.
"""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path

SHA = re.compile(r"[0-9a-f]{64}")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
OP = re.compile(r"[0-9a-f]{32}")
FILETIME = re.compile(r"[1-9][0-9]{16,18}")
INVOCATION = re.compile(r"[0-9a-f]{32}")
SEALS = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
RENAME_NOREPLACE = 1
ACTIVE_OUTPUT_PREFIX = (
    "windows_live", "linux_started", "windows_started", "authenticated_peer",
    "authorization", "pre_abort_reattest",
)
SNAPSHOT_OUTPUTS = (
    ("preflight", "windows_live", False),
    ("start-viewflow", "linux_started", True),
    ("windows-v13", "windows_started", True),
    ("authenticated-peer", "authenticated_peer", True),
)

# The hermetic fixture imports this module and supplies an in-process validator
# for its deliberately non-production marker transaction double.  The CLI path
# never assigns it, and no environment variable or manifest field enables it.
_TEST_ONLY_MARKER_CANDIDATE_VALIDATOR = None

REVIEWED_TEST_MATRIX = {
    "cargo_fmt": "cargo fmt --all -- --check",
    "cargo_test": "cargo test -p viewflow-deployment-marker --bin viewflow-deployment-marker",
    "cargo_clippy": "cargo clippy -p viewflow-deployment-marker --bin viewflow-deployment-marker -- -D warnings",
    "cargo_fmt_passed": True,
    "cargo_test_passed": True,
    "cargo_clippy_passed": True,
}
REVIEWED_RELEASE_BUILD_COMMAND = (
    "cargo build --release -p viewflow-deployment-marker --bin viewflow-deployment-marker"
)


class GateError(RuntimeError):
    pass


def pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise GateError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def strict_json(data: bytes, label: str):
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GateError(f"{label} is not strict UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise GateError(f"{label} must be one JSON object")
    return value


def exact_keys(value, expected, label):
    if set(value) != set(expected):
        raise GateError(f"{label} keys differ")


def hash_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def nonzero_sha(value, label):
    if not isinstance(value, str) or not SHA.fullmatch(value) or value == "0" * 64:
        raise GateError(f"{label} must be a nonzero lowercase SHA-256")
    return value


def read_exact(spec, label, *, json_document=False):
    if set(spec) != {"path", "sha256", "mode"}:
        raise GateError(f"{label} spec keys differ")
    path = spec["path"]
    expected = nonzero_sha(spec["sha256"], f"{label} SHA-256")
    mode = spec["mode"]
    if not isinstance(path, str) or not path.startswith("/") or mode not in (600, 644, 700, 755):
        raise GateError(f"{label} spec is invalid")
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == int(str(mode), 8)
                and not any(name == "system.posix_acl_access" for name in os.listxattr(fd))):
            raise GateError(f"{label} ownership/mode/link contract differs")
        data = b""
        while len(data) < before.st_size:
            chunk = os.read(fd, min(1 << 20, before.st_size - len(data)))
            if not chunk:
                raise GateError(f"{label} short read")
            data += chunk
        if os.read(fd, 1):
            raise GateError(f"{label} grew while read")
        after = os.stat(path, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
                                  value.st_gid, value.st_nlink, value.st_size,
                                  value.st_mtime_ns, value.st_ctime_ns)
        if (identity(before) != identity(os.fstat(fd)) or identity(before) != identity(after)
                or hash_bytes(data) != expected):
            raise GateError(f"{label} bytes changed")
    finally:
        os.close(fd)
    return (strict_json(data, label), data) if json_document else data


def utc_milliseconds(value: int, label: str) -> str:
    try:
        instant = datetime.fromtimestamp(value / 1000, UTC)
    except (OverflowError, OSError, ValueError) as error:
        raise GateError(f"{label} timestamp is out of range") from error
    return instant.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def decode_vfdqt_marker(marker: bytes, manifest, label: str) -> int:
    if len(marker) != 256 or marker[:8] != b"VFDQT001":
        raise GateError(f"{label} VFDQT size/magic differs")
    operation_length = marker[13]
    if not (16 <= operation_length <= 128):
        raise GateError(f"{label} VFDQT operation length differs")
    operation_end = 16 + operation_length
    try:
        operation_id = marker[16:operation_end].decode("ascii", "strict")
    except UnicodeDecodeError as error:
        raise GateError(f"{label} VFDQT operation is not ASCII") from error
    identity = manifest["identity"]
    try:
        expected_uuids = b"".join(uuid.UUID(identity[name]).bytes for name in
                                  ("source_display_id", "target_device_id",
                                   "coordinator_instance_id"))
    except (ValueError, AttributeError) as error:
        raise GateError(f"{label} VFDQT identity is invalid") from error
    if (marker[8:13] != bytes((1, 1, 2, 1, 1)) or marker[14:16] != b"\0\0"
            or operation_id != manifest["operation_id"]
            or any(marker[operation_end:144]) or marker[144:192] != expected_uuids
            or any(marker[208:256])):
        raise GateError(f"{label} VFDQT fixed fields/identity/reserved bytes differ")
    created_at_unix_ms = int.from_bytes(marker[192:200], "little")
    generation = int.from_bytes(marker[200:208], "little")
    if created_at_unix_ms == 0 or generation != 1:
        raise GateError(f"{label} VFDQT timestamp/generation differs")
    return created_at_unix_ms


def validate_reviewed_marker_candidate(candidate) -> bytes:
    global _TEST_ONLY_MARKER_CANDIDATE_VALIDATOR
    if _TEST_ONLY_MARKER_CANDIDATE_VALIDATOR is not None:
        return _TEST_ONLY_MARKER_CANDIDATE_VALIDATOR(candidate)
    exact_keys(candidate, {"path", "sha256", "mode", "reviewed_build_manifest"},
               "marker candidate")
    if candidate["mode"] != 755:
        raise GateError("marker candidate must be native owner mode 0755")
    candidate_spec = {key: candidate[key] for key in ("path", "sha256", "mode")}
    candidate_bytes = read_exact(candidate_spec, "reviewed marker candidate")
    if len(candidate_bytes) < 64 or candidate_bytes[:4] != b"\x7fELF":
        raise GateError("reviewed marker candidate must be a native ELF executable")
    provenance, _ = read_exact(candidate["reviewed_build_manifest"],
                               "reviewed marker build manifest", json_document=True)
    exact_keys(provenance, {"schema_version", "state", "candidate", "rust_sources",
                            "package_manifest", "cargo_lock", "release_build", "test_matrix"},
               "reviewed marker build manifest")
    if (provenance["schema_version"] != 1
            or provenance["state"] != "viewflow-deployment-marker-reviewed-build"
            or provenance["candidate"] != candidate_spec
            or provenance["test_matrix"] != REVIEWED_TEST_MATRIX):
        raise GateError("reviewed marker build provenance binding differs")
    exact_keys(provenance["rust_sources"], {"main", "library"},
               "reviewed marker Rust sources")
    release_build = provenance["release_build"]
    exact_keys(release_build, {"command", "cargo_version", "rustc_version", "toolchain",
                               "host_target"}, "reviewed marker release build")
    host_target = release_build["host_target"]
    if (release_build["command"] != REVIEWED_RELEASE_BUILD_COMMAND
            or not isinstance(host_target, str)
            or not re.fullmatch(r"[a-z0-9_]+-[a-z0-9_]+-[a-z0-9_.-]+", host_target)
            or not isinstance(release_build["toolchain"], str)
            or not re.fullmatch(r"[A-Za-z0-9._-]+-" + re.escape(host_target),
                                release_build["toolchain"])
            or not isinstance(release_build["cargo_version"], str)
            or not re.fullmatch(r"cargo [0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{7,40} [0-9]{4}-[0-9]{2}-[0-9]{2}\)",
                                release_build["cargo_version"])
            or not isinstance(release_build["rustc_version"], str)
            or not re.fullmatch(r"rustc [0-9]+\.[0-9]+\.[0-9]+ \([0-9a-f]{7,40} [0-9]{4}-[0-9]{2}-[0-9]{2}\)",
                                release_build["rustc_version"])
            or release_build["cargo_version"].split()[1]
               != release_build["rustc_version"].split()[1]):
        raise GateError("reviewed marker release-build provenance differs")
    source_paths = {}
    for name, spec in provenance["rust_sources"].items():
        read_exact(spec, f"reviewed marker Rust source {name}")
        source_paths[name] = Path(spec["path"])
    read_exact(provenance["package_manifest"], "reviewed marker Cargo manifest")
    read_exact(provenance["cargo_lock"], "reviewed marker Cargo.lock")
    main_path = source_paths["main"]
    library_path = source_paths["library"]
    crate_root = main_path.parent.parent
    repository_root = crate_root.parent.parent
    if (main_path != crate_root / "src/main.rs"
            or library_path != crate_root / "src/lib.rs"
            or Path(provenance["package_manifest"]["path"]) != crate_root / "Cargo.toml"
            or Path(provenance["cargo_lock"]["path"]) != repository_root / "Cargo.lock"
            or crate_root.name != "viewflow-deployment-marker"):
        raise GateError("reviewed marker source/Cargo path provenance differs")
    return candidate_bytes


def validate_vfdqa(raw: bytes, receipt, auth_sha: str, manifest, label: str):
    if len(raw) != 384 or raw[:8] != b"VFDQA001":
        raise GateError(f"{label} size/magic differs")
    if (raw[8:13] != bytes((1, 1, 1, 3, 1)) or any(raw[13:16])
            or any(raw[344:352])):
        raise GateError(f"{label} schema/state/protocol/owner/reserved bytes differ")
    if raw[352:384] != hashlib.sha256(raw[:352]).digest():
        raise GateError(f"{label} checksum differs")
    marker = raw[16:272]
    marker_sha = hashlib.sha256(marker).digest()
    if raw[272:304] != marker_sha or marker_sha.hex() != manifest["marker"]["sha256"]:
        raise GateError(f"{label} embedded marker hash differs")
    if raw[304:336].hex() != auth_sha:
        raise GateError(f"{label} authorization hash differs")
    marker_created = decode_vfdqt_marker(marker, manifest, label)
    abort_committed = int.from_bytes(raw[336:344], "little")
    if abort_committed == 0 or abort_committed < marker_created:
        raise GateError(f"{label} committed timestamp differs")
    if (receipt["aborted_marker_sha256"] != marker_sha.hex()
            or receipt["marker_created_at_unix_ms"] != str(marker_created)
            or receipt["abort_committed_at_unix_ms"] != str(abort_committed)
            or receipt["abort_committed_at_utc"] != utc_milliseconds(abort_committed, label)):
        raise GateError(f"{label} binary/JSON timestamp or marker binding differs")
    return {
        "marker_sha256": marker_sha.hex(),
        "marker_created_at_unix_ms": marker_created,
        "abort_committed_at_unix_ms": abort_committed,
        "authorization_sha256": auth_sha,
        "receipt_sha256": raw[352:384].hex(),
    }


def seal(data: bytes, name: str) -> int:
    fd = os.memfd_create(name, os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    view = memoryview(data)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise GateError("sealed FD write failed")
        view = view[count:]
    os.lseek(fd, 0, os.SEEK_SET)
    fcntl.fcntl(fd, fcntl.F_ADD_SEALS, SEALS)
    if fcntl.fcntl(fd, fcntl.F_GET_SEALS) != SEALS:
        raise GateError("sealed FD flags differ")
    return fd


def create_once(path: str, data: bytes):
    target = Path(path)
    if not target.is_absolute() or target.name in {"", ".", ".."}:
        raise GateError("output path/parent is unsafe")
    parent = open_directory_nofollow(target.parent)
    temporary = f".{target.name}.tmp.{os.getpid()}.{hash_bytes(data)[:12]}"
    try:
        parent_stat = os.fstat(parent)
        if parent_stat.st_uid != os.geteuid() or stat.S_IMODE(parent_stat.st_mode) & 0o077:
            raise GateError("output parent must be owner-only")
        if any(name in ("system.posix_acl_access", "system.posix_acl_default")
               for name in os.listxattr(parent)):
            raise GateError("output parent ACL is not allowed")
        try:
            existing_stat = os.stat(target.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            existing_stat = None
        if existing_stat is not None:
            fd = os.open(target.name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent)
            try:
                before = os.fstat(fd)
                existing = read_fd_exact(fd, before.st_size, f"existing output {target}")
                if os.read(fd, 1):
                    raise GateError(f"existing output grew while read: {target}")
                after = os.fstat(fd)
                current = os.stat(target.name, dir_fd=parent, follow_symlinks=False)
            finally:
                os.close(fd)
            identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
                                      value.st_gid, value.st_nlink, value.st_size,
                                      value.st_mtime_ns, value.st_ctime_ns)
            if (identity(before) != identity(after) or identity(after) != identity(current)
                    or not stat.S_ISREG(before.st_mode) or existing != data
                    or before.st_uid != os.geteuid() or before.st_nlink != 1
                    or stat.S_IMODE(before.st_mode) != 0o600):
                raise GateError(f"existing output differs: {target}")
            reattest_parent(target.parent, parent, parent_stat)
            return
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                     0o600, dir_fd=parent)
        try:
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                if written <= 0:
                    raise GateError(f"output short write: {target}")
                view = view[written:]
            os.fsync(fd)
            temporary_stat = os.fstat(fd)
        finally:
            os.close(fd)
        libc = ctypes.CDLL(None, use_errno=True)
        result = libc.renameat2(parent, os.fsencode(temporary), parent,
                                os.fsencode(target.name), RENAME_NOREPLACE)
        if result != 0:
            error = ctypes.get_errno()
            raise GateError(f"create-once rename failed for {target}: errno {error}")
        os.fsync(parent)
        readback_fd = os.open(target.name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=parent)
        try:
            readback_stat = os.fstat(readback_fd)
            readback = read_fd_exact(readback_fd, readback_stat.st_size, f"output readback {target}")
            if os.read(readback_fd, 1):
                raise GateError(f"output readback grew: {target}")
        finally:
            os.close(readback_fd)
        if ((readback_stat.st_dev, readback_stat.st_ino) !=
                (temporary_stat.st_dev, temporary_stat.st_ino) or readback != data):
            raise GateError(f"output readback differs: {target}")
        reattest_parent(target.parent, parent, parent_stat)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def open_directory_nofollow(path: Path) -> int:
    if not path.is_absolute():
        raise GateError("directory must be absolute")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            next_fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                              dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def reattest_parent(path: Path, fd: int, expected):
    current_fd = os.fstat(fd)
    current_path = os.stat(path, follow_symlinks=False)
    identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
                              value.st_gid, value.st_nlink)
    if identity(current_fd) != identity(expected) or identity(current_path) != identity(expected):
        raise GateError("output parent identity changed")


def read_fd_exact(fd: int, size: int, label: str) -> bytes:
    data = b""
    while len(data) < size:
        chunk = os.read(fd, min(1 << 20, size - len(data)))
        if not chunk:
            raise GateError(f"{label} short read")
        data += chunk
    return data


def read_owner_output(path: str, label: str) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if not (stat.S_ISREG(before.st_mode) and before.st_uid == os.geteuid()
                and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600
                and not any(name == "system.posix_acl_access" for name in os.listxattr(fd))):
            raise GateError(f"{label} ownership/mode/link contract differs")
        data = read_fd_exact(fd, before.st_size, label)
        if os.read(fd, 1):
            raise GateError(f"{label} grew while read")
        after = os.fstat(fd)
        current = os.stat(path, follow_symlinks=False)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_uid,
                                  value.st_gid, value.st_nlink, value.st_size,
                                  value.st_mtime_ns, value.st_ctime_ns)
        if identity(before) != identity(after) or identity(after) != identity(current):
            raise GateError(f"{label} identity changed while read")
        return data
    finally:
        os.close(fd)


def validate_persisted_snapshots(manifest, *, require_post):
    outputs = manifest["outputs"]
    snapshots = {}
    for action, name, active in [
        ("preflight", "windows_live", False),
        ("start-viewflow", "linux_started", True),
        ("windows-v13", "windows_started", True),
        ("authenticated-peer", "authenticated_peer", True),
        ("pre-abort-reattest", "pre_abort_reattest", True),
    ]:
        raw = read_owner_output(outputs[name], f"persisted {action}")
        value = strict_json(raw, f"persisted {action}")
        validate_snapshot(value, manifest, action, active=active)
        snapshots[action] = value
    windows = snapshots["preflight"]["windows"]
    if any(value["windows"] != windows for value in snapshots.values()):
        raise GateError("persisted Windows stable tuple differs")
    active_linux = snapshots["authenticated-peer"]["linux"]
    if any(snapshots[action]["linux"] != active_linux for action in
           ("start-viewflow", "windows-v13", "authenticated-peer", "pre-abort-reattest")):
        raise GateError("persisted Linux v1.3 tuple differs")
    if require_post:
        raw = read_owner_output(outputs["post_abort_reattest"], "persisted post-abort reattestation")
        post = strict_json(raw, "persisted post-abort reattestation")
        validate_snapshot(post, manifest, "post-abort-reattest", active=True)
        if post["windows"] != windows or post["linux"] != active_linux:
            raise GateError("persisted post-abort tuple differs")
    return snapshots


def authorization_document(manifest, snapshot_raws):
    hashes = {name: hash_bytes(snapshot_raws[name]) for name in
              ("windows_live", "linux_started", "windows_started", "authenticated_peer")}
    identity = manifest["identity"]
    outputs = manifest["outputs"]
    auth = {
        "schema_version": 3,
        "state": "viewflow-deployment-quarantine-early-bootstrap-no-worker-abort-authorized",
        "operation_id": manifest["operation_id"],
        "coordinator_instance_id": identity["coordinator_instance_id"],
        "marker_generation": "1", "marker_sha256": manifest["marker"]["sha256"],
        "authorization_receipt_path": outputs["authorization"],
        "coordinator_terminal_state_sha256": manifest["artifacts"]["coordinator_state"]["sha256"],
        "coordinator_failure_phase": None, "coordinator_mutation_possible": False,
        "marker_handoff_receipt_sha256": manifest["artifacts"]["marker_handoff"]["sha256"],
        "deployment_publish_receipt_sha256": manifest["artifacts"]["deployment_publish"]["sha256"],
        "linux_frozen_evidence_sha256": manifest["artifacts"]["linux_frozen"]["sha256"],
        "bootstrap_request_sha256": manifest["artifacts"]["bootstrap_request"]["sha256"],
        "windows_stop_evidence_sha256": manifest["artifacts"]["windows_stop_evidence"]["sha256"],
        "windows_live_proof_sha256": hashes["windows_live"],
        "old_linux_viewflowd_sha256": manifest["installed"]["viewflowd"]["sha256"],
        "old_linux_deskflow_sha256": manifest["installed"]["deskflow"]["sha256"],
        "old_linux_deskflow_core_sha256": manifest["installed"]["deskflow_core"]["sha256"],
        "old_windows_viewflowd_sha256": manifest["windows_baseline"]["viewflowd_sha256"],
        "old_windows_wrapper_sha256": manifest["windows_baseline"]["wrapper_sha256"],
        "old_windows_task_xml_sha256": manifest["windows_baseline"]["task_xml_sha256"],
        "old_windows_rollback_sha256": manifest["windows_baseline"]["rollback_sha256"],
        "linux_v13_started_receipt_sha256": hashes["linux_started"],
        "windows_v13_started_receipt_sha256": hashes["windows_started"],
        "authenticated_v13_peer_receipt_sha256": hashes["authenticated_peer"],
        "windows_bootstrap_worker_created": False, "windows_new_operation_root_present": False,
        "windows_new_task_present": False, "windows_installer_process_count": 0,
        "mutation_permit_published": False, "force_release_executed": False,
        "rollback_performed": False, "windows_rollback_receipt_sha256": None,
        "initial_force_release_executed": False, "linux_deskflow_started": False,
        "input_producer_count": 0, "protocol_2_1": False,
    }
    return auth, (json.dumps(auth, sort_keys=True, separators=(",", ":")) + "\n").encode()


def active_output_prefix(manifest):
    outputs = manifest["outputs"]
    present = {name for name, path in outputs.items() if os.path.lexists(path)}
    forbidden = present - set(ACTIVE_OUTPUT_PREFIX)
    if forbidden:
        raise GateError("active marker has post-abort/terminal output: " + ",".join(sorted(forbidden)))
    length = 0
    while length < len(ACTIVE_OUTPUT_PREFIX) and ACTIVE_OUTPUT_PREFIX[length] in present:
        length += 1
    if present != set(ACTIVE_OUTPUT_PREFIX[:length]):
        raise GateError("active marker output journal has a hole or extra phase")
    return length, ("none" if length == 0 else ACTIVE_OUTPUT_PREFIX[length - 1])


def validate_active_journal(manifest):
    length, phase = active_output_prefix(manifest)
    outputs = manifest["outputs"]
    snapshots = {}
    snapshot_raws = {}
    for action, name, active in SNAPSHOT_OUTPUTS:
        if ACTIVE_OUTPUT_PREFIX.index(name) >= length:
            break
        raw = read_owner_output(outputs[name], f"resume {action}")
        value = strict_json(raw, f"resume {action}")
        validate_snapshot(value, manifest, action, active=active)
        snapshots[action] = value
        snapshot_raws[name] = raw
    if snapshots:
        windows = snapshots["preflight"]["windows"]
        if any(value["windows"] != windows for value in snapshots.values()):
            raise GateError("resume Windows stable tuple differs")
    if "start-viewflow" in snapshots:
        linux = snapshots["start-viewflow"]["linux"]
        if any(value["linux"] != linux for action, value in snapshots.items()
               if action != "preflight"):
            raise GateError("resume Linux v1.3 stable tuple differs")
    if length >= ACTIVE_OUTPUT_PREFIX.index("authorization") + 1:
        expected_auth, expected_raw = authorization_document(manifest, snapshot_raws)
        auth_raw = read_owner_output(outputs["authorization"], "resume authorization")
        auth = strict_json(auth_raw, "resume authorization")
        if auth != expected_auth or auth_raw != expected_raw:
            raise GateError("resume authorization bytes/binding differ")
    if length >= ACTIVE_OUTPUT_PREFIX.index("pre_abort_reattest") + 1:
        raw = read_owner_output(outputs["pre_abort_reattest"], "resume pre-abort reattestation")
        value = strict_json(raw, "resume pre-abort reattestation")
        validate_snapshot(value, manifest, "pre-abort-reattest", active=True)
        if (value["windows"] != snapshots["preflight"]["windows"]
                or value["linux"] != snapshots["start-viewflow"]["linux"]):
            raise GateError("resume pre-abort stable tuple differs")
        snapshots["pre-abort-reattest"] = value
        snapshot_raws["pre_abort_reattest"] = raw
    return length, phase, snapshots, snapshot_raws


def current_resume_boundary(helper_fd, manifest_fd, manifest, snapshots, phase):
    if phase == "none":
        current, _ = run_helper(helper_fd, manifest_fd, "preflight")
        validate_snapshot(current, manifest, "preflight", active=False)
        return "inactive"
    if phase == "windows_live":
        try:
            current, _ = run_helper(helper_fd, manifest_fd, "preflight")
            validate_snapshot(current, manifest, "preflight", active=False)
            if current["windows"] != snapshots["preflight"]["windows"]:
                raise GateError("resume inactive Windows tuple differs")
            return "inactive"
        except subprocess.CalledProcessError:
            pass
    current, _ = run_helper(helper_fd, manifest_fd, "windows-v13")
    validate_snapshot(current, manifest, "windows-v13", active=True)
    if current["windows"] != snapshots["preflight"]["windows"]:
        raise GateError("resume live Windows tuple differs")
    if "start-viewflow" in snapshots and current["linux"] != snapshots["start-viewflow"]["linux"]:
        raise GateError("resume live Linux tuple differs")
    return "active"


def adopt_or_start_linux(helper_fd, manifest_fd, manifest, snapshots):
    try:
        current, _ = run_helper(helper_fd, manifest_fd, "preflight")
        validate_snapshot(current, manifest, "preflight", active=False)
        if current["windows"] != snapshots["preflight"]["windows"]:
            raise GateError("pre-start resumed Windows tuple differs")
        started, raw = run_helper(helper_fd, manifest_fd, "start-viewflow")
        validate_snapshot(started, manifest, "start-viewflow", active=True)
        if started["windows"] != snapshots["preflight"]["windows"]:
            raise GateError("post-start resumed Windows tuple differs")
    except subprocess.CalledProcessError:
        live, _ = run_helper(helper_fd, manifest_fd, "windows-v13")
        validate_snapshot(live, manifest, "windows-v13", active=True)
        if live["windows"] != snapshots["preflight"]["windows"]:
            raise GateError("adopted transient Windows tuple differs")
        started = dict(live)
        started["state"] = "viewflow-early-gate-start-viewflow"
        raw = (json.dumps(started, sort_keys=True, separators=(",", ":")) + "\n").encode()
        validate_snapshot(started, manifest, "start-viewflow", active=True)
    return started, raw


def validate_committed_abort_readonly(manifest, *, require_post=False):
    validate_persisted_snapshots(manifest, require_post=require_post)
    outputs = manifest["outputs"]
    auth_raw = read_owner_output(outputs["authorization"], "committed authorization")
    auth = strict_json(auth_raw, "committed authorization")
    snapshot_raws = {name: read_owner_output(outputs[name], f"committed {name}") for name in
                     ("windows_live", "linux_started", "windows_started", "authenticated_peer")}
    expected_auth, expected_auth_raw = authorization_document(manifest, snapshot_raws)
    if auth != expected_auth or auth_raw != expected_auth_raw:
        raise GateError("committed authorization bytes/binding differ")
    auth_sha = hash_bytes(auth_raw)
    candidate_fd = seal(validate_reviewed_marker_candidate(
                            manifest["execution"]["marker_candidate"]),
                        "viewflow-early-gate-query-marker-cli")
    identity = manifest["identity"]
    query = subprocess.run([f"/proc/self/fd/{candidate_fd}", "query", "--operation-id",
                            manifest["operation_id"], "--coordinator-instance-id",
                            identity["coordinator_instance_id"], "--marker-generation", "1",
                            "--marker-sha256", manifest["marker"]["sha256"],
                            "--abort-authorization-path", outputs["authorization"],
                            "--abort-authorization-sha256", auth_sha], env={"PATH": "/usr/bin:/bin"},
                           pass_fds=(candidate_fd,), check=True, stdout=subprocess.PIPE)
    query_receipt = strict_json(query.stdout, "committed abort query")
    durable = validate_abort_receipt(query_receipt, auth, auth_sha, manifest, replayed=True)
    durable_raw = read_owner_output(durable, "committed durable VFDQA")
    validate_vfdqa(durable_raw, query_receipt, auth_sha, manifest,
                   "committed durable VFDQA")
    if os.path.lexists(outputs["abort_receipt"]):
        local_raw = read_owner_output(outputs["abort_receipt"], "local abort receipt")
        local = strict_json(local_raw, "local abort receipt")
        if type(local.get("replayed")) is not bool:
            raise GateError("local abort receipt replay flag is invalid")
        validate_abort_receipt(local, auth, auth_sha, manifest, replayed=local["replayed"])
        if {key: value for key, value in local.items() if key != "replayed"} != {
                key: value for key, value in query_receipt.items() if key != "replayed"}:
            raise GateError("local abort receipt stable fields differ from query")
    return auth, auth_raw, auth_sha, query_receipt, query.stdout, durable_raw


def replay_if_terminal(manifest) -> bool:
    outputs = manifest.get("outputs")
    execution = manifest.get("execution")
    if not isinstance(outputs, dict) or not isinstance(execution, dict):
        return False
    terminal_path = outputs.get("terminal")
    if not isinstance(terminal_path, str) or not os.path.lexists(terminal_path):
        return False
    terminal_raw = read_owner_output(terminal_path, "terminal receipt")
    terminal = strict_json(terminal_raw, "terminal receipt")
    expected_keys = {"schema_version", "state", "operation_id", "coordinator_terminal_state_sha256",
                     "authorization_sha256", "abort_receipt_sha256", "pre_abort_reattest_sha256",
                     "post_abort_reattest_sha256", "vfdqa_binary_sha256",
                     "marker_absent", "abort_claim_absent", "release_claim_absent",
                     "runtime_marker_absent", "deskflow_unit_state", "deskflow_process_count",
                     "deskflow_core_process_count", "deskflow_tcp_listener_count",
                     "input_producer_count", "protocol_2_1"}
    exact_keys(terminal, expected_keys, "terminal receipt")
    _, _, _, _, _, verified_durable_raw = validate_committed_abort_readonly(
        manifest, require_post=True)
    auth_raw = read_owner_output(outputs["authorization"], "authorization")
    abort_raw = read_owner_output(outputs["abort_receipt"], "abort receipt")
    abort_receipt = strict_json(abort_raw, "abort receipt")
    durable_raw = read_owner_output(abort_receipt["abort_receipt_path"], "durable VFDQA")
    reattest_raw = read_owner_output(outputs["pre_abort_reattest"], "pre-abort reattestation")
    post_abort_raw = read_owner_output(outputs["post_abort_reattest"], "post-abort reattestation")
    expected_fixed = {
        "schema_version": 1, "state": "viewflow-early-bootstrap-gate-abort-terminal",
        "operation_id": manifest["operation_id"],
        "coordinator_terminal_state_sha256": manifest["artifacts"]["coordinator_state"]["sha256"],
        "authorization_sha256": hash_bytes(auth_raw), "abort_receipt_sha256": hash_bytes(abort_raw),
        "vfdqa_binary_sha256": hash_bytes(durable_raw),
        "pre_abort_reattest_sha256": hash_bytes(reattest_raw), "marker_absent": True,
        "post_abort_reattest_sha256": hash_bytes(post_abort_raw),
        "abort_claim_absent": True, "release_claim_absent": True, "runtime_marker_absent": True,
        "deskflow_unit_state": "inactive", "deskflow_process_count": 0,
        "deskflow_core_process_count": 0, "deskflow_tcp_listener_count": 0,
        "input_producer_count": 0, "protocol_2_1": False,
    }
    if terminal != expected_fixed:
        raise GateError("existing terminal receipt differs")
    if hash_bytes(verified_durable_raw) != terminal["vfdqa_binary_sha256"]:
        raise GateError("replay durable VFDQA bytes differ")
    for path in (execution["marker_path"], execution["abort_claim_path"],
                 execution["release_claim_path"], execution["runtime_marker_path"]):
        if os.path.lexists(path):
            raise GateError(f"replay boundary path exists: {path}")
    for group in ("artifacts", "installed"):
        for name, spec in manifest[group].items():
            read_exact(spec, f"replay {name}", json_document=(group == "artifacts"))
    print("early bootstrap no-worker gate abort terminal replay verified")
    return True


def publish_terminal(manifest, auth_sha, abort_raw, pre_raw, post_raw, durable_raw):
    terminal = {
        "schema_version": 1, "state": "viewflow-early-bootstrap-gate-abort-terminal",
        "operation_id": manifest["operation_id"], "coordinator_terminal_state_sha256":
            manifest["artifacts"]["coordinator_state"]["sha256"],
        "authorization_sha256": auth_sha, "abort_receipt_sha256": hash_bytes(abort_raw),
        "vfdqa_binary_sha256": hash_bytes(durable_raw),
        "pre_abort_reattest_sha256": hash_bytes(pre_raw),
        "post_abort_reattest_sha256": hash_bytes(post_raw), "marker_absent": True,
        "abort_claim_absent": True, "release_claim_absent": True, "runtime_marker_absent": True,
        "deskflow_unit_state": "inactive", "deskflow_process_count": 0,
        "deskflow_core_process_count": 0, "deskflow_tcp_listener_count": 0,
        "input_producer_count": 0, "protocol_2_1": False,
    }
    raw = (json.dumps(terminal, sort_keys=True, separators=(",", ":")) + "\n").encode()
    create_once(manifest["outputs"]["terminal"], raw)


def resume_committed_abort(manifest, manifest_bytes):
    outputs = manifest["outputs"]
    auth_raw = read_owner_output(outputs["authorization"], "committed authorization")
    auth = strict_json(auth_raw, "committed authorization")
    auth_sha = hash_bytes(auth_raw)
    candidate_fd = seal(validate_reviewed_marker_candidate(
                            manifest["execution"]["marker_candidate"]),
                        "viewflow-early-gate-resume-marker-cli")
    identity = manifest["identity"]
    common_args = ["--operation-id", manifest["operation_id"], "--coordinator-instance-id",
                   identity["coordinator_instance_id"], "--marker-generation", "1",
                   "--marker-sha256", manifest["marker"]["sha256"],
                   "--abort-authorization-path", outputs["authorization"],
                   "--abort-authorization-sha256", auth_sha]
    resumed = subprocess.run([f"/proc/self/fd/{candidate_fd}", "abort", *common_args],
                             env={"PATH": "/usr/bin:/bin"}, pass_fds=(candidate_fd,),
                             check=True, stdout=subprocess.PIPE)
    resumed_receipt = strict_json(resumed.stdout, "resumed abort transaction")
    if type(resumed_receipt.get("replayed")) is not bool:
        raise GateError("resumed abort replay flag is invalid")
    validate_abort_receipt(resumed_receipt, auth, auth_sha, manifest,
                           replayed=resumed_receipt["replayed"])
    if os.path.lexists(outputs["abort_receipt"]):
        local_abort_raw = read_owner_output(outputs["abort_receipt"], "existing local abort receipt")
        local_receipt = strict_json(local_abort_raw, "existing local abort receipt")
        if type(local_receipt.get("replayed")) is not bool:
            raise GateError("existing local abort replay flag is invalid")
        validate_abort_receipt(local_receipt, auth, auth_sha, manifest,
                               replayed=local_receipt["replayed"])
        if {key: value for key, value in local_receipt.items() if key != "replayed"} != {
                key: value for key, value in resumed_receipt.items() if key != "replayed"}:
            raise GateError("existing local abort receipt stable fields differ")
    else:
        local_abort_raw = resumed.stdout
        create_once(outputs["abort_receipt"], local_abort_raw)
    query = subprocess.run([f"/proc/self/fd/{candidate_fd}", "query", *common_args],
                           env={"PATH": "/usr/bin:/bin"}, pass_fds=(candidate_fd,),
                           check=True, stdout=subprocess.PIPE)
    query_receipt = strict_json(query.stdout, "resumed abort query")
    durable = validate_abort_receipt(query_receipt, auth, auth_sha, manifest, replayed=True)
    durable_raw = read_owner_output(durable, "resumed durable VFDQA")
    validate_vfdqa(durable_raw, query_receipt, auth_sha, manifest,
                   "resumed durable VFDQA")
    pre_raw = read_owner_output(outputs["pre_abort_reattest"], "pre-abort reattestation")
    pre = strict_json(pre_raw, "pre-abort reattestation")
    validate_snapshot(pre, manifest, "pre-abort-reattest", active=True)
    helper_fd = seal(read_exact(manifest["runtime_helper"], "resume runtime helper"),
                     "viewflow-early-gate-resume-helper")
    manifest_fd = seal(manifest_bytes, "viewflow-early-gate-resume-manifest")
    post, post_raw = run_helper(helper_fd, manifest_fd, "post-abort-reattest")
    validate_snapshot(post, manifest, "post-abort-reattest", active=True)
    if post["windows"] != pre["windows"] or post["linux"] != pre["linux"]:
        raise GateError("resumed post-abort stable tuple differs")
    create_once(outputs["post_abort_reattest"], post_raw)
    for path in (manifest["execution"]["marker_path"], manifest["execution"]["abort_claim_path"],
                 manifest["execution"]["release_claim_path"], manifest["execution"]["runtime_marker_path"]):
        if os.path.lexists(path):
            raise GateError(f"resumed post-abort path exists: {path}")
    publish_terminal(manifest, auth_sha, local_abort_raw, pre_raw, post_raw, durable_raw)
    print("committed VFDQA recovered and early abort terminalized")


def validate_windows(value, manifest, label):
    keys = {
        "task_path", "task_name", "task_state", "task_xml_sha256", "task_action_sha256",
        "task_principal_sha256", "request_sha256", "viewflowd_sha256",
        "viewflowd_process_count", "wrapper_sha256",
        "rollback_sha256", "pid", "process_start_filetime_utc", "session_id", "user_sid",
        "parent_pid", "executable_path", "command_line_sha256",
        "new_operation_root_present", "new_task_present", "bootstrap_worker_created",
        "new_operation_root_path", "new_task_path", "new_task_name",
        "installer_process_count", "mutation_permit_published", "initial_force_release_executed",
        "force_release_executed", "rollback_performed", "windows_rollback_receipt_sha256",
        "protocol_2_1"
    }
    exact_keys(value, keys, f"{label} Windows snapshot")
    baseline = manifest["windows_baseline"]
    expected = {
        "task_path": "\\", "task_name": "Viewflow Peer", "task_state": "Running",
        "task_xml_sha256": baseline["task_xml_sha256"],
        "task_action_sha256": baseline["task_action_sha256"],
        "task_principal_sha256": baseline["task_principal_sha256"],
        "request_sha256": manifest["artifacts"]["bootstrap_request"]["sha256"],
        "viewflowd_sha256": baseline["viewflowd_sha256"],
        "viewflowd_process_count": 1,
        "wrapper_sha256": baseline["wrapper_sha256"],
        "rollback_sha256": baseline["rollback_sha256"], "session_id": 1,
        "executable_path": baseline["executable_path"],
        "command_line_sha256": baseline["command_line_sha256"],
        "user_sid": baseline["user_sid"], "new_operation_root_present": False,
        "new_operation_root_path": baseline["new_operation_root_path"],
        "new_task_path": "\\", "new_task_name": "Viewflow Deployment " + manifest["operation_id"],
        "new_task_present": False, "bootstrap_worker_created": False,
        "installer_process_count": 0, "mutation_permit_published": False,
        "initial_force_release_executed": False, "force_release_executed": False,
        "rollback_performed": False, "windows_rollback_receipt_sha256": None,
        "protocol_2_1": False,
    }
    if any(value.get(key) != expected_value for key, expected_value in expected.items()):
        raise GateError(f"{label} Windows stable baseline differs")
    if type(value["viewflowd_process_count"]) is not int or value["viewflowd_process_count"] != 1:
        raise GateError(f"{label} Windows global Viewflow census differs")
    if type(value["pid"]) is not int or not 1 <= value["pid"] <= 0xFFFFFFFF:
        raise GateError(f"{label} Windows PID is invalid")
    if type(value["parent_pid"]) is not int or not 1 <= value["parent_pid"] <= 0xFFFFFFFF:
        raise GateError(f"{label} Windows parent PID is invalid")
    if not isinstance(value["process_start_filetime_utc"], str) or not FILETIME.fullmatch(value["process_start_filetime_utc"]):
        raise GateError(f"{label} Windows FILETIME is invalid")


def validate_linux(value, manifest, label, active):
    keys = {"viewflow_unit", "viewflow_unit_state", "viewflow_main_pid", "viewflow_start_ticks",
            "viewflow_invocation_id", "viewflow_control_group", "viewflow_exec_start_sha256",
            "viewflowd_sha256", "viewflow_process_count", "viewflow_udp_listener_count",
            "viewflow_sidecar_listener_count", "deskflow_unit_state", "deskflow_unit_main_pid",
            "deskflow_process_count", "deskflow_core_process_count", "deskflow_tcp_listener_count",
            "runtime_marker_present", "input_producer_count"}
    exact_keys(value, keys, label)
    unit = manifest["execution"]["viewflow_unit"]
    installed = manifest["installed"]
    common = {
        "viewflow_unit": unit, "viewflowd_sha256": installed["viewflowd"]["sha256"],
        "deskflow_unit_state": "inactive", "deskflow_unit_main_pid": 0,
        "deskflow_process_count": 0, "deskflow_core_process_count": 0,
        "deskflow_tcp_listener_count": 0, "runtime_marker_present": False,
        "input_producer_count": 0,
    }
    if any(value.get(key) != expected for key, expected in common.items()):
        raise GateError(f"{label} Deskflow/installed boundary differs")
    if active:
        if not (value["viewflow_unit_state"] == "active" and type(value["viewflow_main_pid"]) is int
                and value["viewflow_main_pid"] > 0 and type(value["viewflow_start_ticks"]) is int
                and value["viewflow_start_ticks"] > 0 and value["viewflow_process_count"] == 1
                and value["viewflow_udp_listener_count"] == 1
                and value["viewflow_sidecar_listener_count"] == 1
                and isinstance(value["viewflow_invocation_id"], str)
                and INVOCATION.fullmatch(value["viewflow_invocation_id"])
                and value["viewflow_control_group"].endswith("/" + unit)
                and nonzero_sha(value["viewflow_exec_start_sha256"], label)):
            raise GateError(f"{label} Viewflow live tuple is invalid")
    else:
        expected_zero = {"viewflow_unit_state": "inactive", "viewflow_main_pid": 0,
                         "viewflow_start_ticks": 0, "viewflow_invocation_id": "",
                         "viewflow_control_group": "", "viewflow_exec_start_sha256": None,
                         "viewflow_process_count": 0, "viewflow_udp_listener_count": 0,
                         "viewflow_sidecar_listener_count": 0}
        if any(value.get(key) != expected for key, expected in expected_zero.items()):
            raise GateError(f"{label} initial Viewflow boundary is not inactive")


def validate_snapshot(snapshot, manifest, action, *, active):
    exact_keys(snapshot, {"schema_version", "state", "operation_id", "marker_sha256",
                          "marker_generation", "linux", "windows"}, action)
    if (snapshot["schema_version"] != 1 or snapshot["state"] != f"viewflow-early-gate-{action}"
            or snapshot["operation_id"] != manifest["operation_id"]
            or snapshot["marker_sha256"] != manifest["marker"]["sha256"]
            or snapshot["marker_generation"] != "1"):
        raise GateError(f"{action} identity differs")
    validate_linux(snapshot["linux"], manifest, action, active)
    validate_windows(snapshot["windows"], manifest, action)


def validate_abort_receipt(receipt, auth, auth_sha, manifest, *, replayed):
    common = {"schema_version", "state", "protocol_version", "protocol_2_1", "operation_id",
              "source_display_id", "target_device_id", "coordinator_instance_id", "marker_generation",
              "marker_path", "abort_claim_path", "abort_receipt_path", "abort_authorization_path",
              "abort_authorization_sha256", "aborted_marker_sha256", "marker_created_at_unix_ms",
              "abort_committed_at_unix_ms", "abort_committed_at_utc", "abort_point",
              "deployment_release_claimed", "replayed"}
    v3 = {"authorization_state", "coordinator_terminal_state_sha256", "coordinator_failure_phase",
          "coordinator_mutation_possible", "marker_handoff_receipt_sha256",
          "deployment_publish_receipt_sha256", "linux_frozen_evidence_sha256",
          "bootstrap_request_sha256", "windows_stop_evidence_sha256", "windows_live_proof_sha256",
          "linux_v13_started_receipt_sha256", "windows_v13_started_receipt_sha256",
          "authenticated_v13_peer_receipt_sha256", "windows_bootstrap_worker_created",
          "windows_new_operation_root_present", "windows_new_task_present",
          "windows_installer_process_count", "mutation_permit_published", "force_release_executed",
          "rollback_performed", "windows_rollback_receipt_sha256", "initial_force_release_executed",
          "linux_deskflow_started", "input_producer_count"}
    exact_keys(receipt, common | v3, "marker CLI V3 abort receipt")
    identity = manifest["identity"]
    expected = {
        "schema_version": 3, "state": "deployment-quarantine-aborted", "protocol_version": "1.3",
        "protocol_2_1": False, "operation_id": manifest["operation_id"],
        "source_display_id": identity["source_display_id"], "target_device_id": identity["target_device_id"],
        "coordinator_instance_id": identity["coordinator_instance_id"], "marker_generation": "1",
        "marker_path": manifest["execution"]["marker_path"],
        "abort_claim_path": manifest["execution"]["abort_claim_path"],
        "abort_authorization_path": manifest["outputs"]["authorization"],
        "abort_authorization_sha256": auth_sha, "aborted_marker_sha256": manifest["marker"]["sha256"],
        "abort_point": "abort-claim-unlink-and-parent-directory-fsync",
        "deployment_release_claimed": False, "replayed": replayed,
        "authorization_state": auth["state"],
    }
    for key in v3 - {"authorization_state"}:
        expected[key] = auth[key]
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise GateError("marker CLI V3 abort receipt binding differs")
    for key in ("marker_created_at_unix_ms", "abort_committed_at_unix_ms"):
        if not isinstance(receipt[key], str) or not re.fullmatch(r"[1-9][0-9]*", receipt[key]):
            raise GateError(f"marker CLI receipt {key} is invalid")
    if not isinstance(receipt["abort_committed_at_utc"], str) or not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z",
            receipt["abort_committed_at_utc"]):
        raise GateError("marker CLI abort UTC is invalid")
    durable = receipt["abort_receipt_path"]
    marker_parent = Path(manifest["execution"]["marker_path"]).parent
    expected_durable = marker_parent / (
        ".deployment-quarantine.v1.abort-receipt."
        + manifest["marker"]["sha256"] + "." + auth_sha + ".v1")
    if not isinstance(durable, str) or Path(durable) != expected_durable:
        raise GateError("durable VFDQA path differs")
    return durable


def run_helper(fd, manifest_fd, action):
    result = subprocess.run([sys.executable, "-I", f"/proc/self/fd/{fd}", action,
                             f"/proc/self/fd/{manifest_fd}"], env={"PATH": "/usr/bin:/bin"},
                            pass_fds=(fd, manifest_fd), check=True, stdout=subprocess.PIPE)
    return strict_json(result.stdout, action), result.stdout


def validate_manifest(manifest, manifest_path, *, marker_required=True):
    exact_keys(manifest, {"schema_version", "state", "operation_id", "identity", "artifacts",
                          "installed", "marker", "windows_baseline", "runtime_helper",
                          "execution", "outputs", "required_absent"}, "manifest")
    if manifest["schema_version"] != 1 or manifest["state"] != "viewflow-early-bootstrap-gate-abort-manifest":
        raise GateError("manifest class differs")
    op = manifest["operation_id"]
    if not isinstance(op, str) or not OP.fullmatch(op):
        raise GateError("operation ID must be 32 lowercase hex characters")
    identity = manifest["identity"]
    exact_keys(identity, {"coordinator_instance_id", "source_display_id", "target_device_id",
                          "marker_generation"}, "identity")
    if not all(isinstance(identity[name], str) and UUID.fullmatch(identity[name]) for name in
               ("coordinator_instance_id", "source_display_id", "target_device_id")) or identity["marker_generation"] != "1":
        raise GateError("identity is invalid")
    exact_keys(manifest["artifacts"], {"coordinator_state", "marker_handoff", "linux_frozen",
                                      "deployment_publish", "bootstrap_request", "windows_stop_evidence"}, "artifacts")
    docs = {}
    for name, spec in manifest["artifacts"].items():
        docs[name], _ = read_exact(spec, name, json_document=True)
    state = docs["coordinator_state"]
    exact_keys(state, {"schema_version", "state", "operation_id", "phase", "recovery",
                       "committed_artifacts", "contract"}, "coordinator state")
    expected_committed = {
        "marker_handoff": manifest["artifacts"]["marker_handoff"]["sha256"],
        "linux_frozen": manifest["artifacts"]["linux_frozen"]["sha256"],
        "publish_receipt": manifest["artifacts"]["deployment_publish"]["sha256"],
        "bootstrap_request": manifest["artifacts"]["bootstrap_request"]["sha256"],
        "windows_stop_evidence": manifest["artifacts"]["windows_stop_evidence"]["sha256"],
    }
    if not (state["schema_version"] == 2 and state["state"] == "viewflow-cross-host-bootstrap"
            and state["operation_id"] == op and state["phase"] == "LINUX_RECOVERED"
            and state["recovery"] == {"failure_phase": None, "mutation_possible": False}
            and state["committed_artifacts"] == expected_committed):
        raise GateError("coordinator is not the exact early no-worker terminal class")
    contract = state["contract"]
    exact_keys(contract, {"identity", "inputs", "outputs", "remote"}, "coordinator contract")
    exact_keys(contract["identity"], {"source_display_id", "target_device_id", "coordinator_instance_id",
                                      "marker_generation", "recovery_marker_generation", "windows_user_sid",
                                      "windows_task_xml_sha256_override"}, "coordinator identity")
    for name in manifest["identity"]:
        if contract["identity"].get(name) != manifest["identity"][name]:
            raise GateError("coordinator identity differs")
    if (contract["identity"]["recovery_marker_generation"] != "2"
            or contract["identity"]["windows_user_sid"] != manifest["windows_baseline"]["user_sid"]
            or contract["identity"]["windows_task_xml_sha256_override"] != manifest["windows_baseline"]["task_xml_sha256"]):
        raise GateError("coordinator recovery generation/Windows baseline identity differs")
    if contract["remote"]["operation_root"] != manifest["windows_baseline"]["new_operation_root_path"]:
        raise GateError("Windows absent operation-root target differs")
    input_keys = {"marker_handoff", "linux_frozen", "publish_receipt", "linux_viewflow",
                  "linux_marker_cli", "linux_deskflow", "linux_deskflow_core", "linux_provenance",
                  "linux_viewflow_unit", "linux_deskflow_dropin", "windows_launcher", "windows_installer",
                  "windows_viewflow", "windows_wrapper", "windows_rollback"}
    output_keys = {"request", "prepared", "permit", "force_envelope", "linux_stage", "windows_install",
                   "windows_exit", "linux_finalize", "release", "cross_chain", "post_release",
                   "windows_restart", "cpp_status", "cpp_arm", "cpp_cleanup", "rust_arm", "rust_query",
                   "recovery_publish", "linux_deactivation_proof", "linux_deactivation_transcript",
                   "linux_containment", "windows_validation", "windows_rollback", "recovery_bundle",
                   "windows_stop_evidence", "recovery_publish_intent", "windows_restart_intent"}
    remote_keys = {"operation_root", "request", "prepared", "permit", "force_envelope", "linux_stage",
                   "windows_install", "exit", "readiness_receipt", "readiness_lock", "commit_request",
                   "rollback_manifest", "rollback_token", "recovery_bundle", "recovery_force_release",
                   "rollback_receipt", "rollback_claim", "restart_intent", "restart_claim", "restart_terminal"}
    exact_keys(contract["inputs"], input_keys, "coordinator inputs")
    exact_keys(contract["outputs"], output_keys, "coordinator outputs")
    exact_keys(contract["remote"], remote_keys, "coordinator remote")
    for key, artifact in (("marker_handoff", "marker_handoff"), ("linux_frozen", "linux_frozen"),
                          ("publish_receipt", "deployment_publish")):
        if contract["inputs"][key] != {"path": manifest["artifacts"][artifact]["path"],
                                       "sha256": manifest["artifacts"][artifact]["sha256"]}:
            raise GateError(f"coordinator input differs: {key}")
    if (contract["outputs"]["request"] != manifest["artifacts"]["bootstrap_request"]["path"]
            or contract["outputs"]["windows_stop_evidence"] != manifest["artifacts"]["windows_stop_evidence"]["path"]):
        raise GateError("coordinator request/stop output differs")
    for name, path in contract["outputs"].items():
        if name not in {"request", "windows_stop_evidence"} and os.path.lexists(path):
            raise GateError(f"uncommitted local coordinator output exists: {name}")
    handoff = docs["marker_handoff"]
    if not (handoff.get("schema_version") == 1 and handoff.get("state") == "viewflow-v13-marker-handoff-prepared"
            and handoff.get("operation_id") == op
            and handoff.get("deskflow_executable_sha256") == manifest["installed"]["deskflow"]["sha256"]
            and handoff.get("deskflow_core_executable_sha256") == manifest["installed"]["deskflow_core"]["sha256"]
            and handoff.get("deskflow_unit_active_state") == "inactive"
            and handoff.get("deskflow_exact_process_count") == 0
            and handoff.get("deskflow_core_exact_process_count") == 0
            and handoff.get("deskflow_tcp_listener_count") == 0
            and handoff.get("runtime_marker_present") is False):
        raise GateError("marker handoff H old Deskflow boundary differs")
    frozen = docs["linux_frozen"]
    if not (frozen.get("schema_version") == 1 and frozen.get("state") == "viewflow-v13-bootstrap-frozen"
            and frozen.get("operation_id") == op and frozen.get("daemon", {}).get("sha256") == manifest["installed"]["viewflowd"]["sha256"]
            and frozen.get("pre_stop", {}).get("deskflow_unit_active_state") == "inactive"
            and frozen.get("pre_stop", {}).get("deskflow_exact_process_count") == 0
            and frozen.get("pre_stop", {}).get("deskflow_core_exact_process_count") == 0
            and frozen.get("pre_stop", {}).get("deskflow_tcp_24800_listener_count") == 0
            and frozen.get("post_stop", {}).get("unit_active_state") == "inactive"
            and frozen.get("post_stop", {}).get("main_pid") == 0
            and frozen.get("post_stop", {}).get("exact_process_count") == 0):
        raise GateError("Linux frozen B old daemon/zero-input boundary differs")
    stop = docs["windows_stop_evidence"]
    if stop != {"schema_version": 1, "state": "viewflow-windows-bootstrap-no-worker-stopped",
                "operation_id": op, "request_sha256": manifest["artifacts"]["bootstrap_request"]["sha256"],
                "status_sha256": "0" * 64}:
        raise GateError("no-worker stop sentinel differs")
    exact_keys(manifest["installed"], {"viewflowd", "deskflow", "deskflow_core", "viewflow_unit"}, "installed")
    for name, spec in manifest["installed"].items():
        read_exact(spec, f"installed {name}")
    marker_spec = manifest["marker"]
    if marker_required:
        marker = read_exact(marker_spec, "VFDQT marker")
        if len(marker) != 256 or marker[:8] != b"VFDQT001" or int.from_bytes(marker[200:208], "little") != 1:
            raise GateError("VFDQT marker bytes/generation differ")
        operation_length = marker[13]
        if marker[16:16 + operation_length].decode("ascii", "strict") != op:
            raise GateError("VFDQT marker operation differs")
    publish = docs["deployment_publish"]
    exact_keys(publish, {"schema_version", "state", "protocol_version", "operation_id",
                         "source_display_id", "target_device_id", "coordinator_instance_id",
                         "marker_generation", "marker_path", "marker_sha256",
                         "created_at_unix_ms", "created_at_utc"}, "deployment publish")
    if not (publish["schema_version"] == 1 and publish["state"] == "deployment-quarantine-published"
            and publish["protocol_version"] == "2.1" and publish["operation_id"] == op
            and publish["source_display_id"] == identity["source_display_id"]
            and publish["target_device_id"] == identity["target_device_id"]
            and publish["coordinator_instance_id"] == identity["coordinator_instance_id"]
            and publish["marker_generation"] == "1" and publish["marker_path"] == marker_spec["path"]
            and publish["marker_sha256"] == marker_spec["sha256"]):
        raise GateError("deployment publish receipt differs")
    baseline = manifest["windows_baseline"]
    exact_keys(baseline, {"viewflowd_sha256", "wrapper_sha256", "task_xml_sha256",
                          "task_action_sha256", "task_principal_sha256", "rollback_sha256", "user_sid",
                          "executable_path", "command_line_sha256", "new_operation_root_path"}, "Windows baseline")
    for name in baseline:
        if name not in {"user_sid", "executable_path", "new_operation_root_path"}:
            nonzero_sha(baseline[name], f"Windows baseline {name}")
    helper = manifest["runtime_helper"]
    exact_keys(helper, {"path", "sha256", "mode"}, "runtime helper")
    execution = manifest["execution"]
    exact_keys(execution, {"marker_candidate", "viewflow_unit", "marker_path", "runtime_marker_path",
                           "abort_claim_path", "release_claim_path"}, "execution")
    validate_reviewed_marker_candidate(execution["marker_candidate"])
    exact_keys(manifest["outputs"], {"windows_live", "linux_started", "windows_started",
                                    "authenticated_peer", "authorization", "abort_receipt",
                                    "pre_abort_reattest", "post_abort_reattest", "terminal"}, "outputs")
    if len(set(manifest["outputs"].values())) != 9 or any(not isinstance(path, str) or not path.startswith("/") for path in manifest["outputs"].values()):
        raise GateError("output paths must be unique and absolute")
    if not isinstance(manifest["required_absent"], list) or len(set(manifest["required_absent"])) != len(manifest["required_absent"]):
        raise GateError("required_absent is invalid")
    return docs


def reattest_inputs(manifest):
    for group in ("artifacts", "installed"):
        for name, spec in manifest[group].items():
            read_exact(spec, f"reattest {name}", json_document=(group == "artifacts"))
    read_exact(manifest["marker"], "reattest VFDQT marker")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--manifest-sha256", required=True)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--check-only", action="store_true")
    modes.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    spec = {"path": str(Path(args.manifest).resolve()), "sha256": args.manifest_sha256, "mode": 600}
    manifest, manifest_bytes = read_exact(spec, "manifest", json_document=True)
    outputs = manifest.get("outputs", {})
    execution = manifest.get("execution", {})
    terminal_exists = (isinstance(outputs, dict)
                       and os.path.lexists(outputs.get("terminal", "")))
    committed_abort = (isinstance(outputs, dict) and isinstance(execution, dict)
                       and os.path.lexists(outputs.get("authorization", ""))
                       and not os.path.lexists(execution.get("marker_path", "")))
    validate_manifest(manifest, args.manifest,
                      marker_required=not (terminal_exists or committed_abort))
    for path in manifest["required_absent"]:
        if os.path.lexists(path):
            if committed_abort and path == manifest["execution"]["abort_claim_path"]:
                continue
            raise GateError(f"required-absent path exists: {path}")
    if os.path.lexists(manifest["execution"]["runtime_marker_path"]):
        raise GateError("VFQST runtime marker is present")
    if not (terminal_exists or committed_abort):
        for name in ("abort_claim_path", "release_claim_path"):
            if os.path.lexists(manifest["execution"][name]):
                raise GateError(f"pre-abort fixed claim exists: {name}")
        journal_length, journal_phase, snapshots, snapshot_raws = validate_active_journal(manifest)
    if args.check_only:
        if terminal_exists:
            replay_if_terminal(manifest)
        elif committed_abort:
            validate_committed_abort_readonly(manifest)
            print("committed VFDQA recovery boundary validated without mutation")
        else:
            helper_fd = seal(read_exact(manifest["runtime_helper"], "check-only runtime helper"),
                             "viewflow-early-gate-check-helper")
            manifest_fd = seal(manifest_bytes, "viewflow-early-gate-check-manifest")
            boundary = current_resume_boundary(helper_fd, manifest_fd, manifest,
                                               snapshots, journal_phase)
            reattest_inputs(manifest)
            print(f"early bootstrap gate abort resumable at {journal_phase}; "
                  f"Viewflow boundary is {boundary}; no mutation performed")
        return
    if terminal_exists:
        if replay_if_terminal(manifest):
            return
        raise GateError("terminal path vanished after validation")
    if committed_abort:
        resume_committed_abort(manifest, manifest_bytes)
        return
    helper_bytes = read_exact(manifest["runtime_helper"], "runtime helper")
    marker_bytes = validate_reviewed_marker_candidate(
        manifest["execution"]["marker_candidate"])
    helper_fd = seal(helper_bytes, "viewflow-early-gate-helper")
    manifest_fd = seal(manifest_bytes, "viewflow-early-gate-manifest")
    marker_fd = seal(marker_bytes, "viewflow-early-gate-marker-cli")
    outputs = manifest["outputs"]
    if journal_length == 0:
        snapshot, raw = run_helper(helper_fd, manifest_fd, "preflight")
        validate_snapshot(snapshot, manifest, "preflight", active=False)
        create_once(outputs["windows_live"], raw)
        snapshots["preflight"] = snapshot
        snapshot_raws["windows_live"] = raw
        reattest_inputs(manifest)
        journal_length = 1
    if journal_length == 1:
        snapshot, raw = adopt_or_start_linux(helper_fd, manifest_fd, manifest, snapshots)
        create_once(outputs["linux_started"], raw)
        snapshots["start-viewflow"] = snapshot
        snapshot_raws["linux_started"] = raw
        reattest_inputs(manifest)
        journal_length = 2
    for action, output in (("windows-v13", "windows_started"),
                           ("authenticated-peer", "authenticated_peer")):
        output_index = ACTIVE_OUTPUT_PREFIX.index(output)
        if journal_length > output_index:
            continue
        snapshot, raw = run_helper(helper_fd, manifest_fd, action)
        validate_snapshot(snapshot, manifest, action, active=True)
        if (snapshot["windows"] != snapshots["preflight"]["windows"]
                or snapshot["linux"] != snapshots["start-viewflow"]["linux"]):
            raise GateError(f"stable tuple changed at {action}")
        create_once(outputs[output], raw)
        snapshots[action] = snapshot
        snapshot_raws[output] = raw
        reattest_inputs(manifest)
        journal_length += 1
    auth, auth_raw = authorization_document(manifest, snapshot_raws)
    if journal_length == ACTIVE_OUTPUT_PREFIX.index("authorization"):
        create_once(outputs["authorization"], auth_raw)
        reattest_inputs(manifest)
        journal_length += 1
    else:
        persisted_auth_raw = read_owner_output(outputs["authorization"], "persisted authorization")
        if persisted_auth_raw != auth_raw or strict_json(persisted_auth_raw, "persisted authorization") != auth:
            raise GateError("persisted authorization bytes/binding differ")
    auth_sha = hash_bytes(auth_raw)
    if journal_length == ACTIVE_OUTPUT_PREFIX.index("pre_abort_reattest"):
        reattest, raw = run_helper(helper_fd, manifest_fd, "pre-abort-reattest")
        validate_snapshot(reattest, manifest, "pre-abort-reattest", active=True)
        if (reattest["windows"] != snapshots["preflight"]["windows"]
                or reattest["linux"] != snapshots["authenticated-peer"]["linux"]):
            raise GateError("post-authorization stable tuple changed before abort")
        create_once(outputs["pre_abort_reattest"], raw)
        snapshots["pre-abort-reattest"] = reattest
        snapshot_raws["pre_abort_reattest"] = raw
        reattest_inputs(manifest)
    else:
        raw = snapshot_raws["pre_abort_reattest"]
    identity = manifest["identity"]
    command = [f"/proc/self/fd/{marker_fd}"]
    command += ["abort", "--operation-id", manifest["operation_id"],
                "--coordinator-instance-id", identity["coordinator_instance_id"],
                "--marker-generation", "1", "--marker-sha256", manifest["marker"]["sha256"],
                "--abort-authorization-path", outputs["authorization"],
                "--abort-authorization-sha256", auth_sha]
    result = subprocess.run(command, env={"PATH": "/usr/bin:/bin"}, pass_fds=(marker_fd,),
                            check=True, stdout=subprocess.PIPE)
    receipt = strict_json(result.stdout, "abort receipt")
    durable_vfdqa = validate_abort_receipt(receipt, auth, auth_sha, manifest, replayed=False)
    create_once(outputs["abort_receipt"], result.stdout)
    durable_bytes = read_owner_output(durable_vfdqa, "durable VFDQA")
    validate_vfdqa(durable_bytes, receipt, auth_sha, manifest,
                   "fresh durable VFDQA")
    query = subprocess.run([f"/proc/self/fd/{marker_fd}", "query",
                            "--operation-id", manifest["operation_id"],
                            "--coordinator-instance-id", identity["coordinator_instance_id"],
                            "--marker-generation", "1", "--marker-sha256", manifest["marker"]["sha256"],
                            "--abort-authorization-path", outputs["authorization"],
                            "--abort-authorization-sha256", auth_sha], env={"PATH": "/usr/bin:/bin"},
                           pass_fds=(marker_fd,), check=True, stdout=subprocess.PIPE)
    query_receipt = strict_json(query.stdout, "abort query receipt")
    query_durable = validate_abort_receipt(query_receipt, auth, auth_sha, manifest, replayed=True)
    if query_durable != durable_vfdqa:
        raise GateError("abort query durable VFDQA path differs")
    for path in (manifest["execution"]["marker_path"], manifest["execution"]["abort_claim_path"],
                 manifest["execution"]["release_claim_path"], manifest["execution"]["runtime_marker_path"]):
        if os.path.lexists(path):
            raise GateError(f"post-abort marker/claim boundary is not empty: {path}")
    post_abort, post_abort_raw = run_helper(helper_fd, manifest_fd, "post-abort-reattest")
    validate_snapshot(post_abort, manifest, "post-abort-reattest", active=True)
    if (post_abort["windows"] != snapshots["preflight"]["windows"]
            or post_abort["linux"] != snapshots["authenticated-peer"]["linux"]):
        raise GateError("post-abort Deskflow/peer stable tuple changed")
    create_once(outputs["post_abort_reattest"], post_abort_raw)
    publish_terminal(manifest, auth_sha, result.stdout, raw, post_abort_raw, durable_bytes)
    print("early bootstrap no-worker gate abort committed; Deskflow remained inactive")


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, subprocess.CalledProcessError) as error:
        print(f"early bootstrap gate abort: {error}", file=sys.stderr)
        raise SystemExit(1)
