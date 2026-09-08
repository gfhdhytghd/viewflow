from pathlib import Path
import subprocess,base64,os,re,json
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 s="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; "+s
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=30)
 print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode();return r.stdout.decode(errors='replace')
def copy(n):subprocess.run(['scp','-q','-o','BatchMode=yes','wilf@172.16.105.70:'+root.replace('\\','/')+'/'+n,'/tmp/viewflow-'+n],check=True)
started=False
try:
 status=ps('wpr -status'); assert 'WPR is not recording' in status
 subprocess.run(['scp','-q','-o','BatchMode=yes','/tmp/viewflow-network-only.wprp','wilf@172.16.105.70:'+root.replace('\\','/')+'/network-only.wprp'],check=True)
 ps("wpr -start '"+root+"\\network-only.wprp!ViewflowNetwork'; exit $LASTEXITCODE");started=True
 subprocess.run(['python3','/tmp/viewflow-run-udp-burst.py','wpr-network'],env=dict(os.environ,VIEWFLOW_PROBE_PORT='49101',VIEWFLOW_PROBE_PAIRS='2'),check=True)
finally:
 if started:ps("wpr -stop '"+root+"\\probe-wpr-network.etl'; exit $LASTEXITCODE")
ps("pktmon etl2txt '"+root+"\\probe-wpr-network.etl' --out '"+root+"\\probe-wpr-network.txt' --timestamp --verbose; exit $LASTEXITCODE")
for n in ['probe-wpr-network.etl','probe-wpr-network.txt']:copy(n)
ps('wpr -status')
