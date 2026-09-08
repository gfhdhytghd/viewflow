import os,subprocess,sys
children=[]
for name in ['viewflow_windows_frame_observer.exe','viewflow_windows_window_frame_observer.exe']:
 env=dict(os.environ,VIEWFLOW_OBSERVER_EXE=name);env.pop('VIEWFLOW_OBSERVE_BOTH',None)
 children.append((name,subprocess.Popen(['python3','/tmp/viewflow-observe-frames.py',sys.argv[1]],env=env)))
results=[(name,child.wait()) for name,child in children]
print('dual_observer_results',results,flush=True)
raise SystemExit(0 if all(code==0 for _,code in results) else 1)
