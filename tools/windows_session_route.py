"""Choose the existing Windows media/input peers without touching desktop input."""
import base64
import subprocess
from desktop_peer_discovery import endpoint_host_port, ssh_args


def media_available(config, endpoint):
    """None means unknown: an SSH failure must not tear down a working route."""
    address, port = endpoint_host_port(endpoint)
    script = f"""$ErrorActionPreference='Stop'
$locked=[System.Diagnostics.Process]::GetProcessesByName('LogonUI').Length -gt 0
$desktop=[System.Diagnostics.Process]::GetProcessesByName('explorer').Length -gt 0
if ($locked -or !$desktop) {{[Console]::Write('input'); exit 0}}
$listeners=[System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners()
$listener=@($listeners | Where-Object {{$_.Port -eq {port}}}).Count -gt 0
if ($listener) {{[Console]::Write('media')}} else {{[Console]::Write('input')}}
"""
    encoded = base64.b64encode(script.encode('utf-16le')).decode('ascii')
    try:
        result = subprocess.run(ssh_args(config['peer_discovery'], address) +
                                ['powershell.exe', '-NoProfile', '-NonInteractive',
                                 '-EncodedCommand', encoded], capture_output=True,
                                text=True, errors="replace", timeout=6)
        if result.returncode == 0:
            return {'media': True, 'input': False}.get(result.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return None


class RoutePolicy:
    def __init__(self):
        self.mode = 'input'
        self.healthy = 0
        self.retry_after = 0.0

    def failed(self, now):
        self.healthy = 0
        self.retry_after = now + 30
        self.mode = 'input'

    def observe(self, available, now):
        if available is False:
            self.healthy = 0
            self.mode = 'input'
        elif available is True:
            self.healthy += 1
            if self.healthy >= 2 and now >= self.retry_after:
                self.mode = 'media'
        else:
            self.healthy = 0
        return self.mode
