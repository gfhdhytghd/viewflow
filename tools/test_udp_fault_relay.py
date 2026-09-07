#!/usr/bin/env python3
"""Exercise real relay sockets, bounded packet loss, recovery and clean stop."""
import json
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import unittest


class RelayTest(unittest.TestCase):
    def test_one_fault_drops_both_directions_and_does_not_replay(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server, \
                socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            server.bind(("127.0.0.1", 0))
            server.settimeout(0.1)
            client.settimeout(0.1)
            child = subprocess.Popen([
                sys.executable, str(Path(__file__).with_name("udp_fault_relay.py")),
                "--remote", f"127.0.0.1:{server.getsockname()[1]}", "--drop-ms", "400",
                "--lifetime-seconds", "5",
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
            try:
                def event(name):
                    with selectors.DefaultSelector() as selector:
                        selector.register(child.stdout, selectors.EVENT_READ)
                        self.assertTrue(selector.select(2), "relay log timeout")
                    value = json.loads(child.stdout.readline())
                    self.assertEqual(value["event"], name)
                    return value

                ready = event("ready")
                relay = tuple(ready["listen"])
                client.sendto(b"before", relay)
                request, upstream = server.recvfrom(100)
                self.assertEqual(request, b"before")
                event("client")
                server.sendto(b"reply", upstream)
                self.assertEqual(client.recvfrom(100)[0], b"reply")
                child.send_signal(signal.SIGUSR1)
                event("drop_started")
                client.sendto(b"lost-request", relay)
                server.sendto(b"lost-reply", upstream)
                with self.assertRaises(TimeoutError):
                    server.recvfrom(100)
                with self.assertRaises(TimeoutError):
                    client.recvfrom(100)
                done = event("drop_finished")
                self.assertEqual(done["dropped"], [1, 1])
                client.sendto(b"after", relay)
                self.assertEqual(server.recvfrom(100)[0], b"after")
                server.sendto(b"new-reply", upstream)
                self.assertEqual(client.recvfrom(100)[0], b"new-reply")
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as unrelated:
                    unrelated.sendto(b"wrong-client", relay)
                    with self.assertRaises(TimeoutError):
                        server.recvfrom(100)
                child.send_signal(signal.SIGUSR1)
                client.sendto(b"second-signal-does-not-repeat-fault", relay)
                self.assertEqual(server.recvfrom(100)[0], b"second-signal-does-not-repeat-fault")
                child.send_signal(signal.SIGTERM)
                stopped = event("stopped")
                self.assertEqual(stopped["unrelated"], 1)
                self.assertEqual(child.wait(timeout=2), 0)
                self.assertEqual(child.stderr.read(), "")
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=2)
                child.stdout.close()
                child.stderr.close()


if __name__ == "__main__":
    unittest.main()
