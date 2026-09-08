from pathlib import Path
import hashlib,json,subprocess
out=Path('docs/evidence/performance-20260908/binary-alpha-backdrop');before=Path('/tmp/viewflow-binary-backdrop-initial-source');base=Path('platform/windows-composition-preview')
ledger=json.loads(Path('/tmp/viewflow-binary-backdrop-build-success.json').read_text())['source_hashes']
files=['main.cpp','sparse_opaque.h','sparse_opaque_test.cpp','atlas_frame_bindings.h','atlas_frame_bindings_test.cpp']
for n in files+['CMakeLists.txt','sparse_binary_backdrop_test.cpp']:
 assert hashlib.sha256((base/n).read_bytes()).hexdigest()==ledger[str(base/n)],n
 assert (base/n).read_bytes()==(out/'source-tested'/base/n).read_bytes(),n
current=(base/'CMakeLists.txt').read_text();prior=Path('docs/evidence/performance-20260908/composition-path-probe/toggle-source/platform/windows-composition-preview/CMakeLists.txt').read_text()
start=current.index('# Manual oracle for binary alpha backdrop elision and transform fallbacks.')
end=current.index('\n\n',current.index('target_link_libraries(viewflow_sparse_binary_backdrop_test',start))
assert current[:start]+current[end+2:]==prior
for n in files:(base/n).write_bytes((before/n).read_bytes())
(base/'CMakeLists.txt').write_text(prior)
(base/'sparse_binary_backdrop_test.cpp').unlink()
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
for n in files+['CMakeLists.txt']:
 subprocess.run(['scp','-q','-o','BatchMode=yes',str(base/n),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+str(base/n)],check=True)
# The isolated oracle EXE and exact tested source snapshot remain as evidence.
data={str(base/n):hashlib.sha256((base/n).read_bytes()).hexdigest() for n in files+['CMakeLists.txt']}
Path('/tmp/viewflow-binary-backdrop-production-restored.json').write_text(json.dumps(data,indent=2)+'\n');print('restored five production/test files and original CMake target list; tested prototype retained in evidence')
