from pathlib import Path
s=Path('/tmp/viewflow-capture-ready-final-state.py').read_text().replace('RestoreCaptureReady','RestoreCommitCadence')
a=s.index('final_source={}');b=s.index("Path('/tmp/viewflow-capture-ready-final-state.json')",a)
s=s[:a]+'''final_source={}
for n,d in json.loads(Path('/tmp/viewflow-commit-cadence-trial-source-sha256.json').read_text()).items():
 current=Path(n).read_bytes();assert hashlib.sha256(current).hexdigest()==d,n
 final_source[n]=d
v['trial_source_and_binaries_sha256']=final_source
v['post_trial_source_change']='none'
'''+s[b:]
s=s.replace('viewflow-capture-ready-final-state.json','viewflow-commit-cadence-final-state.json').replace('Linux event implementation retained with final test feature guard','Linux binary and prototype source unchanged through all trials')
Path('/tmp/viewflow-commit-cadence-final-state.py').write_text(s)
