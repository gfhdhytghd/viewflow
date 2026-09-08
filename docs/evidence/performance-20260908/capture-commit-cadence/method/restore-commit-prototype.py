from pathlib import Path
import json,hashlib
base=Path('docs/evidence/performance-20260908/capture-commit-cadence');record={}
original=json.loads(Path('/tmp/viewflow-before-commit-cadence-sha256.json').read_text())
for n in ['platform/viewflow-capture/src/main.cpp','platform/viewflow-capture/CMakeLists.txt']:
 p=Path(n);frozen=base/'source-prototype'/n
 assert p.read_bytes()==frozen.read_bytes(),n
 old=Path('/tmp/viewflow-before-commit-cadence-'+p.name).read_bytes();assert hashlib.sha256(old).hexdigest()==original[n]
 p.write_bytes(old);record[n]=hashlib.sha256(p.read_bytes()).hexdigest()
for n in ['platform/viewflow-capture/src/capture_commit_schedule.hpp','platform/viewflow-capture/tests/capture_commit_schedule_test.cpp']:
 p=Path(n);assert p.read_bytes()==(base/'source-prototype'/n).read_bytes();p.unlink();record[n]='removed; retained only in source-prototype evidence'
for n,h in original.items():assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h,n
record['all_six_original_hashes_verified']=True
Path('/tmp/viewflow-commit-cadence-production-restored.json').write_text(json.dumps(record,indent=2)+'\n')
print('prototype source restored; renderer, loaded capture plugin and Linux media binary unchanged')
