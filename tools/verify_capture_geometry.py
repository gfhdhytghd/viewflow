#!/usr/bin/env python3
"""Owned isolated-compositor metadata/fence test; not pixel/display acceptance."""
import argparse
import array
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compositor-pid", type=int, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    root = args.output_dir.resolve(strict=True)
    info = root.stat()
    if not str(root).startswith("/tmp/viewflow-") or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError("private owned test output directory required")
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if not runtime.startswith("/tmp/") or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        raise RuntimeError("explicit isolated compositor environment required")
    command = Path(f"/proc/{args.compositor_pid}/cmdline").read_bytes().split(b"\0")
    if b"--config" not in command or not command[command.index(b"--config") + 1].startswith(b"/tmp/viewflow-"):
        raise RuntimeError("compositor is not an explicitly configured Viewflow test instance")

    def hypr(*command):
        return subprocess.check_output(["hyprctl", *command], text=True, timeout=3)

    if json.loads(hypr("-j", "clients")):
        raise RuntimeError("isolated compositor must have no pre-existing test clients")

    def request(name, payload, function):
        path = root / name
        with path.open("x") as output:
            json.dump(payload, output)
        path.chmod(0o600)
        hypr("repl", f"return hl.plugin.viewflow_capture.{function}({json.dumps(str(path))})")
        result = json.loads(path.read_text())
        if result.get("ok") is not True:
            raise RuntimeError(f"capture request failed: {result}")

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    path = root / "capture.sock"
    listener.bind(str(path))
    path.chmod(0o600)
    listener.listen(1)
    listener.settimeout(3)
    stream = "geometry-witness"
    started = False
    probe = None
    epochs = []
    frame_count = 0
    previous = None
    try:
        with (root / "probe.log").open("x") as output:
            probe = subprocess.Popen([str(args.probe.resolve(strict=True))], stdout=output, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 3
            while True:
                clients = [c for c in json.loads(hypr("-j", "clients")) if c["pid"] == probe.pid]
                if len(clients) == 1:
                    break
                if probe.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("owned geometry probe did not map")
                time.sleep(0.05)
            request("start.json", {"id": stream, "socketPath": str(path),
                "windowAddress": clients[0]["address"], "fps": 30, "mode": "window-gpu"}, "window_stream_start")
            started = True
            connection, _ = listener.accept()
            with connection, (root / "frames.jsonl").open("x") as log:
                pid, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
                if (pid, uid) != (args.compositor_pid, os.getuid()):
                    raise RuntimeError("unexpected capture producer")
                connection.settimeout(1)
                deadline = time.monotonic() + 38
                while probe.poll() is None:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("owned capture test timed out")
                    try:
                        data, ancillary, flags, _ = connection.recvmsg(320, socket.CMSG_SPACE(8))
                    except TimeoutError:
                        if probe.poll() is None:
                            raise RuntimeError("capture stopped across owned geometry change")
                        break
                    fds = []
                    try:
                        for level, kind, payload in ancillary:
                            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                                values = array.array("i")
                                values.frombytes(payload)
                                fds.extend(values)
                        if len(data) != 320 or len(fds) != 2 or flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC):
                            raise RuntimeError("malformed GPU frame")
                        if data[:8] != b"HCGF\x00\x01\x00\xe8" or data[232:240] != b"HCGI\x00\x01\x00\x58":
                            raise RuntimeError("unexpected GPU metadata versions")
                        sequence, stamp, epoch = struct.unpack_from(">QQQ", data, 8)
                        logical = struct.unpack_from(">dddd", data, 32)
                        pixels = struct.unpack_from(">II", data, 64)
                        fingerprint = (logical, pixels, data[232:])
                        if previous:
                            old_sequence, old_epoch, old_fingerprint = previous
                            if sequence <= old_sequence or epoch != old_epoch + (fingerprint != old_fingerprint):
                                raise RuntimeError("geometry epoch did not match changed capture/input mapping")
                        elif epoch != 1:
                            raise RuntimeError("initial capture epoch is not one")
                        # The receiver never imports/reads the image. Await the
                        # producer fence, then release only this exact allocation.
                        poll = select.poll()
                        poll.register(fds[1], select.POLLIN)
                        events = poll.poll(1000)
                        if not events or not events[0][1] & select.POLLIN:
                            raise RuntimeError("GPU producer fence did not complete")
                        connection.sendall(struct.pack(">4sHHQQQ", b"HCGR", 1, 32, sequence, epoch, 0))
                        row = {"sequence": sequence, "epoch": epoch, "capture_ns": stamp,
                            "logical": logical, "pixels": pixels}
                        log.write(json.dumps(row) + "\n")
                        log.flush()
                        if not previous or epoch != previous[1]:
                            epochs.append(row)
                            print(json.dumps(row), flush=True)
                        previous = (sequence, epoch, fingerprint)
                        frame_count += 1
                    finally:
                        for fd in fds:
                            os.close(fd)
            if probe.wait(timeout=2) != 0:
                raise RuntimeError("owned probe failed")
            if len(epochs) < 5 or epochs[-1]["pixels"] != epochs[0]["pixels"]:
                raise RuntimeError("resize/popup/restore geometry transitions missing")
            print(json.dumps({"frames": frame_count, "epochs": len(epochs),
                "pixel_content_verified": False, "physical_present_receipt": False}), flush=True)
    finally:
        try:
            if started:
                request("stop.json", {"streamId": stream}, "window_stream_stop")
        finally:
            if probe is not None:
                if probe.poll() is None:
                    probe.terminate()
                try:
                    probe.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    probe.kill()
                    probe.wait(timeout=3)
            listener.close()
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
