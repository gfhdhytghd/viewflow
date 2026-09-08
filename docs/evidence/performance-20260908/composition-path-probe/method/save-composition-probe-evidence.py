from pathlib import Path
import json,shutil,gzip,hashlib
out=Path('docs/evidence/performance-20260908/composition-path-probe');method=out/'method'
for n in ['composition-probe-state.json','composition-toggle-state.json','composition-toggle-controls.log','composition-toggle-analysis.log','analyze-composition-startup.py','composition-startup-analysis.log','composition-probe-final-state.py','composition-probe-final-state.json','composition-probe-cmake-build.log','composition-probe-cmake-path-failure.log','build-composition-probe-cmake.py','restore-composition-probe.ps1','restore-composition-toggle.ps1','save-composition-probe-evidence.py']:
 shutil.copy2('/tmp/viewflow-'+n,method/n)
raw=out/'runs';raw.mkdir(exist_ok=True)
for p in sorted(Path('/tmp/viewflow-composition-latency-probe').glob('*')):
 if p.name.endswith(('-probe.log','-desktop.log','-pairs.json')):
  (raw/(p.name+'.gz')).write_bytes(gzip.compress(p.read_bytes(),mtime=0))
 else:shutil.copy2(p,raw/p.name)
for n in ['profile_atlas_timeline.py','summarize_desktop_markers.py','windows_frame_observer.cpp']:
 shutil.copy2(Path('tools')/n,method/n)
# Keep the existing production binary ledgers used in the fresh restoration audit.
for n in ['trace-controls-binaries.json','nowait-binaries.json','before-commit-cadence-sha256.json']:
 shutil.copy2('/tmp/viewflow-'+n,method/n)
# Config snapshots may contain pairing data. Only keep their hashes in this public evidence tree.
config_hashes={}
for n in ['codec-restore-send.json','codec-restore-receive.json','codec-restore-receive-remote.json']:
 p=Path('/tmp/viewflow-'+n);config_hashes[n]=hashlib.sha256(p.read_bytes()).hexdigest()
(method/'original-config-sha256.json').write_text(json.dumps(config_hashes,indent=2)+'\n')
print('saved raw runs, paired records, controls and source dependencies')
