from pathlib import Path
import subprocess,base64,sys
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();name=sys.argv[1] if len(sys.argv)>1 else 'probe-ndis';port=sys.argv[2] if len(sys.argv)>2 else '49101'
assert all(c.isalnum() or c=='-' for c in name) and port in ['49073','49101']
if len(sys.argv)<=1:subprocess.run(['scp','-q','-r','-o','BatchMode=yes','/tmp/viewflow-ndis-reader-publish','wilf@172.16.105.70:'+root.replace('\\','/')+'/'],check=True)
s="Set-Location '"+root+"'; & .\\viewflow-ndis-reader-publish\\reader.exe '"+name+".etl' '"+name+".jsonl' '"+port+"'; exit $LASTEXITCODE"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=120);print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode()
for n in [name+'.jsonl',name+'.jsonl.summary.json']:subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+root.replace('\\','/')+'/'+n,'/tmp/viewflow-'+n],check=True)
