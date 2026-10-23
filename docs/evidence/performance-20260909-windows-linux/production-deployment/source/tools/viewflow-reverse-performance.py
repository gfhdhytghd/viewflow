#!/usr/bin/env python3
"""Read or change the Windows-to-Linux performance mode without restarting it."""
import argparse
import base64
import json
from pathlib import Path
import subprocess

MODES = ('frame-rate', 'latency')
DEFAULT_CONFIG = Path.home() / '.config/viewflow/reverse-performance.json'


def load_config(path):
    config = json.loads(path.read_text())
    if not isinstance(config, dict):
        raise ValueError('reverse performance configuration must be an object')
    host, native = config.get('ssh_host'), config.get('native')
    if not isinstance(host, str) or not host or host.startswith('-') or any(c.isspace() for c in host):
        raise ValueError('reverse performance configuration needs an SSH host')
    if not isinstance(native, str) or not native or '\x00' in native or '\n' in native or '\r' in native:
        raise ValueError('reverse performance configuration needs a native executable path')
    return {'ssh_host': host, 'native': native}


def ps_string(value):
    return "'" + value.replace("'", "''") + "'"


def command_script(config, mode=None):
    if mode is not None and mode not in MODES:
        raise ValueError(f'unknown reverse performance mode: {mode}')
    script = r"""
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$native=NATIVE_PATH
$path=Join-Path (Split-Path -Parent $native) 'reverse-performance-mode'
# Legacy reverse programs ignore unknown arguments and would start capture.
# The status printf format is retained even when option comparisons are inlined.
# Check that protocol marker before invoking this read-only command.
if(-not [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($native)).Contains('"max_pending":%u,"scope":"configured"')){
    throw 'The installed reverse program needs the performance-mode update'
}
function Read-Mode {
    $text=& $native --mode-file $path --performance-status
    if($LASTEXITCODE -ne 0){throw 'Reverse native program does not provide performance settings'}
    $value=$text | ConvertFrom-Json
    if($value.schema -ne 1 -or $value.scope -ne 'configured' -or $value.mode -notin @('frame-rate','latency')){
        throw 'Unsupported reverse performance settings response'
    }
    return $value
}
$before=Read-Mode
""".replace('NATIVE_PATH', ps_string(config['native']))
    if mode is None:
        return script + "$before | ConvertTo-Json -Compress\n"
    script += "$requested=" + ps_string(mode) + r"""
$temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
try {
    [IO.File]::WriteAllText($temporary,$requested+"`n",[Text.UTF8Encoding]::new($false))
    for($attempt=0;;$attempt++){
        try {
            if([IO.File]::Exists($path)){
                [IO.File]::Replace($temporary,$path,[NullString]::Value)
            } else {
                [IO.File]::Move($temporary,$path)
            }
            break
        } catch {
            $cause=$_.Exception.InnerException
            $code=if($null -ne $cause){$cause.HResult -band 65535}else{0}
            if($attempt -ge 9 -or $code -notin @(32,33)){throw}
            # A native settings read may briefly overlap the atomic replace.
            Start-Sleep -Milliseconds 20
        }
    }
} finally {
    if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
}
$after=Read-Mode
if($after.mode -ne $requested){throw 'Reverse performance setting changed during verification'}
[pscustomobject]@{schema=1;mode=$after.mode;max_pending=$after.max_pending;scope='configured';changed=($before.mode -ne $after.mode);restarted=$false} | ConvertTo-Json -Compress
"""
    return script


def request(config, mode=None):
    script = 'try {\n' + command_script(config, mode) + r"""
} catch {
    [pscustomobject]@{error=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
}
"""
    encoded = base64.b64encode(script.encode('utf-16le')).decode('ascii')
    result = subprocess.run([
        'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', config['ssh_host'],
        'powershell', '-NoProfile', '-EncodedCommand', encoded,
    ], check=False, capture_output=True, text=True, timeout=20)
    if result.returncode:
        try:
            message = json.loads(result.stdout.lstrip('\ufeff'))['error']
        except (ValueError, KeyError, TypeError):
            message = '\n'.join(line for line in result.stderr.splitlines() if not line.startswith('** ')).strip()
        raise RuntimeError(message or f'SSH control failed with exit code {result.returncode}')
    value = json.loads(result.stdout.lstrip('\ufeff'))
    if not isinstance(value, dict) or value.get('mode') not in MODES or value.get('scope') != 'configured':
        raise RuntimeError('invalid reverse performance response')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('status')
    select = commands.add_parser('set')
    select.add_argument('mode', choices=MODES)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        print(json.dumps(request(config, args.mode if args.command == 'set' else None)))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'viewflow-reverse-performance: {error}\n')


if __name__ == '__main__':
    main()
