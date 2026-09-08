from pathlib import Path
import subprocess,base64,json
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
for i in [1,2,3]:subprocess.run(['scp','-q','-o','BatchMode=yes',f'/tmp/viewflow-atlas-growth-fixture/color-{i}.av1','wilf@172.16.105.70:'+root.replace(chr(92),'/')+f'/color-{i}.av1'],check=True)
s="$ErrorActionPreference='Stop';$r='"+root+"';& ($r+'\\native-av1-build\\Release\\viewflow_atlas_growth_gpu_test.exe') $r;exit $LASTEXITCODE"
p=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=90);Path('/tmp/viewflow-av1-presenter-gpu-test.log').write_bytes(p.stdout+p.stderr);print(p.returncode,p.stdout.decode(errors='replace'),p.stderr.decode(errors='replace'));p.check_returncode()
