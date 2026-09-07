#!/usr/bin/env python3
"""Exercise SIGINT/SIGTERM against the real native media entry point.

Stops during a loopback handshake. No compositor, capture, or input is started.
This is deliberately not proof of stopping an active GPU session.
"""
import argparse
import json
import os
import re
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import time


def exercise(binary, fixtures, stop_signal, reconnect):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as blackhole:
        blackhole.bind(("127.0.0.1", 0))
        args = [
            str(binary), "send", "--remote", f"127.0.0.1:{blackhole.getsockname()[1]}",
            "--server-name", "localhost", "--cert", str(fixtures / "peer.pem"),
            "--key", str(fixtures / "peer.key"), "--ca", str(fixtures / "ca.pem"),
            "--capture-stream", "0x1", "--compositor-pid", "1",
            "--logical-width", "100", "--logical-height", "100",
            "--composition-blur-rect", "0,0,100,100", "--composition-blur-radius", "1",
            "--persistent", "--timeout-ms", "100" if reconnect else "60000",
        ]
        if reconnect:
            args.append("--reconnect")
        child = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        diagnostic = bytearray()
        try:
            ready_deadline = time.monotonic() + 10
            with selectors.DefaultSelector() as selector:
                selector.register(child.stderr, selectors.EVENT_READ)
                marker = (b"native media retry after attempt=2 " if reconnect
                          else b"native media owner stop handlers ready")
                while marker not in diagnostic:
                    remaining = ready_deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise AssertionError("stop handler readiness timed out")
                    chunk = os.read(child.stderr.fileno(), 8192)
                    if not chunk:
                        raise AssertionError(f"process exited before readiness: {diagnostic!r}")
                    diagnostic.extend(chunk)
            started = time.monotonic()
            child.send_signal(stop_signal)
            _, remainder = child.communicate(timeout=5)
            diagnostic.extend(remainder)
            elapsed = time.monotonic() - started
            assert child.returncode == 1, (child.returncode, diagnostic)
            assert b"stop requested; attempt retirement returned" in diagnostic, diagnostic
            assert b"Error:" in diagnostic, diagnostic
            assert b"native media cleanup failed" not in diagnostic, diagnostic
            ports = set()
            blackhole.setblocking(False)
            while True:
                try:
                    _, address = blackhole.recvfrom(65536)
                    ports.add(address[1])
                except BlockingIOError:
                    break
            if reconnect:
                assert len(ports) == 1, ports
                assert len(re.findall(rb"native media retry after attempt=\d+ ", diagnostic)) >= 2
            print(json.dumps({"signal": stop_signal.name, "exit_code": child.returncode,
                              "stop_ms": round(elapsed * 1000, 3),
                              "reconnect": reconnect, "observed_source_ports": sorted(ports),
                              "retirement_returned": True,
                              "transport_error_preserved": True}))
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
            child.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--reconnect", action="store_true", help="stop during backoff after two failed admissions")
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("this test sends POSIX signals; Windows console events need a separate test")
    fixtures = Path(__file__).resolve().parent.parent / "crates/viewflow-transport/tests/fixtures"
    for stop_signal in (signal.SIGINT, signal.SIGTERM):
        exercise(args.binary.resolve(), fixtures, stop_signal, args.reconnect)


if __name__ == "__main__":
    main()
