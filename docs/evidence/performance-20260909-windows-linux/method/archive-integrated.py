"""Validate and describe the integrated-candidate evidence, without rerunning it."""
from pathlib import Path
import base64
import hashlib
import json
import subprocess

b = Path(__file__).resolve().parent.parent
root = b.parents[2]


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def read(p):
    return json.loads(p.read_text())


def write(p, data):
    p.write_text(json.dumps(data, indent=2) + '\n')


descriptions = {
    'capture-changes': ('Skip unchanged capture versions',
        'The tracker compares capture versions and all tile metadata fields. It commits only accepted submissions; a later capture remains pending. Unchanged scenes receive a periodic one-second refresh and requested keyframes bypass skipping. Neither interval terminates a session. The dedicated tracker test passes. The standalone run decodes all 958 frames with exact opaque alpha and records 32.866 distinct frames/s; this excludes live transport. The subsequent lifecycle probe exposed resize and closed-handle defects, so this prototype was not installed. See ../lifecycle/README.md and ../integrated-candidate/README.md.'),
    'integrated-candidate': ('Direct submission, render alpha summary and lifecycle recovery',
        'This candidate combines owned-source direct submission, render-first exact alpha summary and optional capture-version skipping. The capture callback still copies borrowed WGC data into an application-owned texture. It also recovers a resized source that produces no follow-up frame after 500 ms and omits invalid closed-window metadata. Recovery restarts only that capture while retaining the source texture and parent session. Its 39-file build and tracker test pass. The four integrated full-chain trials vary only capture skipping: enabled achieves 32.795–33.211 distinct FPS versus 30.974–31.266 disabled; latency intervals overlap. No 60 ms result is claimed. See ../transport/README.md and ../lifecycle-v2/README.md. No standalone source run is claimed for this exact build, and no installed reverse executable was replaced.'),
    'lifecycle': ('Preserved failing lifecycle experiment',
        'An owned, nonactivating layered-window fixture changes title, moves, adds another window, resizes, hides and destroys windows. With capture-changes, the initial probe fails on a closed handle published with fallback title Windows and zero geometry. The resized first window also remains at its old captured size. Raw failure logs and diagnostic metadata are retained. These failures led to the fixes tested in ../lifecycle-v2/README.md. Native and fixture exit normally; the GPU semantic probe failure must not be interpreted as a passing runtime qualification.'),
    'lifecycle-v2': ('Passing lifecycle and exact-alpha regression',
        'The same owned-window sequence, with additional actual Win32 rectangle logging, exercises the integrated candidate. All 21 frames pass Linux NVDEC/CUDA/GLES decoding and every alpha byte, including atlas padding. Coverage includes title, movement, two windows, resize, hide and destruction, and both direct and atlas-copy paths. Atlas sizes change from 256×192 to 384×192 to 448×256. Exactly one pending-resize recovery occurs. Foreground-window samples remain unchanged. This is recorded-source-to-GPU qualification, not live Wayland lifecycle or physical-input acceptance. Phase timestamps are logged after Win32 actions: signed differences in summary.json are diagnostic and are not action-to-output latency. The resized frame includes roughly 1.08 seconds of recovery and encoder reinitialization, separate from steady 6K latency.'),
    'candidate-quality': ('Matched full-frame synthetic RGB comparison',
        'The same 90 common marker IDs are decoded from each of four streams; every one of 21,233,664 RGB pixels per frame is compared with the exact fixture shader using the first encoded occurrence. Aggregate PSNR is 41.871488 dB for mft-speed0, 41.871363 for direct-source-stop, 41.870557 for capture-changes and 41.871362 for alpha-summary-render. All four probes exit normally and validate opaque alpha. This establishes comparable error on this synthetic grid, not lossless output or fidelity on natural images and text. Inputs, helper source/binary hashes, chosen markers and per-frame results are preserved in method/.'),
    'root-lifecycle': ('Canonical lifecycle fixes and Windows build',
        'Canonical source tracks expected capture dimensions and retries only a stuck resized capture after 500 ms, retaining its last texture. It validates HWND ownership and positive geometry before publishing metadata and rechecks ownership after reading the title. This prevents the reproduced closed-handle metadata frame. The 31 build inputs match the canonical workspace at archival time and the Windows stage; all four existing Windows CTests pass. The 21-frame runtime regression uses the separate integrated candidate with the same lifecycle fix, not this canonical binary. Performance features and reverse modes have not yet been integrated into this build. The installed reverse binary is unchanged.'),
    'deployment-inspection': ('Read-only reverse deployment inspection',
        'Selected live configuration fields show that reverse source/presenter processes are already configured within the ordinary paired main connection. The Windows main scheduled task was Ready at inspection. The current controller provides forward performance modes; reverse mode integration remains pending. JSON snapshots contain selected executable paths, arguments, hashes and task state, not TLS private-key contents. This snapshot does not establish that a reverse stream was running.')
}

for name in ['capture-changes', 'integrated-candidate', 'root-lifecycle']:
    p = b / name
    m = read(p / 'method/source-sha256.json')
    assert m == read(p / 'method/remote-source-sha256.json')
    assert all(digest(p / 'source' / k) == h for k, h in m.items())
    if name == 'root-lifecycle':
        assert all(digest(root / k) == h for k, h in m.items())
        assert '100% tests passed, 0 tests failed out of 4' in (p / 'method/build.log').read_text()
    else:
        assert '100% tests passed, 0 tests failed out of 1' in (p / 'method/build.log').read_text()

for name in ['lifecycle', 'lifecycle-v2']:
    p = b / name
    m = read(p / 'method/windows-source-sha256.json')
    assert m == read(p / 'method/windows-remote-source-sha256.json')
    assert all(digest(p / k) == h for k, h in m.items())
    for f in (p / 'source/platform').rglob('*'):
        if f.is_file():
            assert f.read_bytes() == (b / 'lifecycle/source/platform' / f.relative_to(p / 'source/platform')).read_bytes()

assert read(b / 'lifecycle-v2/summary.json')['qualified']
s = read(b / 'capture-changes/summary.json')
assert s['run_qualified'] and s['marker_validation']['decoded'] == s['source_frames'] == 958
q = read(b / 'candidate-quality/method/inputs.json')
assert digest(b / 'candidate-quality/method/quality-probe-used.cpp') == q['source_sha256']
assert digest(Path(q['probe'])) == q['probe_sha256']
for name, h in q['inputs'].items():
    assert digest(b / name / 'runs/stream.vfrv') == h

# Record the canonical build output identity without importing its staging script.
remote = r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\reverse-root-lifecycle-20260909\build\Release'
script = "$ErrorActionPreference='Stop';Get-ChildItem '" + remote + "' -Filter *.exe|ForEach-Object{[pscustomobject]@{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash}}|ConvertTo-Json"
r = subprocess.run(['ssh', '-o', 'BatchMode=yes', 'wilf@172.16.105.70',
    'powershell', '-NoProfile', '-EncodedCommand',
    base64.b64encode(script.encode('utf-16le')).decode()],
    capture_output=True, check=True, timeout=30)
write(b / 'root-lifecycle/method/build-binaries.json', json.loads(r.stdout))

for name, (title, body) in descriptions.items():
    p = b / name
    (p / 'README.md').write_text(f'# {title}\n\n2026-09-09. {body}\n\nSource, methods and raw observations are retained beside this report. `sha256.json` covers all archived files except itself.\n')
    files = sorted(f for f in p.rglob('*') if f.is_file() and '__pycache__' not in f.parts and f != p / 'sha256.json')
    write(p / 'sha256.json', {str(f.relative_to(p)): digest(f) for f in files})
    print(name, len(files))

print('integrated evidence checks passed')
