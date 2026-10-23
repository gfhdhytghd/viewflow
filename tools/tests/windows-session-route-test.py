#!/usr/bin/env python3
"""Session state changes and failed probes; no Windows/compositor operations."""
import sys
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from windows_session_route import RoutePolicy, media_available

p = RoutePolicy()
assert p.mode == 'input'
assert p.observe(False, 0) == 'input'  # boot/login screen
assert p.observe(True, 3) == 'input'  # receiver startup may be transient
assert p.observe(None, 6) == 'input'
assert p.observe(True, 9) == 'input'
assert p.observe(True, 12) == 'media'
assert p.observe(None, 15) == 'media'  # SSH outage does not remove working input
assert p.observe(False, 18) == 'input'  # lock/logout, even if media had been alive
assert p.observe(True, 21) == 'input'
assert p.observe(True, 24) == 'media'
p.failed(25)  # native/transport failure despite receiver listener
assert p.mode == 'input'
assert p.observe(True, 28) == 'input'
assert p.observe(True, 31) == 'input'
assert p.observe(True, 54) == 'input'
assert p.observe(True, 55) == 'media'
config = {'peer_discovery': {'ssh_user': 'test', 'ssh_host_key_alias': 'peer'}}
for output, code, expected in [('media', 0, True), ('input', 0, False),
                                ('', 1, None), ('unexpected', 0, None)]:
    with patch('windows_session_route.subprocess.run', return_value=SimpleNamespace(
            stdout=output, returncode=code)) as run:
        assert media_available(config, '192.0.2.1:44129') is expected
        args = run.call_args.args[0]
        assert 'StrictHostKeyChecking=yes' in args
        assert '-EncodedCommand' in args
# PowerShell may emit localized, non-UTF8 diagnostics even on success.
import subprocess
original = subprocess.run
with patch('windows_session_route.subprocess.run', side_effect=lambda args, **kwargs:
           original([sys.executable, '-c', "import os;os.write(2,bytes([255]));print('input',end='')"], **kwargs)):
    assert media_available(config, '192.0.2.1:44129') is False
print('Windows automatic route policy and read-only probe tests passed')
