from pathlib import Path
p=Path('/tmp/viewflow-commit-cadence-trials.py')
s=Path('/tmp/viewflow-capture-ready-trials.py').read_text().replace('RestoreCaptureReady','RestoreCommitCadence').replace('capture-ready','commit-cadence')
s=s.replace("for label,codec,value,capture_events in [('4k-commit-cadence0-minimal-a1','h264','minimal','0'),('4k-commit-cadence1-minimal-b1','h264','minimal','1'),('4k-commit-cadence1-minimal-b2','h264','minimal','1'),('4k-commit-cadence0-minimal-a2','h264','minimal','0')]:", "for label,codec,value,capture_mode in [('4k-commit-grid-minimal-a1','h264','minimal','grid'),('4k-commit-event-minimal-b1','h264','minimal','commit'),('4k-commit-event-minimal-b2','h264','minimal','commit'),('4k-commit-grid-minimal-a2','h264','minimal','grid')]:\n  capture_events='1'")
assert 'for label,codec,value,capture_mode' in s
s=s.replace("'capture_events':capture_events,'before':before", "'capture_events':capture_events,'capture_mode':capture_mode,'before':before")
s=s.replace("env=dict(os.environ,VIEWFLOW_CAPTURE_EVENTS=capture_events,", "env=dict(os.environ,VIEWFLOW_COMMIT_MODE=capture_mode,VIEWFLOW_CAPTURE_EVENTS=capture_events,")
s=s.replace("'/tmp/viewflow-full-resolution-trial.py'", "'/tmp/viewflow-commit-full-resolution-trial.py'")
s=s.replace("'tools/windows_observer_timer.h'];", "'tools/windows_observer_timer.h','platform/viewflow-capture/src/main.cpp','platform/viewflow-capture/src/capture_commit_schedule.hpp','platform/viewflow-capture/src/capture_cadence.hpp','platform/viewflow-capture/CMakeLists.txt','/tmp/viewflow-commit-cadence-build/viewflow-capture-commit-test.so'];")
p.write_text(s)
s=Path('/tmp/viewflow-full-resolution-trial.py').read_text()
s=s.replace("'3386992'", "os.environ['VIEWFLOW_NESTED_COMPOSITOR_PID']")
s=s.replace("s['windows'][0].update", "s['compositor_pid']=int(os.environ['VIEWFLOW_NESTED_COMPOSITOR_PID']);s['windows'][0].update")
Path('/tmp/viewflow-commit-full-resolution-trial.py').write_text(s)
s=Path('/tmp/viewflow-commit-nested-driver.py').read_text()
s=s.replace("subprocess.run(['/usr/bin/python3','/tmp/viewflow-commit-cohort-smoke.py'],env=inner,check=True)","""subprocess.run(['/usr/bin/python3','/tmp/viewflow-commit-cohort-smoke.py'],env=inner,check=True)
 state['smoke']='passed';save()
 inner['VIEWFLOW_NESTED_COMPOSITOR_PID']=str(pid);inner['VIEWFLOW_TRIAL_SCREEN']=screen
 inner['PATH']='/tmp/viewflow-commit-hyprctl-shim:'+inner['PATH']
 subprocess.run(['/usr/bin/python3','/tmp/viewflow-commit-cadence-trials.py'],env=inner,check=True)
 state['ab_trials']='passed'""")
Path('/tmp/viewflow-commit-nested-ab.py').write_text(s)
shim=Path('/tmp/viewflow-commit-hyprctl-shim');shim.mkdir(exist_ok=True,mode=0o700)
f=shim/'hyprctl';f.write_text('''#!/usr/bin/python3
import os,sys
args=sys.argv[1:]
for i,arg in enumerate(args):
 if 'hl.plugin.viewflow_capture.' in arg:
  arg=arg.replace('hl.plugin.viewflow_capture.window_stream_start(', 'hl.plugin.viewflow_capture_commit_test.'+('window_stream_start_commit(' if os.environ.get('VIEWFLOW_COMMIT_MODE')=='commit' else 'window_stream_start('))
  arg=arg.replace('hl.plugin.viewflow_capture.window_stream_stop(', 'hl.plugin.viewflow_capture_commit_test.window_stream_stop(')
  args[i]=arg
os.execv('/usr/bin/hyprctl',['hyprctl',*args])
''');f.chmod(0o700)
s=Path('/tmp/viewflow-summarize-capture-ready.py').read_text().replace("row['capture_events']='-ready1-' in label", "row['capture_events']=True\n row['capture_mode']='commit' if '-event-' in label else 'grid'").replace('viewflow-capture-ready-comparison','viewflow-commit-cadence-comparison')
Path('/tmp/viewflow-summarize-commit-cadence.py').write_text(s)
