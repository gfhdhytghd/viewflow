"""Media selection and bounded synthetic hardware checks; never installs drivers."""
import json
import os
from pathlib import Path
import subprocess

BACKENDS = ('auto', 'nvidia', 'vaapi')


def normalize(backend, node):
    if backend not in BACKENDS:
        raise ValueError('Unknown media backend')
    if not isinstance(node, str) or '\0' in node or (node and not Path(node).is_absolute()):
        raise ValueError('Media render device must be an absolute path')
    return backend, node


def environment(backend, node):
    backend, node = normalize(backend, node)
    # An empty value explicitly clears a stale inherited selection.
    return {'VIEWFLOW_MEDIA_BACKEND': backend, 'VIEWFLOW_MEDIA_RENDER_NODE': node}


def render_devices():
    devices = []
    for entry in sorted(Path('/sys/class/drm').glob('renderD*')):
        node = Path('/dev/dri') / entry.name
        pci = (entry / 'device').resolve()
        def read(name):
            try: return (pci / name).read_text().strip()
            except OSError: return ''
        vendor = read('vendor')
        brand = {'0x10de': 'NVIDIA', '0x1002': 'AMD', '0x8086': 'Intel'}.get(vendor, vendor)
        devices.append({'node': str(node), 'pci': pci.name, 'vendor': vendor, 'device': read('device'),
                        'driver': (pci / 'driver').resolve().name,
                        'accessible': os.access(node, os.R_OK | os.W_OK),
                        'label': f'{brand} · {pci.name} · {node}'})
    return devices


def probe(program, backend, node):
    backend, node = normalize(backend, node)
    args = [str(program), '--backend', backend]
    if node: args += ['--render-node', node]
    try:
        result = subprocess.run(args, capture_output=True, text=True, errors='replace', timeout=45,
                                env=dict(os.environ, **environment(backend, node)))
        report = json.loads(result.stdout)
        if not isinstance(report, dict): raise ValueError('invalid media probe report')
        passed = result.returncode == 0 and report.get('ok') is True and all(
            report.get(field) is True for field in ('hardware_encode', 'hardware_decode', 'egl_import', 'alpha_atlas', 'synthetic_only'))
        passed = passed and report.get('codec') == 'h264' and report.get('frames') == 8 and report.get('backend') in ('nvidia', 'vaapi')
        if backend != 'auto': passed = passed and report.get('backend') == backend
        if node: passed = passed and Path(report.get('render_node', '')).resolve() == Path(node).resolve()
        report['ok'] = passed
        report['diagnostic'] = result.stderr[-8192:]
        if not passed and not report.get('error'): report['error'] = 'Incomplete hardware media proof'
        return report
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return {'ok': False, 'backend': backend, 'render_node': node, 'error': str(error)}
