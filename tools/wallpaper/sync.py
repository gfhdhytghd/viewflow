#!/usr/bin/env python3
"""Sync static awww/swww wallpaper over existing SSH credentials, independently of media."""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import time

from PIL import Image, ImageOps


def run(argv, **kwargs):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', 'replace')[-1500:])
    return result.stdout


def powershell(config, script):
    encoded = base64.b64encode(script.encode('utf-16le')).decode()
    return run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', config['host'],
                'powershell -NoProfile -NonInteractive -EncodedCommand ' + encoded])


def quote(value):
    return "'" + value.replace("'", "''") + "'"


def discover(query, monitor):
    for line in query.splitlines():
        match = re.search(r'(?:^|: )' + re.escape(monitor) + r': .*currently displaying: (image|color): (.+)$', line)
        if match:
            return match.group(1), match.group(2).strip()
    raise ValueError(f'No active wallpaper for {monitor}')


def render(kind, value, size, mode='crop'):
    if kind == 'color':
        if not re.fullmatch(r'[0-9a-fA-F]{6}([0-9a-fA-F]{2})?', value):
            raise ValueError('Invalid solid wallpaper color')
        image = Image.new('RGB', size, '#' + value[:6])
    else:
        with Image.open(value) as source:
            image = ImageOps.exif_transpose(source).convert('RGB')
        if mode == 'crop':
            image = ImageOps.fit(image, size, Image.Resampling.LANCZOS)
        elif mode == 'stretch':
            image = image.resize(size, Image.Resampling.LANCZOS)
        elif mode in ('fit', 'no'):
            if mode == 'fit':
                image = ImageOps.contain(image, size, Image.Resampling.LANCZOS)
            canvas = Image.new('RGB', size)
            canvas.paste(image, ((size[0]-image.width)//2, (size[1]-image.height)//2))
            image = canvas
        else:
            raise ValueError('Unsupported wallpaper resize mode')
    result = io.BytesIO()
    image.save(result, format='PNG')
    return result.getvalue()


def synchronize(config, cache, previous):
    # The daemon query, rather than a possibly stale wallpaper config, is authoritative.
    kind, value = discover(run([config.get('provider', 'awww'), 'query']).decode(), config['monitor'])
    content = hashlib.sha256(Path(value).read_bytes()).hexdigest() if kind == 'image' else value
    rect = config['rect']
    size = (rect[2]-rect[0], rect[3]-rect[1])
    if min(size) <= 0 or max(size) > 16384:
        raise ValueError('Invalid target monitor rectangle')
    signature = (kind, value, content, tuple(rect), config.get('resize', 'crop'), config['host'], config['remote_root'])
    root = config['remote_root']
    if previous is None or previous[0] != signature:
        data = render(kind, value, size, config.get('resize', 'crop'))
        digest = hashlib.sha256(data).hexdigest()
        local = cache / (digest + '.png')
        local.write_bytes(data)
        request = cache / 'request.json'
        request.write_text(json.dumps({'version': 1, 'sha256': digest, 'rect': rect, 'source': value}))
        powershell(config, f'New-Item -ItemType Directory -Force -Path {quote(root)} | Out-Null')
        for source, name in ((local, digest + '.png'), (request, 'request.next.json')):
            run(['scp', '-q', '-o', 'BatchMode=yes', str(source), config['host'] + ':' + root.replace('\\', '/') + '/' + name])
        # Publish the manifest only after the image upload completes.
        powershell(config, "Add-Type 'public static class PublishWallpaper { public static void Move(string s,string d) { if(System.IO.File.Exists(d)) System.IO.File.Replace(s,d,null); else System.IO.File.Move(s,d); } }'; "
                   f"[PublishWallpaper]::Move({quote(root + '/request.next.json')},{quote(root + '/request.json')})")
        print(f'Wallpaper uploaded: {value} -> {size}, sha256={digest}', flush=True)
        previous = (signature, digest, 0)
    if time.monotonic() - previous[2] >= 30:
        task = quote(config.get('task', 'ViewflowWallpaper'))
        raw = powershell(config, f"$t=Get-ScheduledTask -TaskName {task}; if($t.State -ne 'Running'){{Start-ScheduledTask -TaskName {task}}}; if(Test-Path -LiteralPath {quote(root + '/receipt.json')}){{Get-Content -Raw -LiteralPath {quote(root + '/receipt.json')}}}")
        if raw.strip():
            receipt = json.loads(raw.decode('utf-8-sig'))
            if receipt['sha256'] == previous[1] and receipt['rect'] == rect:
                (cache / 'receipt.json').write_text(json.dumps(receipt, indent=2))
                print('Wallpaper verified on Windows virtual monitor', flush=True)
                return previous[0], previous[1], time.monotonic()
        print('Waiting for Windows wallpaper receipt', flush=True)
    return previous


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    cache = Path(os.environ.get('XDG_CACHE_HOME', str(Path.home()/'.cache'))) / 'viewflow/wallpaper'
    cache.mkdir(parents=True, exist_ok=True)
    previous = None
    while True:
        try:
            if not os.environ.get('WAYLAND_DISPLAY'):
                instances = json.loads(run(['hyprctl', '-j', 'instances']))
                if len(instances) != 1:
                    raise ValueError('Select WAYLAND_DISPLAY for this wallpaper session')
                os.environ['WAYLAND_DISPLAY'] = instances[0]['wl_socket']
            config = json.loads(args.config.read_text())
            previous = synchronize(config, cache, previous)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            print(f'Wallpaper sync retry: {error}', flush=True)
            if args.once:
                raise
        if args.once:
            break
        time.sleep(3)


if __name__ == '__main__':
    main()
