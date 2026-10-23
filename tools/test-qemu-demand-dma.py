#!/usr/bin/env python3
"""Isolated QOM lifecycle test; never connects to an existing QEMU instance.

No guest, VFIO device, GPU, or DMA transfer is involved. This tests the candidate
backend's API and sparse allocation behavior, not hardware DMA correctness.
"""
import argparse
import ctypes
import json
import mmap
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time


MIB = 1 << 20
SIZE = 1 << 30
MANAGED = "x-viewflow-dma-managed"
PREFIX = "x-viewflow-dma-prefix"


class QMP:
    def __init__(self, sock, deadline, records):
        self.sock, self.deadline, self.records = sock, deadline, records
        self.buffer = b""
        self.sequence = 0
        greeting = self.receive()
        if "QMP" not in greeting:
            raise RuntimeError(f"Invalid QMP greeting: {greeting!r}")
        self.call("qmp_capabilities")

    def receive(self):
        while b"\n" not in self.buffer:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Own test QEMU exceeded deadline")
            self.sock.settimeout(remaining)
            data = self.sock.recv(65536)
            if not data:
                raise RuntimeError("Own test QEMU closed QMP")
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def call(self, command, arguments=None, reject=False):
        self.sequence += 1
        request = {"execute": command, "id": self.sequence}
        if arguments is not None:
            request["arguments"] = arguments
        self.sock.sendall(json.dumps(request).encode() + b"\n")
        while True:
            response = self.receive()
            if "event" in response:
                continue
            if response.get("id") != self.sequence:
                raise RuntimeError(f"Unexpected QMP response: {response!r}")
            break
        self.records.append({"request": request, "response": response})
        failed = "error" in response
        if failed != reject:
            raise AssertionError(f"Expected {'rejection' if reject else 'success'}: {response!r}")
        return response.get("return")

    def get(self, ident, prop):
        return self.call("qom-get", {"path": f"/objects/{ident}", "property": prop})

    def set(self, ident, prop, value, reject=False):
        return self.call("qom-set", {"path": f"/objects/{ident}", "property": prop,
                                     "value": value}, reject)


def sparse_file(directory, name):
    path = directory / name
    with path.open("xb") as stream:
        stream.truncate(SIZE)
    return path


def residency(path):
    """mincore does not fault the mapped bytes in; never read/write the pixels."""
    page = os.sysconf("SC_PAGE_SIZE")
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    libc.mincore.restype = ctypes.c_int
    with path.open("r+b") as stream:
        with mmap.mmap(stream.fileno(), SIZE, flags=mmap.MAP_SHARED,
                       prot=mmap.PROT_READ | mmap.PROT_WRITE) as mapping:
            anchor = ctypes.c_char.from_buffer(mapping)
            vector = (ctypes.c_ubyte * ((SIZE + page - 1) // page))()
            try:
                if libc.mincore(ctypes.addressof(anchor), SIZE, vector):
                    code = ctypes.get_errno()
                    raise OSError(code, os.strerror(code))
                resident = sum(v & 1 for v in vector) * page
            finally:
                del anchor
    return {"virtual_bytes": SIZE, "resident_bytes": resident,
            "allocated_file_bytes": path.stat().st_blocks * 512}


def run(args, report):
    executable = Path(args.qemu).resolve(strict=True)
    deadline = time.monotonic() + args.timeout
    # Short private socket path, with no dependence on any production VM path.
    with tempfile.TemporaryDirectory(prefix="viewflow-dma-", dir="/tmp") as name:
        directory = Path(name)
        sockpath = directory / "qmp.sock"
        pixel = sparse_file(directory, "viewflow-dma-pixels")
        ordinary = sparse_file(directory, "ordinary-file")
        command = [str(executable), "-machine", "none", "-nodefaults", "-display",
                   "none", "-S", "-qmp", f"unix:{sockpath},server=on,wait=off"]
        report["command"] = command
        process = None
        sock = None
        with (directory / "stderr.log").open("w+b") as errors:
            try:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                           stdout=subprocess.DEVNULL, stderr=errors)
                report["owned_pid"] = process.pid
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f"Own test QEMU exited: {process.returncode}")
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Own test QEMU QMP startup deadline")
                    candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    candidate.settimeout(min(1, max(.01, deadline - time.monotonic())))
                    try:
                        candidate.connect(str(sockpath))
                        sock = candidate
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        candidate.close()
                        time.sleep(.02)
                qmp = QMP(sock, deadline, report["qmp"])
                ident = "viewflow_dma_test"
                def properties(object_id, path, **extra):
                    result = {"qom-type": "memory-backend-file", "id": object_id,
                              "mem-path": str(path), "size": SIZE, "share": True,
                              "reserve": False, "prealloc": False, MANAGED: True}
                    result.update(extra)
                    return result

                def sample(label):
                    value = residency(pixel)
                    report["residency"].append({"stage": label, **value})
                    if value["resident_bytes"] != 0 or value["allocated_file_bytes"] != 0:
                        raise AssertionError(f"Backend touched sparse pixels at {label}: {value}")

                sample("before_object")
                qmp.call("object-add", properties(ident, pixel))
                blockers = qmp.call("query-migrate").get("blocked-reasons", [])
                assert any("Viewflow" in reason for reason in blockers), blockers
                assert qmp.get(ident, PREFIX) == 0
                assert qmp.get(ident, MANAGED) is True
                sample("created_zero_prefix")
                for value in (0, MIB, 81 * MIB, 81 * MIB):
                    qmp.set(ident, PREFIX, value)
                    assert qmp.get(ident, PREFIX) == value
                sample("grown_81_mib")
                for prop, value in ((PREFIX, MIB), (PREFIX, SIZE + MIB),
                                    (PREFIX, 81 * MIB + 1), (MANAGED, False),
                                    (MANAGED, True), ("prealloc", True),
                                    ("reserve", True)):
                    before = qmp.get(ident, prop)
                    qmp.set(ident, prop, value, reject=True)
                    assert qmp.get(ident, prop) == before
                    assert qmp.get(ident, PREFIX) == 81 * MIB
                sample("rejected_mutations")
                qmp.call("object-del", {"id": ident})
                # Failure before allocation must not leak the object or discard requirement.
                for prop in ("prealloc", "reserve"):
                    qmp.call("object-add", properties(ident, pixel, **{prop: True}), reject=True)
                    qmp.call("qom-get", {"path": f"/objects/{ident}", "property": PREFIX}, reject=True)
                    qmp.call("object-add", properties(ident, pixel))
                    assert qmp.get(ident, PREFIX) == 0
                    qmp.call("object-del", {"id": ident})
                qmp.call("object-add", properties(ident, pixel))
                qmp.set(ident, PREFIX, MIB)
                qmp.call("object-del", {"id": ident})
                sample("deleted_recreated_deleted")
                blockers = qmp.call("query-migrate").get("blocked-reasons", [])
                assert not any("Viewflow" in reason for reason in blockers), blockers
                normal = properties("ordinary_test", ordinary)
                normal.pop(MANAGED)
                normal["reserve"] = True
                qmp.call("object-add", normal)
                assert qmp.get("ordinary_test", MANAGED) is False
                assert qmp.get("ordinary_test", "reserve") is True
                qmp.set("ordinary_test", PREFIX, MIB, reject=True)
                assert qmp.get("ordinary_test", PREFIX) == 0
                qmp.call("object-del", {"id": "ordinary_test"})
                report["ordinary_backend"] = "default unmanaged/reserve=true lifecycle passed"
                qmp.call("quit")
                process.wait(timeout=max(.01, deadline - time.monotonic()))
                if process.returncode:
                    raise RuntimeError(f"Own test QEMU exit status {process.returncode}")
                report["status"] = "passed"
            finally:
                if sock is not None:
                    sock.close()
                # Only this exact Popen child may be terminated. No pid discovery,
                # process groups, production socket, or external cleanup commands.
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
                errors.flush()
                errors.seek(0)
                report["stderr"] = errors.read().decode(errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qemu", required=True, help="Candidate QEMU executable")
    parser.add_argument("--timeout", type=float, default=45, help="Whole test deadline in seconds")
    args = parser.parse_args()
    if args.timeout <= 0 or args.timeout > 300:
        parser.error("--timeout must be in (0, 300]")
    report = {"status": "failed", "scope": "isolated QMP/QOM and sparse backing only",
              "vfio_tested": False, "gpu_dma_tested": False, "guest_started": False,
              "qmp": [], "residency": []}
    try:
        run(args, report)
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
