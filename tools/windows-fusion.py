#!/usr/bin/env python3
"""Control the interactive Windows fusion session over the existing SSH identity."""
import argparse
import base64
import json
import os
from pathlib import Path, PureWindowsPath
import subprocess
import sys
import time
import uuid
import hashlib
import socket
from urllib.parse import unquote, urlsplit

DEFAULT_CONFIG = Path.home() / '.config/viewflow/fusion.json'


def windows_path(value, share):
    if value.startswith('file:'):
        uri = urlsplit(value)
        if uri.netloc not in ('', 'localhost'):
            raise ValueError('Only local file URLs can be shared')
        value = unquote(uri.path)
    path = Path(value).expanduser().resolve(strict=True)
    root = Path(share['root']).expanduser().resolve(strict=True)
    if not path.is_file():
        raise ValueError(f'Not a file: {path}')
    try:
        relative = path.relative_to(root)
    except ValueError:
        raise ValueError(f'{path} is outside the selected share ({root}); select Home or move the file into the temporary share') from None
    # SMB maps Windows path components; don't silently target a different name.
    if any(any(c in part for c in '\\:*?"<>|') or part.endswith((' ', '.')) for part in relative.parts):
        raise ValueError(f'Filename is not representable as a Windows SMB path: {path}')
    # Route FUSE subtrees through their user-owned Samba bridge after checking
    # the selected share's scope. This still addresses the original file.
    for mount in sorted(share.get('mounts', []), key=lambda item: len(item['root']), reverse=True):
        try:
            mounted_relative=path.relative_to(Path(mount['root']).expanduser().resolve(strict=True))
        except ValueError:
            continue
        return str(PureWindowsPath(mount['unc']).joinpath(*mounted_relative.parts))
    return str(PureWindowsPath(share['unc']).joinpath(*relative.parts))


def control_socket(config):
    identity=json.dumps({'ssh':config['ssh'],'directory':config['guest_directory']},sort_keys=True).encode()
    return Path(os.environ.get('XDG_RUNTIME_DIR',f'/run/user/{os.getuid()}'))/'viewflow'/('fusion-'+hashlib.sha256(identity).hexdigest()[:16]+'.sock')


def request(config, payload):
    connection=socket.socket(socket.AF_UNIX);connection.settimeout(30)
    try:
        connection.connect(str(control_socket(config)))
    except (FileNotFoundError,ConnectionRefusedError):
        connection.close()
    else:
        with connection:
            connection.sendall(json.dumps(payload,ensure_ascii=False).encode()+b'\n')
            with connection.makefile('rb') as stream:reply=stream.readline(2*1024*1024)
        result=json.loads(reply.decode('utf-8-sig'))
        if not result.get('ok'):raise RuntimeError(result.get('error','Windows request failed'))
        return result
    return request_over_ssh(config,payload)


def request_over_ssh(config, payload):
    token = uuid.uuid4().hex
    body = base64.b64encode(json.dumps(payload, ensure_ascii=False).encode()).decode()
    directory = base64.b64encode(config['guest_directory'].encode()).decode()
    script = f"""$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$OutputEncoding=[Console]::OutputEncoding
trap {{ @{{ok=$false;error=$_.Exception.Message}} | ConvertTo-Json -Compress; exit 1 }}
$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{directory}'))
# The interactive task can have exited since login. Recover before enqueueing
# this action; its IgnoreNew policy prevents duplicate desktop agents.
$task=Get-ScheduledTask -TaskName 'Viewflow-Fusion-Agent'
if($task.State -ne 'Running'){{Start-ScheduledTask -TaskName 'Viewflow-Fusion-Agent'}}
$p=Join-Path $d 'requests\\{token}.json'
[IO.File]::WriteAllBytes(($p+'.next'),[Convert]::FromBase64String('{body}'))
Move-Item ($p+'.next') $p
$reply=Join-Path $d 'responses\\{token}.json'
$deadline=[DateTime]::UtcNow.AddSeconds(20)
while(-not (Test-Path $reply)){{
 if([DateTime]::UtcNow -gt $deadline){{throw 'Windows desktop agent has not replied; the request may still be pending'}}
 Start-Sleep -Milliseconds 100
}}
Get-Content $reply -Raw -Encoding UTF8
Remove-Item $reply
"""
    encoded = base64.b64encode(script.encode('utf-16le')).decode()
    peer = config['ssh']
    control_dir=Path.home()/'.cache/viewflow/ssh';control_dir.mkdir(parents=True,exist_ok=True);control_dir.chmod(0o700)
    proc = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                           '-o','ControlMaster=auto','-o','ControlPersist=300','-o','ControlPath='+str(control_dir/'%C'),
                           '-o', 'HostKeyAlias='+peer['host_key_alias'],
                           peer['user']+'@'+peer['host'], 'powershell.exe', '-NoProfile',
                           '-NonInteractive', '-EncodedCommand', encoded],
                          capture_output=True, text=True, encoding='utf-8', errors='replace', stdin=subprocess.DEVNULL, timeout=30)
    if proc.returncode:
        try:
            message = json.loads(proc.stdout.strip()).get('error')
        except ValueError:
            message = None
        raise RuntimeError(message or (proc.stderr.strip().splitlines() or ['Cannot reach Windows'])[-1])
    result = json.loads(proc.stdout.lstrip('\ufeff').strip())
    if not result.get('ok'):
        raise RuntimeError(result.get('error', 'Windows request failed'))
    return result


def save(path, config):
    temporary = path.with_suffix('.next')
    temporary.write_text(json.dumps(config, indent=2, ensure_ascii=False)+'\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def hyprland_env():
    instances = json.loads(subprocess.check_output(['hyprctl', 'instances', '-j'], text=True))
    if not instances:
        raise RuntimeError('Hyprland desktop unavailable')
    signature = os.environ.get('HYPRLAND_INSTANCE_SIGNATURE')
    instance = next((i for i in instances if i['instance'] == signature), None)
    if instance is None:
        instance = next((i for i in instances if i['wl_socket'] == os.environ.get('WAYLAND_DISPLAY')), instances[0])
    return dict(os.environ, HYPRLAND_INSTANCE_SIGNATURE=instance['instance'])


def prepare_start_menu(anchor):
    if not anchor:return
    env=hyprland_env()
    monitors=json.loads(subprocess.check_output(['hyprctl','monitors','-j'],env=env,text=True))
    x,y=anchor
    for monitor in monitors:
        if monitor['x']<=x<monitor['x']+monitor['width']/monitor['scale'] and monitor['y']<=y<monitor['y']+monitor['height']/monitor['scale']:
            move=f"{int(x-monitor['x'])} {int(y-monitor['y'])}"
            rule="hl.window_rule({name='viewflow-windows-start-anchor',match={class='^ViewflowReverse-WindowsStart-.*$'},float=true,pin=true,no_anim=true,monitor="+json.dumps(monitor['name'])+",workspace="+json.dumps(monitor['activeWorkspace']['name']+' silent')+",move="+json.dumps(move)+"})"
            subprocess.run(['hyprctl','eval',rule],env=env,check=True,capture_output=True)
            return
    raise RuntimeError('Start button anchor is outside the active monitors')


def focus_start_menu(anchor=None):
    # Invoked only by the user's Start button, never during installation/tests.
    env=hyprland_env()
    deadline = time.monotonic()+12
    while time.monotonic() < deadline:
        clients = json.loads(subprocess.check_output(['hyprctl', 'clients', '-j'], env=env, text=True))
        for client in clients:
            if client.get('mapped') and client.get('class', '').startswith('ViewflowReverse-WindowsStart-'):
                selector = json.dumps('address:'+client['address'])
                if anchor:
                    x,y=anchor
                    monitors=json.loads(subprocess.check_output(['hyprctl','monitors','-j'],env=env,text=True))
                    for monitor in monitors:
                        width=monitor['width']/monitor['scale'];height=monitor['height']/monitor['scale']
                        if monitor['x'] <= x < monitor['x']+width and monitor['y'] <= y < monitor['y']+height:
                            x=max(monitor['x'],min(x,monitor['x']+width-client['size'][0]))
                            y=max(monitor['y'],min(y,monitor['y']+height-client['size'][1]))
                            workspace=json.dumps(monitor['activeWorkspace']['name'])
                            subprocess.run(['hyprctl','dispatch','hl.dsp.window.move({workspace='+workspace+',follow=false,window='+selector+'})'],env=env,check=True,capture_output=True)
                            break
                    subprocess.run(['hyprctl','dispatch',f'hl.dsp.window.move({{x={int(x)},y={int(y)},window='+selector+'})'],env=env,check=True,capture_output=True)
                subprocess.run(['hyprctl','dispatch','hl.dsp.window.pin({action="set",window='+selector+'})'],env=env,check=True,capture_output=True)
                subprocess.run(['hyprctl', 'eval', 'hl.plugin.viewflow.focus_without_warp('+selector+')'], env=env, check=True, capture_output=True)
                return
        time.sleep(.1)
    raise RuntimeError('Windows received Start, but its menu surface has not appeared on Linux yet')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest='action', required=True)
    start=sub.add_parser('start');start.add_argument('--anchor',nargs=2,type=int)
    dismiss=sub.add_parser('dismiss-start');dismiss.add_argument('--window-class')
    for name in ('ping', 'on', 'off', 'toggle', 'status', 'menu'):
        sub.add_parser(name)
    share = sub.add_parser('share');share.add_argument('mode', choices=('home', 'temporary'))
    op = sub.add_parser('open')
    target=op.add_mutually_exclusive_group()
    target.add_argument('--choose', action='store_true')
    target.add_argument('--app', choices=('word','excel','powerpoint'))
    op.add_argument('--dry-run', action='store_true');op.add_argument('files', nargs='+')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if args.action == 'dismiss-start' and args.window_class:
        clients=json.loads(subprocess.check_output(['hyprctl','clients','-j'],env=hyprland_env(),text=True))
        if not any(c.get('mapped') and c.get('class')==args.window_class for c in clients):return
    if args.action == 'menu':
        labels = ['Windows 开始菜单', '关闭融合模式' if config.get('enabled') else '开启融合模式',
                  '文件共享：整个 Home', '文件共享：临时目录', '打开临时共享目录']
        choice = subprocess.run(['rofi-wayland', '-dmenu', '-p', 'Windows'], input='\n'.join(labels), text=True, capture_output=True)
        if choice.returncode:
            return
        selected = choice.stdout.strip()
        if selected not in labels:
            return
        index = labels.index(selected)
        if index == 4:
            subprocess.Popen(['xdg-open', config['shares']['temporary']['root']]);return
        command = [['start'], ['toggle'], ['share', 'home'], ['share', 'temporary']][index]
        subprocess.run([sys.executable, __file__, '--config', str(args.config), *command], check=True)
        return
    if args.action == 'status':
        print(json.dumps({'enabled': config.get('enabled', False), 'share': config['share_mode']}));return
    if args.action == 'share':
        config['share_mode'] = args.mode;save(args.config, config);print(args.mode);return
    if args.action in ('on', 'off', 'toggle'):
        enabled = args.action == 'on' or (args.action == 'toggle' and not config.get('enabled', False))
        request(config, {'action': 'fusion', 'enabled': enabled})
        config['enabled'] = enabled;save(args.config, config);return
    payload = {'action': args.action}
    if args.action == 'open':
        payload.update(paths=[windows_path(f, config['shares'][config['share_mode']]) for f in args.files], choose=args.choose)
        if args.app:payload['app']=args.app
        if args.dry_run:
            print(json.dumps(payload, ensure_ascii=False));return
    started=time.monotonic()
    if args.action == 'start':prepare_start_menu(args.anchor)
    result = request(config, payload)
    if args.action == 'start':
        replied=time.monotonic()
        focus_start_menu(args.anchor)
        timing=Path.home()/'.cache/viewflow/start-timing.jsonl'
        timing.parent.mkdir(parents=True,exist_ok=True)
        with timing.open('a') as log:
            log.write(json.dumps({'time':time.time(),'request_ms':round((replied-started)*1000,1),'surface_ms':round((time.monotonic()-replied)*1000,1)})+'\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Windows fusion: {error}', file=sys.stderr)
        if os.environ.get('WAYLAND_DISPLAY'):
            subprocess.run(['notify-send', 'Windows fusion', str(error)], check=False)
        sys.exit(1)
