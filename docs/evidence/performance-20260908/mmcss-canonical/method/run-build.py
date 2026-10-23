from pathlib import Path
import subprocess,sys,base64
b=Path(__file__).resolve().parent.parent
kind=sys.argv[1];assert kind in ['native','receiver']
root=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\mmcss-canonical-20260909'
s="Set-Location '"+root+"';cmd.exe /d /c 'build-"+kind+".cmd > build-"+kind+".log 2>&1';$code=$LASTEXITCODE;Get-Content ('build-"+kind+".log');exit $code"
r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=600)
(b/('method/build-'+kind+'.log')).write_bytes(r.stdout+r.stderr)
print(kind,'exit',r.returncode,flush=True);print((r.stdout+r.stderr).decode(errors='replace')[-3000:],flush=True)
raise SystemExit(r.returncode)
