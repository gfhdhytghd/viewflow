#!/usr/bin/env python3
"""Exercise real owner death without starting networking, capture or input.
Usage: managed-owner-test.py <viewflowd lib-test executable>
"""
import os
import json
from pathlib import Path
import tempfile
import select
import signal
import subprocess
import sys
import time

PARENT = r'''
import os, subprocess, sys, time
env = dict(os.environ, VIEWFLOW_OWNER_TEST=sys.argv[2])
env.pop("VIEWFLOW_OWNER_PID", None)
if sys.argv[2] != "standalone": env["VIEWFLOW_OWNER_PID"] = str(os.getpid())
child = subprocess.Popen([sys.argv[1], "--exact", "managed_owner::tests::owner_fixture", "--nocapture"], env=env, stdout=subprocess.PIPE, text=True)
for line in child.stdout:
    if "owner-fixture-ready" in line:
        print(child.pid, flush=True)
        break
while True: time.sleep(1)
'''

def alive(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    return result.returncode == 0 and not result.stdout.lstrip().startswith("Z")

# Isolate this OS lifecycle test from unrelated platform-specific lib tests.
harness = tempfile.TemporaryDirectory(prefix="viewflow-owner-test-")
if len(sys.argv) > 1:
    fixture = os.path.abspath(sys.argv[1])
else:
    root = Path(harness.name)
    source = Path(__file__).resolve().parents[2] / "crates/viewflowd/src/managed_owner.rs"
    (root / "Cargo.toml").write_text('[package]\nname="viewflow-owner-test"\nversion="0.0.0"\nedition="2024"\n[dependencies]\nanyhow="1"\nlibc="0.2"\n[lib]\npath="lib.rs"\n[workspace]\n')
    (root / "lib.rs").write_text('#[path = ' + json.dumps(str(source)) + ']\nmod managed_owner;\n')
    build = subprocess.run(["cargo", "test", "--offline", "--no-run", "--message-format=json", "--manifest-path", str(root / "Cargo.toml")], capture_output=True, text=True)
    assert build.returncode == 0, build.stderr
    fixture = next(item["executable"] for line in build.stdout.splitlines() if (item := json.loads(line)).get("executable"))

for mode in ("owned", "standalone", "stubborn"):
    parent = subprocess.Popen([sys.executable, "-c", PARENT, fixture, mode], stdout=subprocess.PIPE, text=True)
    child = None
    try:
        assert select.select([parent.stdout], [], [], 10)[0], "fixture did not start"
        child = int(parent.stdout.readline())
        time.sleep(0.6)
        assert alive(child), "service exited while owner was alive"
        parent.kill(); parent.wait(timeout=3)
        if mode == "standalone":
            time.sleep(1)
            assert alive(child), "standalone service was incorrectly stopped"
        else:
            until = time.monotonic() + 10
            while alive(child) and time.monotonic() < until: time.sleep(0.1)
            assert not alive(child), "orphan service survived owner death"
        print(mode + ": passed")
    finally:
        if parent.poll() is None: parent.kill(); parent.wait()
        if child is not None and alive(child): os.kill(child, signal.SIGKILL)
