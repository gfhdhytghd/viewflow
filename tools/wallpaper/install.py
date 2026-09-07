#!/usr/bin/env python3
"""Install the optional wallpaper sidecar without restarting the media session."""
import argparse
import json
from pathlib import Path
import subprocess

from sync import powershell, quote, run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--monitor', required=True)
    parser.add_argument('--receiver-config', required=True)
    parser.add_argument('--remote-root', required=True)
    parser.add_argument('--provider', choices=['awww', 'swww'], default='awww')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    config = dict(host=args.host, monitor=args.monitor, remote_root=args.remote_root, provider=args.provider,
                  task='ViewflowWallpaper', resize='crop')
    policy = json.loads(powershell(config, 'Get-Content -Raw -LiteralPath ' + quote(args.receiver_config)).decode('utf-8-sig'))
    rect = [int(value) for value in policy['reverse']['args']]
    if len(rect) != 4 or rect[2] <= rect[0] or rect[3] <= rect[1]:
        raise ValueError('Receiver reverse args must specify the virtual monitor rectangle')
    config['rect'] = rect
    powershell(config, 'New-Item -ItemType Directory -Force -Path ' + quote(args.remote_root) + ' | Out-Null')
    powershell(config, "if(Get-ScheduledTask -TaskName 'ViewflowWallpaper' -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName 'ViewflowWallpaper'}")
    script = root / 'tools/wallpaper/windows.ps1'
    destination = args.remote_root.replace('\\', '/') + '/windows.ps1'
    run(['scp', '-q', '-o', 'BatchMode=yes', str(script), args.host + ':' + destination])
    # InteractiveToken binds COM to the logged-in user's desktop, not SSH's desktop.
    action = '-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + destination + '" -Root "' + args.remote_root + '"'
    powershell(config, f"""
$ErrorActionPreference='Stop'
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument {quote(action)}
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'ViewflowWallpaper' -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'ViewflowWallpaper'
""")
    local_config = Path.home()/'.config/viewflow/wallpaper.json'
    local_config.parent.mkdir(parents=True, exist_ok=True)
    local_config.write_text(json.dumps(config, indent=2)+'\n')
    service = Path.home()/'.config/systemd/user/viewflow-wallpaper.service'
    service.parent.mkdir(parents=True, exist_ok=True)
    content = (root/'deploy/linux/viewflow-wallpaper.service').read_text()
    content = content.replace('%h/data/viewflow', str(root))
    service.write_text(content)
    subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', '--user', 'enable', 'viewflow-wallpaper.service'], check=True)
    subprocess.run(['systemctl', '--user', 'restart', 'viewflow-wallpaper.service'], check=True)
    print('Wallpaper sidecar installed; media session retained')


if __name__ == '__main__':
    main()
