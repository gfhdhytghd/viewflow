from pathlib import Path
import gzip,hashlib,json
b=Path(__file__).resolve().parent.parent
old=b.parent/'import-cache-hyperv-ddc'
base=json.loads((old/'method/candidate-source-sha256.json').read_text())
current=json.loads((b/'method/source-sha256.json').read_text())
changed={n for n in current if current[n]!=base[n]}
assert changed=={'platform/nvenc-encoder/README.md','platform/nvenc-encoder/gpu_dmabuf_encoder.cu'}
for name,digest in current.items():
    file=b/'source'/Path(name).name if name in changed else old/'source-tree'/name
    assert hashlib.sha256(file.read_bytes()).hexdigest()==digest,name
before=(old/'source-tree/platform/nvenc-encoder/gpu_dmabuf_encoder.cu').read_text()
expected=before.replace('bool cacheImports = false;','bool cacheImports = true;').replace('cacheImports = importCache && std::strcmp(importCache, "1") == 0;','// Retain registrations by default; the diagnostic override can bypass them.\n    cacheImports = !importCache || !*importCache || std::strcmp(importCache, "1") == 0;')
assert (b/'source/gpu_dmabuf_encoder.cu').read_text()==expected
assert '100% tests passed out of 7' in (b/'method/tests.log').read_text()
assert 'PASS atlas scratch transitions and full alpha 3840x2400' in (b/'method/integration-4k.log').read_text()
state=json.loads((b/'method/prepared-state.json').read_text())
assert state['cache_override_during_tests'] is None
assert state['service_name']=='viewflow-desktop.service' and 'LoadState=loaded' in state['service']
assert 'ActiveState=inactive' in state['service']
assert 'vf-media-peer-main' in state['service']
assert set(state['built'].values()).isdisjoint(state['installed'].values())
assert len(state['installed'])==1 and next(iter(state['installed'])) in state['service']
run_bundle=b.parent/'shared-blur-brush'
for p in sorted((run_bundle/'runs').glob('*/state.json')):
    run=json.loads(p.read_text())
    assert run['source_import_cache_override'] is None and run['source_exit']==124
    for path,digest in state['built'].items():assert run['linux_binaries'][path]==digest
    raw=gzip.decompress((p.parent/'source.log.gz').read_bytes()).decode(errors='replace')
    cache=[dict(v.split('=',1) for v in line.split()[2:]) for line in raw.splitlines() if line.startswith('GPU import-cache ')]
    assert cache and all(r['enabled']=='1' and int(r['entries'])<=4 for r in cache)
    assert int(cache[-1]['hits'])>3000
assert len(list((run_bundle/'runs').glob('*/state.json')))==4
manifest=json.loads((b/'sha256.json').read_text())
for name,digest in manifest.items():assert hashlib.sha256((b/name).read_bytes()).hexdigest()==digest,name
print('PASS default-cache source delta, build identity, GPU tests, four implicit-default runs and',len(manifest),'hashes; deployment remains pending')
