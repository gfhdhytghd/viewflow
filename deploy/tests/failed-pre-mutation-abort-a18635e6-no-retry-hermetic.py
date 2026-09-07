#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import threading
import time
from pathlib import Path

GATE = "/home/wilf/data/viewflow/deploy/gate-failed-pre-mutation-abort-a18635e6-no-retry.py"
spec = importlib.util.spec_from_file_location("vf_v4_gate", GATE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
approval_spec = importlib.util.spec_from_file_location(
    "vf_v4_approval",
    "/home/wilf/data/viewflow/deploy/publish-failed-pre-mutation-abort-a18635e6-no-retry-approval.py",
)
approval = importlib.util.module_from_spec(approval_spec)
approval_spec.loader.exec_module(approval)

manifest = json.loads(Path(
    "/home/wilf/data/viewflow/deploy/failed-pre-mutation-abort-a18635e6-no-retry-manifest.json"
).read_text())
argv = module.marker_cli_args(manifest, "a" * 64)
names = argv[::2]
assert names == ["--operation-id", "--coordinator-instance-id", "--marker-generation",
                 "--marker-sha256", "--abort-authorization-path",
                 "--abort-authorization-sha256"]
assert len(names) == len(set(names)) == 6

linux_raw = b"linux-proof\n"
windows_raw = b"windows-proof\n"
authorization = module.authorization(manifest, linux_raw, windows_raw)
assert authorization["schema_version"] == 4
assert authorization["input_producer_count"] == 0
assert authorization["windows_operation_root_inventory_sha256"] == manifest["windows_operation_root_inventory"]["sha256"]
assert not any("retry" in key for key in authorization)

with tempfile.TemporaryDirectory() as temporary:
    os.chmod(temporary, 0o700)
    target = str(Path(temporary) / "proof.json")
    module.create_once(target, b"one\n")
    module.create_once(target, b"one\n")
    assert Path(target).read_bytes() == b"one\n"
    try:
        module.create_once(target, b"two\n")
        raise AssertionError("create_once clobbered an existing output")
    except module.GateError:
        pass
    Path(target).unlink()
    Path(target).symlink_to("missing")
    try:
        module.create_once(target, b"one\n")
        raise AssertionError("create_once accepted a symlink")
    except (module.GateError, OSError):
        pass
    Path(target).unlink()
    original = Path(temporary) / "original"
    original.write_bytes(b"one\n")
    os.chmod(original, 0o600)
    os.link(original, target)
    try:
        module.create_once(target, b"one\n")
        raise AssertionError("create_once accepted a hardlink")
    except module.GateError:
        pass

with tempfile.TemporaryDirectory() as temporary:
    os.chmod(temporary, 0o700)
    lock_path = Path(temporary) / ".deployment-quarantine.v1.lock"
    lock_path.write_bytes(b"")
    os.chmod(lock_path, 0o600)
    durable_path = Path(temporary) / ".deployment-quarantine.v1.abort-receipt.fixture.v1"
    durable_path.write_bytes(b"durable-proof")
    os.chmod(durable_path, 0o600)
    terminal_path = Path(temporary) / "terminal.json"
    writer_started = threading.Event()

    def competing_publisher():
        import fcntl
        with lock_path.open("r+b", buffering=0) as lock:
            writer_started.set()
            fcntl.flock(lock, fcntl.LOCK_EX)
            marker = Path(temporary) / "deployment-quarantine.v1"
            marker.write_bytes(b"publisher-ran-after-terminal")
            os.chmod(marker, 0o600)
            fcntl.flock(lock, fcntl.LOCK_UN)

    thread = None

    def locked_hook():
        nonlocal_thread = threading.Thread(target=competing_publisher)
        globals()["_vf_competing_thread"] = nonlocal_thread
        nonlocal_thread.start()
        assert writer_started.wait(1)
        time.sleep(0.05)
        assert not (Path(temporary) / "deployment-quarantine.v1").exists()

    module.commit_terminal_under_marker_lock(
        str(durable_path), b"durable-proof", str(terminal_path), b"terminal\n",
        marker_parent=temporary, locked_hook=locked_hook,
    )
    thread = globals().pop("_vf_competing_thread")
    thread.join(1)
    assert terminal_path.read_bytes() == b"terminal\n"
    assert (Path(temporary) / "deployment-quarantine.v1").read_bytes() == b"publisher-ran-after-terminal"

with tempfile.TemporaryDirectory() as temporary:
    os.chmod(temporary, 0o700)
    approval.ROOT = Path(temporary)
    approval.OUTPUT = approval.ROOT / "approval.json"
    approval.publish(b"approval\n")
    assert approval.OUTPUT.read_bytes() == b"approval\n"
    try:
        approval.publish(b"other\n")
        raise AssertionError("approval publisher overwrote an existing receipt")
    except RuntimeError:
        pass
print("83fa no-retry V4 hermetic gate fixture passed")
