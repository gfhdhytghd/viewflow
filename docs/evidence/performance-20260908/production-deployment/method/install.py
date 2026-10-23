"""Check staged files by default. --apply installs the previously qualified pair."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time

B = Path(__file__).resolve().parent.parent
ROOT = Path('/home/wilf/data/viewflow')
CONFIG = Path('/home/wilf/.config/viewflow/desktop-source.json')
BACKUP = Path('/home/wilf/.local/share/viewflow/performance-backup-20260909')
PLUGIN = ROOT / 'build/desktop/capture/viewflow-capture.so'
SERVICE = 'viewflow-desktop.service'

def run(argv):
    result = subprocess.run([str(v) for v in argv], capture_output=True, text=True, errors='replace', timeout=55)
    if result.returncode:
        raise RuntimeError(f'{argv[0]} failed ({result.returncode}): {result.stderr.strip()} {result.stdout.strip()}')
    return result.stdout

def digest(path):
    path = Path(path)
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

def windows(mode):
    return json.loads(run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
        'wilf@172.16.105.70', 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', r'C:\Users\wilf\Viewflow\performance-stage-20260909\windows-install.ps1', '-Mode', mode]))

def inactive():
    state = run(['systemctl', '--user', 'show', SERVICE, '--property=ActiveState', '--value']).strip()
    if state != 'inactive':
        raise RuntimeError('Main Linux service state changed; recheck coordinated deployment state')
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            args = (proc / 'cmdline').read_bytes().split(b'\0')
        except (PermissionError, FileNotFoundError, ProcessLookupError):
            continue
        if args and b'vf-media-peer' in args[0].rsplit(b'/', 1)[-1] and b'send' in args and b'--config' in args:
            raise RuntimeError(f'An active sender still uses capture: PID {proc.name}')

def geometry():
    return [{k: m[k] for k in ['id', 'name', 'width', 'height', 'x', 'y', 'scale', 'transform', 'refreshRate']}
            for m in json.loads(run(['hyprctl', '-j', 'monitors', 'all']))]

def restore_virtual_geometry(before):
    # Plugin load/unload can reload the compositor's persistent monitor rules.
    # Restore existing dynamic headless modes; never create or reassign outputs.
    expected = {m['name']: m for m in before}
    changes = []
    stable = 0
    for _ in range(50):
        current = {m['name']: m for m in geometry()}
        assert current.keys() == expected.keys(), 'Output set changed during installation'
        for name, old in expected.items():
            new = current[name]
            if new == old:
                continue
            assert old['id'] == new['id'] and name.startswith('HEADLESS-'), 'Physical display changed; inspect before continuing'
            mode = f"{old['width']}x{old['height']}@{old['refreshRate']}"
            position = f"{old['x']}x{old['y']}"
            expression = ('hl.monitor({output=' + json.dumps(name) + ',mode=' + json.dumps(mode)
                + ',position=' + json.dumps(position) + ',scale=' + str(old['scale'])
                + ',transform=' + str(old['transform']) + '})')
            run(['hyprctl', 'eval', expression])
            changes.append(dict(before=new, restored=old))
        stable = stable + 1 if current == expected else 0
        if stable >= 5:
            return changes
        time.sleep(0.1)
    raise RuntimeError('Virtual output did not retain its original geometry')

def atomic(source, target, mode):
    target = Path(target)
    fd, name = tempfile.mkstemp(prefix='.' + target.name + '.performance-', dir=target.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            os.fchmod(out.fileno(), mode)
            out.write(Path(source).read_bytes())
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, target)
    finally:
        Path(name).unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    items = json.loads((B / 'method/linux-staged.json').read_text())
    inactive()
    for item in items:
        assert digest(item['staged']) == item['sha256'], item['staged']
        assert digest(item['target']) == item['before'], item['target']
    assert digest(CONFIG) == 'c92f91009096e8d2d74cb96ed1167ea0e4a73c41074d2f7568f71a2b0c973a3d'
    initial = dict(windows=windows('Check'), geometry=geometry(), config_hash=digest(CONFIG),
                   plugins=run(['hyprctl', 'plugin', 'list']))
    run([items[0]['staged'], 'validate-send', '--config', CONFIG])
    (B / 'method/install-check.json').write_text(json.dumps(initial, indent=2) + '\n')
    if not args.apply:
        print('PASS staged pair, effective configs, inactive main tasks and original files; no installation performed')
        return
    BACKUP.mkdir(mode=0o700, exist_ok=True)
    if not (BACKUP / 'desktop-source.json').exists():
        shutil.copy2(CONFIG, BACKUP / 'desktop-source.json')
    assert digest(BACKUP / 'desktop-source.json') == initial['config_hash']
    for index, item in enumerate(items):
        if item['before'] is not None:
            if not (BACKUP / str(index)).exists():
                shutil.copy2(item['target'], BACKUP / str(index))
            assert digest(BACKUP / str(index)) == item['before']
    if (BACKUP / 'files.json').exists():
        assert json.loads((BACKUP / 'files.json').read_text()) == items
    else:
        (BACKUP / 'files.json').write_text(json.dumps(items, indent=2) + '\n')
    windows_applied = False
    plugin_unloaded = False
    plugin_new_loaded = False
    replaced = []
    try:
        result_windows = windows('Apply')
        windows_applied = True
        inactive()
        run(['hyprctl', 'plugin', 'unload', PLUGIN])
        plugin_unloaded = True
        for index, item in enumerate(items):
            atomic(item['staged'], item['target'], item['mode'])
            replaced.append(index)
            assert digest(item['target']) == item['sha256'], item['target']
        run(['hyprctl', 'plugin', 'load', PLUGIN])
        plugin_new_loaded = True
        geometry_corrections = restore_virtual_geometry(initial['geometry'])
        for entry in ['window_stream_start', 'window_stream_start_commit', 'window_stream_stop']:
            assert run(['hyprctl', 'repl', f'return type(hl.plugin.viewflow_capture.{entry})']).strip() == 'function'
        assert not run(['hyprctl', 'configerrors']).strip()
        mode = json.loads(run(['python3', ROOT / 'tools/viewflow-performance.py', 'set', 'latency']))
        assert mode['changed'] and not mode['restarted']
        assert json.loads(CONFIG.read_text()) == dict(json.loads((BACKUP / 'desktop-source.json').read_text()), performance_mode='latency')
        assert geometry() == initial['geometry']
        inactive()
        result = dict(windows=result_windows, linux=[dict(path=i['target'], hash=digest(i['target'])) for i in items],
                      config_hash=digest(CONFIG), mode=json.loads(run(['python3', ROOT / 'tools/viewflow-performance.py', 'status'])),
                      backup=str(BACKUP), geometry_unchanged=True, configerrors='',
                      geometry_corrections=geometry_corrections,
                      main_services_started=False, live_stream_acceptance=False)
        (B / 'method/installed.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    except Exception:
        if plugin_new_loaded:
            run(['hyprctl', 'plugin', 'unload', PLUGIN])
        for index in reversed(replaced):
            item = items[index]
            if item['before'] is None:
                Path(item['target']).unlink(missing_ok=True)
            else:
                atomic(BACKUP / str(index), item['target'], item['mode'])
        atomic(BACKUP / 'desktop-source.json', CONFIG, (BACKUP / 'desktop-source.json').stat().st_mode & 0o777)
        if plugin_unloaded:
            run(['hyprctl', 'plugin', 'load', PLUGIN])
            restore_virtual_geometry(initial['geometry'])
        if windows_applied:
            windows('Rollback')
        raise

if __name__ == '__main__':
    main()
