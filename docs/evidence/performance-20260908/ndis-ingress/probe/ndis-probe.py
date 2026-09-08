from pathlib import Path
import subprocess,base64,os
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 s="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; "+s
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=60)
 print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode();return r.stdout.decode(errors='replace')
started=False
try:
 status=ps('netsh trace show status; exit 0');assert 'no trace session' in status
 ps("netsh trace start capture=yes report=no persistent=no correlation=no maxsize=32 tracefile='"+root+"\\probe-ndis.etl' Ethernet.Type=IPv4 Protocol=17 IPv4.SourceAddress=172.16.105.62 'CustomIp=UINT16(22,49101)' PacketTruncateBytes=64 CaptureMultiLayer=yes; exit $LASTEXITCODE");started=True
 subprocess.run(['python3','/tmp/viewflow-run-udp-burst.py','ndis'],env=dict(os.environ,VIEWFLOW_PROBE_PORT='49101',VIEWFLOW_PROBE_PAIRS='2'),check=True)
finally:
 if started:ps('netsh trace stop; exit $LASTEXITCODE')
ps('netsh trace show status; exit 0')
