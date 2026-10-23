#!/usr/bin/env python3
"""Owned machine-none QEMU test of sealed memfd segment backends; no VFIO/GPU."""
import argparse
import ctypes
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

# Reuse only the existing QMP protocol helper; never execute its main/test.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "demand_qmp", Path(__file__).with_name("test-qemu-demand-dma.py"))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
SIZE = 1 << 30
SEGMENT = 64 << 20
PREFIX = "x-viewflow-dma-prefix"


def resident(fd):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                         ctypes.c_int, ctypes.c_int, ctypes.c_longlong]
    libc.mmap.restype = ctypes.c_void_p
    libc.mincore.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    libc.mincore.restype = ctypes.c_int
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    libc.munmap.restype = ctypes.c_int
    address = libc.mmap(None, SIZE, 1, 1, fd, 0)
    if address == ctypes.c_void_p(-1).value:
        raise OSError(ctypes.get_errno(), "mmap")
    try:
        page = os.sysconf("SC_PAGE_SIZE")
        vector = (ctypes.c_ubyte * ((SIZE + page - 1) // page))()
        if libc.mincore(address, SIZE, vector):
            raise OSError(ctypes.get_errno(), "mincore")
        return sum(v & 1 for v in vector) * page
    finally:
        if libc.munmap(address, SIZE):
            raise OSError(ctypes.get_errno(), "munmap")


def run(args, report):
    executable = str(Path(args.qemu).resolve(strict=True))
    deadline = time.monotonic() + args.timeout
    fd = os.memfd_create("viewflow-demand-test", os.MFD_ALLOW_SEALING | os.MFD_CLOEXEC)
    try:
        os.ftruncate(fd, SIZE)
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW)
        report["seals"] = fcntl.fcntl(fd, fcntl.F_GET_SEALS)
        def sample(stage):
            count = resident(fd)
            report["residency"].append({"stage": stage, "resident_bytes": count})
            if count:
                raise AssertionError(f"Unexpected pixel residency at {stage}: {count}")
        sample("before_qemu")
        with tempfile.TemporaryDirectory(prefix="viewflow-dma-memfd-", dir="/tmp") as directory:
            path = Path(directory)
            endpoint = path / "qmp.sock"
            command = [executable, "-machine", "none", "-nodefaults", "-display", "none",
                       "-S", "-qmp", f"unix:{endpoint},server=on,wait=off"]
            report["command"] = command
            process = None
            connection = None
            with (path / "stderr").open("w+b") as errors:
                try:
                    process = subprocess.Popen(command, pass_fds=(fd,), stdin=subprocess.DEVNULL,
                                               stdout=subprocess.DEVNULL, stderr=errors)
                    report["owned_pid"] = process.pid
                    while True:
                        if process.poll() is not None:
                            raise RuntimeError(f"Own QEMU exited {process.returncode}")
                        if time.monotonic() >= deadline:
                            raise TimeoutError("Own QEMU startup deadline")
                        candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        candidate.settimeout(min(1, max(.01, deadline-time.monotonic())))
                        try:
                            candidate.connect(str(endpoint))
                            connection = candidate
                            break
                        except (FileNotFoundError, ConnectionRefusedError):
                            candidate.close()
                            time.sleep(.02)
                    qmp = helper.QMP(connection, deadline, report["qmp"])
                    identities = [f"viewflow_dma_memfd{i}" for i in range(3)]
                    for i, ident in enumerate(identities):
                        qmp.call("object-add", {"qom-type": "memory-backend-file", "id": ident,
                                 "mem-path": f"/proc/self/fd/{fd}", "size": SEGMENT,
                                 "offset": i*SEGMENT, "share": True, "reserve": False,
                                 "prealloc": False, "x-viewflow-dma-managed": True})
                        if qmp.get(ident, "offset") != i*SEGMENT:
                            raise AssertionError("Segment offset readback mismatch")
                    expected = [0, 0, 0]
                    for i in range(3):
                        actual = [qmp.get(ident, PREFIX) for ident in identities]
                        if actual != expected:
                            raise AssertionError(f"Independent prefix mismatch: {actual}/{expected}")
                        qmp.set(identities[i], PREFIX, SEGMENT)
                        expected[i] = SEGMENT
                        actual = [qmp.get(ident, PREFIX) for ident in identities]
                        if actual != expected:
                            raise AssertionError(f"Growth affected other segments: {actual}/{expected}")
                        sample(f"segment_{i}_grown")
                    for ident in reversed(identities):
                        qmp.call("object-del", {"id": ident})
                    sample("all_objects_deleted")
                    qmp.call("quit")
                    process.wait(timeout=max(.01, deadline-time.monotonic()))
                    if process.returncode:
                        raise RuntimeError(f"Own QEMU exit status {process.returncode}")
                    sample("qemu_exited")
                    if os.fstat(fd).st_size != SIZE:
                        raise AssertionError("Sealed memfd extent changed")
                    report["status"] = "passed"
                finally:
                    if connection is not None:
                        connection.close()
                    # Supervise only the child created here, never discover other processes.
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
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--qemu", required=True)
    parser.add_argument("--timeout", type=float, default=45)
    args = parser.parse_args()
    if not 0 < args.timeout <= 300:
        parser.error("--timeout must be in (0,300]")
    report = {"status": "failed", "scope": "owned QMP/QOM memfd test only",
              "vfio_tested": False, "gpu_dma_tested": False, "guest_started": False,
              "residency_is_pin_proof": False, "memfd_bytes": SIZE,
              "segment_bytes": SEGMENT, "qmp": [], "residency": []}
    try:
        run(args, report)
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
