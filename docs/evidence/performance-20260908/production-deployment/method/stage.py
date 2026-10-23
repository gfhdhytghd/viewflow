"""Stage the qualified pair; do not replace installed files or start services."""
from pathlib import Path
import base64
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path('/home/wilf/data/viewflow')
B = Path(__file__).resolve().parent.parent
STAGE = Path('/tmp/viewflow-performance-deployment')
STAGE.mkdir(exist_ok=True)
STAGE.chmod(0o700)
preflight = json.loads((STAGE / 'preflight.json').read_text())

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

for name, old in preflight.items():
    if name.startswith('/'):
        assert digest(name) == old['sha256'], name
for name, value in preflight['candidates'].items():
    assert digest(name) == value, name

files = [
    (ROOT / 'target/release/vf-media-peer', Path('/home/wilf/.local/lib/viewflow/desktop/vf-media-peer-main')),
    (Path('/tmp/viewflow-performance-production-build/viewflow-capture.so'), ROOT / 'build/desktop/capture/viewflow-capture.so'),
    (ROOT / 'tools/quickshell/ViewflowPerformanceControl.qml', Path('/home/wilf/.config/HyprV/quickshell/ViewflowPerformanceControl.qml')),
    (ROOT / 'tools/quickshell/viewflow-performance.sh', Path('/home/wilf/.config/HyprV/quickshell/scripts/viewflow-performance.sh')),
]
popup = Path('/home/wilf/.config/HyprV/quickshell/ControlPanelPopup.qml')
text = popup.read_text()
anchor = '''                    Row {
                        width: parent.width
                        spacing: popupRoot.cardSpacing

                        ControlPanelToggle {
                            width: (parent.width - popupRoot.cardSpacing) / 2
                            height: popupRoot.moduleSize
                            shellRoot: popupRoot.shellRoot
                            icon: "󰻃"'''
assert text.count(anchor) == 1 and 'ViewflowPerformanceControl {' not in text
block = '''                    ViewflowPerformanceControl {
                        width: parent.width
                        buttonHeight: popupRoot.moduleSize
                        cardSpacing: popupRoot.cardSpacing
                        shellRoot: popupRoot.shellRoot
                    }

'''
candidate = STAGE / 'ControlPanelPopup.qml'
candidate.write_text(text.replace(anchor, block + anchor))
files.append((candidate, popup))
items = []
for index, (source, target) in enumerate(files):
    staged = STAGE / f'file-{index}'
    shutil.copy2(source, staged)
    items.append(dict(source=str(source), staged=str(staged), target=str(target),
                      sha256=digest(staged), before=digest(target) if target.exists() else None,
                      mode=target.stat().st_mode & 0o777 if target.exists() else source.stat().st_mode & 0o777))
(B / 'method/linux-staged.json').write_text(json.dumps(items, indent=2) + '\n')

audit = json.loads((B.parent / 'production-pair/method/build-audit.json').read_text())
expected = audit['binaries'][:2] + audit['dlls']
encoded = base64.b64encode(json.dumps(expected).encode()).decode()
script = r'''$ErrorActionPreference='Stop'
$items=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ITEMS__'))|ConvertFrom-Json
$stage='C:\Users\wilf\Viewflow\performance-stage-20260909'
New-Item -ItemType Directory -Force -Path $stage|Out-Null
$result=@()
foreach($item in $items) {
  if((Get-FileHash -LiteralPath $item.Path).Hash -ne $item.Hash) {throw 'candidate changed'}
  $name=[IO.Path]::GetFileName($item.Path)
  $destination=Join-Path $stage $name
  Copy-Item -LiteralPath $item.Path -Destination $destination -Force
  if((Get-FileHash -LiteralPath $destination).Hash -ne $item.Hash) {throw 'staged hash mismatch'}
  $installed=Join-Path 'C:\Users\wilf\Viewflow\desktop-test' $name
  $before=$null
  if(Test-Path -LiteralPath $installed){$before=(Get-FileHash -LiteralPath $installed).Hash}
  $result+=[pscustomobject]@{source=$item.Path;staged=$destination;target=$installed;sha256=$item.Hash;before=$before}
}
& (Join-Path $stage 'vf-media-peer.exe') validate-receive --config 'C:\Users\wilf\Viewflow\desktop-test\receive.json' 1>$null
if($LASTEXITCODE -ne 0){throw 'production receive configuration validation failed'}
$result|ConvertTo-Json -Depth 4
'''.replace('__ITEMS__', encoded)
(B / 'method/stage-windows.ps1').write_text(script)
subprocess.run(['scp', '-q', str(B / 'method/stage-windows.ps1'),
                'wilf@172.16.105.70:Viewflow/performance-stage-20260909.ps1'], check=True, timeout=30)
run = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                      'wilf@172.16.105.70', 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                      r'C:\Users\wilf\Viewflow\performance-stage-20260909.ps1'],
                     capture_output=True, timeout=90)
if run.returncode:
    raise RuntimeError(run.stderr.decode(errors='replace'))
windows = json.loads(run.stdout)
assert len(windows) == 9
(B / 'method/windows-staged.json').write_text(json.dumps(windows, indent=2) + '\n')
subprocess.run([str(STAGE / 'file-0'), 'validate-send', '--config',
                '/home/wilf/.config/viewflow/desktop-source.json'], check=True)
print('PASS staged five Linux files and nine Windows binaries/DLLs; installed files unchanged')
