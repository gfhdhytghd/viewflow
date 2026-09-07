#!/usr/bin/env python3
"""Bounded real native resize rebind witness; no Windows/latency acceptance."""
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
    parser.add_argument("--terminal", choices=["expiry", "unmap"])
    parser.add_argument("--held", choices=["button", "key"])
    args = parser.parse_args()
    root = args.output_dir.resolve(strict=True)
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    if not str(root).startswith("/tmp/viewflow-") or root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
        raise RuntimeError("private owned output required")
    if not str(runtime).startswith("/tmp/") or not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        raise RuntimeError("explicit isolated environment required")
    display = Path(os.environ.get("WAYLAND_DISPLAY", ""))
    display = display if display.is_absolute() else runtime / display
    if display.parent.resolve() != runtime.resolve() or not display.is_socket():
        raise RuntimeError("probe display must be the isolated runtime socket")
    proc = Path(f"/proc/{args.compositor_pid}")
    cmd = (proc / "cmdline").read_bytes().split(b"\0")
    if b"--config" not in cmd or not cmd[cmd.index(b"--config") + 1].startswith(b"/tmp/viewflow-"):
        raise RuntimeError("not an owned compositor")
    env = dict(entry.split(b"=", 1) for entry in (proc / "environ").read_bytes().split(b"\0") if b"=" in entry)
    native_path = runtime / "input.sock"
    if env.get(b"VIEWFLOW_HYPRLAND_SOCKET") != os.fsencode(native_path) or native_path.exists():
        raise RuntimeError("native endpoint mismatch or already owned")

    def hypr(*command):
        return subprocess.check_output(["hyprctl", *command], text=True, timeout=3)

    if json.loads(hypr("-j", "clients")):
        raise RuntimeError("isolated compositor has existing clients")

    def request(name, payload, function):
        path = root / name
        with path.open("x") as output:
            json.dump(payload, output)
        path.chmod(0o600)
        hypr("repl", f"return hl.plugin.viewflow_capture.{function}({json.dumps(str(path))})")
        if json.loads(path.read_text()).get("ok") is not True:
            raise RuntimeError(f"failed capture request: {name}")

    def listener(path):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        sock.bind(str(path))
        path.chmod(0o600)
        sock.listen(1)
        sock.settimeout(3)
        return sock

    def accept(sock):
        connection, _ = sock.accept()
        pid, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if (pid, uid) != (args.compositor_pid, os.getuid()):
            connection.close()
            raise RuntimeError("unexpected native peer")
        return connection

    probe = None
    started = False
    cap_path = root / "capture.sock"
    native_listener = listener(native_path)
    cap_listener = listener(cap_path)
    native = capture = None
    try:
        native = accept(native_listener)
        with (root / "probe.log").open("x") as output, (root / "native.jsonl").open("x") as log:
            probe = subprocess.Popen([str(args.probe.resolve(strict=True))], stdout=output, stderr=subprocess.STDOUT)
            cutoff = time.monotonic() + 3
            while True:
                clients = [c for c in json.loads(hypr("-j", "clients")) if c["pid"] == probe.pid]
                if len(clients) == 1:
                    break
                if probe.poll() is not None or time.monotonic() >= cutoff:
                    raise RuntimeError("probe failed to map")
                time.sleep(0.05)
            request("start.json", {"id": "resize-input-witness", "socketPath": str(cap_path),
                "windowAddress": clients[0]["address"], "fps": 30, "mode": "window-gpu"}, "window_stream_start")
            started = True
            capture = accept(cap_listener)
            sequence = 0
            resized = False
            terminal_seen = False
            last_native = 0

            def read_native():
                nonlocal resized, terminal_seen, last_native
                data = native.recv(16384)
                magic, version, opcode, length, envelope = struct.unpack_from("<4sHHIQ", data)
                if magic != b"VFHY" or version != 1 or len(data) != 20 + length or envelope <= last_native:
                    raise RuntimeError("invalid native envelope")
                last_native = envelope
                if opcode in (53, 54):
                    row = {"opcode": opcode, "envelope": envelope, "payload_hex": data[20:].hex()}
                    log.write(json.dumps(row) + "\n")
                    log.flush()
                if opcode == 54:
                    generation, reason, reserved = struct.unpack_from("<QII", data, 20)
                    allowed_terminal = {13} if args.terminal == "expiry" else {2, 3, 4}
                    if generation != 1 or reserved or (reason != 5 and not (args.terminal and reason in allowed_terminal)):
                        raise RuntimeError(f"unexpected native revocation {generation}/{reason}")
                    if reason == 5:
                        resized = True
                    else:
                        terminal_seen = True
                return opcode, data[20:]

            def command(opcode, generation, payload, expected):
                nonlocal sequence
                sequence += 1
                body = struct.pack("<Q", generation) + payload
                native.sendall(struct.pack("<4sHHIQ", b"VFHY", 1, opcode, len(body), sequence) + body)
                limit = time.monotonic() + 1
                while time.monotonic() < limit:
                    if not select.select([native], [], [], max(0, limit - time.monotonic()))[0]:
                        break
                    kind, body = read_native()
                    if kind != 53:
                        continue
                    gen, seq, result, reserved = struct.unpack("<QQII", body)
                    if (gen, seq, result, reserved) != (generation, sequence, expected, 0):
                        raise RuntimeError(f"unexpected command result: {gen}/{seq}/{result}")
                    print(json.dumps({"command": opcode, "generation": gen, "result": result}), flush=True)
                    return
                raise RuntimeError("native command timed out")

            def binding(window, surface, pid, extent):
                return struct.pack("<QQQddQ", window, pid, time.monotonic_ns() + 4_000_000_000, *extent, surface)

            active = False
            done = False
            start = time.monotonic()
            while time.monotonic() - start < 17 and probe.poll() is None:
                readable, _, _ = select.select([native, capture], [], [], 1)
                if native in readable:
                    read_native()
                if capture not in readable:
                    continue
                data, ancillary, flags, _ = capture.recvmsg(320, socket.CMSG_SPACE(8))
                fds = []
                try:
                    for level, kind, payload in ancillary:
                        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                            values = array.array("i")
                            values.frombytes(payload)
                            fds.extend(values)
                    if flags or len(data) != 320 or len(fds) != 2 or data[232:240] != b"HCGI\x00\x01\x00\x58":
                        raise RuntimeError("invalid capture envelope")
                    frame, _, epoch = struct.unpack_from(">QQQ", data, 8)
                    window, surface, pid = struct.unpack_from(">QQQ", data, 240)
                    extent = struct.unpack_from(">dd", data, 296)
                    if pid != probe.pid or window != int(clients[0]["address"], 16):
                        raise RuntimeError("capture identity mismatch")
                    poll = select.poll()
                    poll.register(fds[1], select.POLLIN)
                    if not any(events & select.POLLIN for _, events in poll.poll(1000)):
                        raise RuntimeError("capture fence timeout")
                    capture.sendall(struct.pack(">4sHHQQQ", b"HCGR", 1, 32, frame, epoch, 0))
                finally:
                    for fd in fds:
                        os.close(fd)
                if not active and time.monotonic() - start > 9:
                    if extent != (400.0, 300.0):
                        raise RuntimeError(f"unexpected initial extent: {extent}")
                    command(59 if args.held == "key" else 56 if args.held == "button" else 50,
                        1, binding(window, surface, pid, extent), 1)
                    command(51, 1, struct.pack("<Qdd", time.monotonic_ns() + 200_000_000, 100, 50), 2)
                    if args.held == "button":
                        command(55, 1, struct.pack("<QddII", time.monotonic_ns() + 200_000_000, 100, 50, 1, 1), 4)
                    elif args.held == "key":
                        command(60, 1, struct.pack("<QIIII", time.monotonic_ns() + 200_000_000, 7, 4, 1, 0), 6)
                    active = True
                if active and resized and extent == (500.0, 350.0):
                    if args.terminal:
                        if args.terminal == "unmap":
                            probe.terminate()
                            probe.wait(timeout=3)
                        cutoff = time.monotonic() + 5
                        while not terminal_seen and time.monotonic() < cutoff:
                            if select.select([native], [], [], 0.1)[0]:
                                read_native()
                        if not terminal_seen:
                            raise RuntimeError("missing terminal guard notification")
                        command(61, 3, binding(window, surface, pid, extent), 0)
                        command(50, 4, binding(window, surface, pid, extent), 0)
                        done = True
                        print(json.dumps({"terminal": args.terminal, "rebind_rejected": True,
                            "ordinary_begin_rejected": True}), flush=True)
                        break
                    command(50, 2, binding(window, surface, pid, extent), 0)
                    command(61, 3, binding(window, surface, pid, extent), 1)
                    command(51, 3, struct.pack("<Qdd", time.monotonic_ns() + 200_000_000, 150, 60), 2)
                    command(52, 3, b"", 3)
                    time.sleep(0.1)
                    events = [json.loads(line) for line in (root / "probe.log").read_text().splitlines() if line.startswith("{")]
                    for x, y in [(100, 50), (150, 60)]:
                        if not any(e.get("event") == "motion" and e.get("x") == x and e.get("y") == y for e in events):
                            raise RuntimeError(f"application did not observe motion {x}/{y}")
                    if args.held:
                        transitions = [e for e in events if e.get("event") == args.held and not e.get("repeat", False)]
                        if [e["down"] for e in transitions] != [True, False]:
                            raise RuntimeError(f"held input was not released exactly once: {transitions}")
                        if args.held == "button" and any(e["button"] != 1 for e in transitions):
                            raise RuntimeError("wrong button cleanup")
                        # Qt reports the XKB scan code (evdev KEY_A 30 + 8),
                        # not the raw Wayland/evdev key value sent by the plugin.
                        if args.held == "key" and any(e["scan"] != 38 for e in transitions):
                            raise RuntimeError("wrong key cleanup")
                        release_index = next(i for i, e in enumerate(events)
                            if e.get("event") == args.held and not e.get("down") and not e.get("repeat", False))
                        if any(e.get("event") == args.held for e in events[release_index + 1:]):
                            raise RuntimeError("held input continued after cleanup")
                    done = True
                    print(json.dumps({"native_resize_rebind": True, "application_coordinates": True,
                        "held_cleanup": args.held,
                        "windows_verified": False, "latency_gate": False}), flush=True)
                    break
            if not done:
                raise RuntimeError("resize recovery not completed")
    finally:
        try:
            if started:
                request("stop.json", {"streamId": "resize-input-witness"}, "window_stream_stop")
        finally:
            if native:
                native.close()
            if capture:
                capture.close()
            native_listener.close()
            cap_listener.close()
            native_path.unlink(missing_ok=True)
            cap_path.unlink(missing_ok=True)
            if probe:
                if probe.poll() is None:
                    probe.terminate()
                try:
                    probe.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    probe.kill()
                    probe.wait(timeout=3)


if __name__ == "__main__":
    main()
