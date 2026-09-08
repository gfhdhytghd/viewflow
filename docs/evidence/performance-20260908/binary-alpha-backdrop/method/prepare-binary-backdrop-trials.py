from pathlib import Path
import json
s=Path('/tmp/viewflow-commit-cadence-trials.py').read_text().replace('RestoreCommitCadence','RestoreBinaryBackdrop').replace('commit-cadence-state.json','binary-backdrop-state.json').replace('restore-commit-cadence.ps1','restore-binary-backdrop.ps1')
start=s.index(" paths=['crates/");end=s.index('\n for label,',start)
paths=['crates/viewflowd/src/atlas_source.rs','crates/viewflowd/src/gpu_atlas_capture.rs','crates/viewflowd/src/gpu_atlas_device.rs','crates/viewflowd/src/gpu_atlas_session.rs','crates/viewflowd/src/hyprcapture_gpu_socket.rs','platform/windows-composition-preview/main.cpp','platform/windows-composition-preview/sparse_opaque.h','platform/windows-composition-preview/atlas_frame_bindings.h','platform/windows-composition-preview/sparse_shared_visuals.h','platform/windows-video-compositor/gpu_timestamp_probe.h','target/release/vf-media-peer','tools/windows_frame_observer.cpp','tools/windows_observer_timer.h','platform/viewflow-capture/src/main.cpp','platform/viewflow-capture/src/capture_cadence.hpp','platform/viewflow-capture/CMakeLists.txt']
s=s[:start]+" paths="+repr(paths)+";Path('/tmp/viewflow-binary-backdrop-trial-source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\\n')"+s[end:]
s=s.replace("for label,codec,value,capture_mode in [('4k-commit-grid-minimal-a1','h264','minimal','grid'),('4k-commit-event-minimal-b1','h264','minimal','commit'),('4k-commit-event-minimal-b2','h264','minimal','commit'),('4k-commit-grid-minimal-a2','h264','minimal','grid')]:", "for label,codec,value,disabled in [('4k-binary-disabled-a1','h264','minimal','1'),('4k-binary-enabled-b1','h264','minimal','0'),('4k-binary-enabled-b2','h264','minimal','0'),('4k-binary-disabled-a2','h264','minimal','1')]:")
s=s.replace('native-trace-controls-build','native-binary-backdrop-build').replace("'capture_mode':capture_mode","'binary_backdrop_disabled':disabled").replace('VIEWFLOW_COMMIT_MODE=capture_mode,','VIEWFLOW_TRIAL_BINARY_BACKDROP_DISABLED=disabled,').replace('/tmp/viewflow-commit-full-resolution-trial.py','/tmp/viewflow-binary-full-resolution-trial.py')
s=s.replace("  assert 'atlas-native-mutation ' in receiver", "  nodes=[line for line in receiver.splitlines() if line.startswith('atlas-sparse-nodes ')];assert nodes and all('binary_alpha=1' in line and 'backdrop_muted='+('0' if disabled=='1' else '1') in line for line in nodes),nodes[:3]\n  assert 'atlas-native-mutation ' in receiver")
# Verify successful native build and source content before changing ESRV/configs.
pos=s.index('initial=json.loads(')
preflight="""expected=json.loads(Path('/tmp/viewflow-binary-backdrop-build-success.json').read_text())
for n,h in expected['source_hashes'].items():assert hashlib.sha256(Path(n).read_bytes()).hexdigest()==h,n
for entry in expected['hashes']:
 actual=ps("(Get-FileHash '"+entry['Path']+"').Hash").strip();assert actual==entry['Hash'],entry['Path']
"""
s=s[:pos]+preflight+s[pos:]
Path('/tmp/viewflow-binary-backdrop-trials.py').write_text(s)
