#!/usr/bin/env python3
"""Resolve an identified desktop peer without pinning its DHCP address."""
import argparse
import base64
import ipaddress
import json
from pathlib import Path
import subprocess


def endpoint_host_port(endpoint):
    host, port = endpoint.rsplit(':', 1)
    port = int(port)
    if not 1 <= port <= 65535:
        raise ValueError('Invalid peer port')
    return host.strip('[]'), port


def neighbor_candidates(rows, mac):
    result = []
    for row in rows:
        if row.get('lladdr', '').lower() != mac.lower():
            continue
        if {'FAILED', 'INCOMPLETE'} & set(row.get('state', [])):
            continue
        address = ipaddress.ip_address(row['dst'])
        if address.version == 4 and str(address) not in result:
            result.append(str(address))
    return result


def ssh_args(peer, address):
    return ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ConnectTimeout=3', '-o', 'ConnectionAttempts=1',
            '-o', 'HostKeyAlias=' + peer['ssh_host_key_alias'],
            peer['ssh_user'] + '@' + address]


def resolve(config):
    peer = config.get('peer_discovery')
    if not peer:
        return config['remote']
    host, port = endpoint_host_port(config['remote'])
    candidates = []
    # Neighbors are tied to this desktop's stable NIC, not other LAN machines.
    rows = json.loads(subprocess.check_output(['ip', '-j', '-4', 'neigh', 'show'], timeout=3))
    candidates.extend(neighbor_candidates(rows, peer['mac']))
    for name in dict.fromkeys([host, *peer.get('hostnames', [])]):
        try:
            result = subprocess.run(['getent', 'ahostsv4', name], capture_output=True,
                                    text=True, timeout=3)
            for line in result.stdout.splitlines():
                address = str(ipaddress.IPv4Address(line.split()[0]))
                if address not in candidates:
                    candidates.append(address)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    for address in candidates:
        try:
            result = subprocess.run(ssh_args(peer, address) + ['hostname'],
                                    capture_output=True, text=True, timeout=5)
            if result.returncode == 0 and result.stdout.strip().casefold() == peer['hostname'].casefold():
                return f'{address}:{port}'
        except (OSError, subprocess.SubprocessError):
            continue
    raise RuntimeError(f"Cannot find {peer['hostname']} by hostname or NIC {peer['mac']}; Windows may still be starting")


def start_windows(config, endpoint):
    address, _ = endpoint_host_port(endpoint)
    script = "if ((Get-ScheduledTask -TaskName 'ViewflowInput-Prelogin').State -ne 'Running') { Start-ScheduledTask -TaskName 'ViewflowInput-Prelogin' }"
    encoded = base64.b64encode(script.encode('utf-16le')).decode('ascii')
    subprocess.run(ssh_args(config['peer_discovery'], address) +
                   ['powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
                   check=True, timeout=12, stdout=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--start-windows', action='store_true')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    endpoint = resolve(config)
    if args.start_windows:
        start_windows(config, endpoint)
    print(endpoint)


if __name__ == '__main__':
    main()
