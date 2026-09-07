#!/usr/bin/env python3
"""Bounded, single-client UDP fault relay for an explicitly selected test peer.

Listens only on loopback. SIGUSR1 drops both directions once, without buffering
or replaying packets. Does not modify routes, interfaces, or firewall rules.
"""
import argparse
import ipaddress
import json
import os
import selectors
import signal
import socket
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--listen-port", type=int, default=0)
    parser.add_argument("--drop-ms", type=int, default=750)
    parser.add_argument("--lifetime-seconds", type=int, default=60)
    args = parser.parse_args()
    host, port = args.remote.rsplit(":", 1)
    ipaddress.IPv4Address(host)
    port = int(port)
    if not (1 <= port <= 65535 and 0 <= args.listen_port <= 65535
            and 1 <= args.drop_ms <= 5000 and 1 <= args.lifetime_seconds <= 120):
        parser.error("invalid bounded relay arguments")
    stopping = False
    requested = False

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    def fault(_signal, _frame):
        nonlocal requested
        requested = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGUSR1, fault)

    def emit(event, **fields):
        print(json.dumps(dict(event=event, monotonic_ns=time.monotonic_ns(), **fields)), flush=True)

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as front, \
            socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as back, \
            selectors.DefaultSelector() as selector:
        for endpoint in (front, back):
            endpoint.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
            endpoint.setblocking(False)
        front.bind(("127.0.0.1", args.listen_port))
        back.connect((host, port))
        selector.register(front, selectors.EVENT_READ)
        selector.register(back, selectors.EVENT_READ)
        emit("ready", pid=os.getpid(), listen=front.getsockname(), upstream=back.getsockname())
        client = None
        drop_until = None
        fault_used = False
        forwarded = [0, 0]
        dropped = [0, 0]
        unrelated = 0
        end = time.monotonic() + args.lifetime_seconds
        while not stopping and time.monotonic() < end:
            now = time.monotonic()
            if requested and not fault_used:
                fault_used = True
                drop_until = now + args.drop_ms / 1000
                emit("drop_started", duration_ms=args.drop_ms)
            if drop_until is not None and now >= drop_until:
                drop_until = None
                emit("drop_finished", dropped=dropped)
            for key, _ in selector.select(0.002):
                direction = int(key.fileobj is back)
                for _ in range(64):
                    try:
                        packet, address = key.fileobj.recvfrom(65536)
                    except BlockingIOError:
                        break
                    if direction == 0:
                        if client is None:
                            client = address
                            emit("client", address=client)
                        if address != client:
                            unrelated += 1
                            continue
                    if drop_until is not None:
                        dropped[direction] += 1
                        continue
                    if direction == 0:
                        back.send(packet)
                    elif client is not None:
                        front.sendto(packet, client)
                    forwarded[direction] += 1
        emit("stopped", fault_used=fault_used, forwarded=forwarded, dropped=dropped,
             unrelated=unrelated)


if __name__ == "__main__":
    main()
