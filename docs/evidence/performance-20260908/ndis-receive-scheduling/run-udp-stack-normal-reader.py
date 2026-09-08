from pathlib import Path
import subprocess,base64
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
s="Set-Location '"+root+"'; & .\\udp-stack-reader\\reader.exe 'udp-stack-normal.etl' 'udp-stack-normal.jsonl' '49073'; exit $LASTEXITCODE"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True);print(r.stdout.decode(errors='replace'),flush=True);print(r.stderr.decode(errors='replace'),flush=True);r.check_returncode()
for n in ['udp-stack-normal.jsonl','udp-stack-normal.jsonl.summary.json']:subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+root.replace('\\','/')+'/'+n,'/tmp/viewflow-'+n],check=True)
