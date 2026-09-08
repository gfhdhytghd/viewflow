from pathlib import Path
import subprocess,base64,os,re,json
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 s="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; "+s
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30)
 print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode();return r.stdout.decode(errors='replace')
def copy(n):subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+root.replace('\\','/')+'/'+n,'/tmp/viewflow-'+n],check=True)
filtered=started=False
try:
 status=ps('pktmon status; pktmon filter list')
 assert '没有运行' in status and '无' in status
 ps('pktmon filter add ViewflowProbe49101 -t UDP -p 49101; exit $LASTEXITCODE');filtered=True
 ps("pktmon start --capture --comp all --pkt-size 64 --file-size 32 --file-name '"+root+"\\probe-port-only.etl'; exit $LASTEXITCODE");started=True
 subprocess.run(['python3','/tmp/viewflow-run-udp-burst.py','pktmon-port-only'],env=dict(os.environ,VIEWFLOW_PROBE_PORT='49101',VIEWFLOW_PROBE_PAIRS='2'),check=True)
finally:
 if started:ps('pktmon stop; exit $LASTEXITCODE')
 if filtered:ps('pktmon filter remove ViewflowProbe49101; exit $LASTEXITCODE')
ps("pktmon etl2txt '"+root+"\\probe-port-only.etl' --out '"+root+"\\probe-port-only.txt' --timestamp --verbose; exit $LASTEXITCODE")
for n in ['probe-port-only.etl','probe-port-only.txt']:copy(n)
s=Path('/tmp/viewflow-probe-port-only.txt').read_text(encoding='utf-16')
print('directions', {k:len(re.findall(r' '+k+r' ',s)) for k in ['Rx','Tx']})
Path('/tmp/viewflow-probe-port-only-utf8.txt').write_text(s)
ps('pktmon status; pktmon filter list')
