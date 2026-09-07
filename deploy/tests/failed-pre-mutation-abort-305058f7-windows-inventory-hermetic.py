#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
from pathlib import Path

PATH = "/home/wilf/data/viewflow/deploy/collect-failed-pre-mutation-abort-305058f7-windows-inventory.py"
spec = importlib.util.spec_from_file_location("op305_inventory", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def digest(seed):
    import hashlib
    return hashlib.sha256(seed.encode()).hexdigest()


members = []
for index, name in enumerate(module.EXPECTED_ORDER):
    members.append({"name": name, "kind": "file", "length": index,
                    "sha256": digest(name), "attributes": "Archive",
                    "owner": "WINDOWSVM\\wilf",
                    "sddl": "O:" + module.SID + "D:P(A;;FA;;;" + module.SID + ")",
                    "access_rules_protected": name not in ("installer.stderr.log", "installer.stdout.log")})
task = lambda name, state: {"task_name": name, "task_path": "\\", "state": state,
                            "xml_sha256": digest(name + "xml"),
                            "action_sha256": digest(name + "action"),
                            "principal_sha256": digest(name + "principal")}
snapshot = {
    "operation_root": {"root": module.WINDOWS_ROOT, "root_owner": "WINDOWSVM\\wilf",
                       "root_sddl": "O:" + module.SID + "D:P(A;OICI;FA;;;" + module.SID + ")",
                       "root_access_rules_protected": True, "member_count": 14, "members": members},
    "deployment_task": task("Viewflow Deployment " + module.OP, "Disabled"),
    "old_peer_task": task("Viewflow Peer", "Running"),
    "old_peer": {"pid": 123, "parent_pid": 45, "start_filetime_utc": "134330000000000000",
                 "session_id": 1, "sid": module.SID, "command_line_sha256": digest("cmd"),
                 "viewflowd_sha256": digest("exe"), "wrapper_sha256": digest("wrapper"),
                 "rollback_sha256": digest("rollback")},
    "bootstrap_worker_count": 0, "installer_process_count": 0,
    "mutation_outputs_present": [],
    "global_relevant_processes": [{"pid": 123, "parent_pid": 45,
                                    "executable_path": r"C:\Programs\viewflowd.exe",
                                    "command_line_sha256": digest("cmd")}],
}
document = {"schema_version": 2, "state": "viewflow-windows-operation-root-stable-inventory",
            "operation_id": module.OP, "stable": True, "before": snapshot, "after": snapshot}
module.validate_document(document)
assert module.strict_json(module.canonical(document)) == document
assert len(module.encoded_command()) < 7500

for mutate in (
    lambda value: value["before"].update({"bootstrap_worker_count": 1}),
    lambda value: value["before"]["operation_root"]["members"].pop(),
    lambda value: value["before"]["operation_root"]["members"][0].update({"sddl": "bad"}),
    lambda value: value["before"]["deployment_task"].update({"state": "Running"}),
):
    candidate = json.loads(json.dumps(document))
    mutate(candidate)
    try:
        module.validate_document(candidate)
        raise AssertionError("unsafe inventory mutation accepted")
    except module.InventoryError:
        pass

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    os.chmod(root, 0o700)
    module.ROOT = root
    module.OUTPUT = root / "inventory.json"
    raw = module.canonical(document)
    module.create_once(raw)
    assert module.OUTPUT.read_bytes() == raw
    try:
        module.create_once(raw)
        raise AssertionError("collector clobbered an existing output")
    except module.InventoryError:
        pass

print("op305 Windows stable-inventory hermetic fixture passed")
