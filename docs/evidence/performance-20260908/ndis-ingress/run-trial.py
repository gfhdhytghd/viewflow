from pathlib import Path
import subprocess,base64,os,hashlib,json
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 s="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; "+s
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=240)
 print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode();return r.stdout.decode(errors='replace')
paths=['target/release/vf-media-peer','crates/viewflowd/src/atlas_socket_trace.rs','platform/nvenc-encoder/gpu_dmabuf_encoder.cu'];Path('/tmp/viewflow-ndis-network-trial-source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
started=network=False
try:
 status=ps('wpr -status; netsh trace show status; exit 0');assert 'WPR is not recording' in status and 'no trace session' in status
 ps("netsh trace start capture=yes report=no persistent=no correlation=no maxsize=64 tracefile='"+root+"\\ndis-network.etl' Ethernet.Type=IPv4 Protocol=17 IPv4.SourceAddress=172.16.105.62 'CustomIp=UINT16(22,49073)' PacketTruncateBytes=64 CaptureMultiLayer=yes; exit $LASTEXITCODE");started=True
 ps("wpr -start '"+root+"\\network-only.wprp!ViewflowNetwork'; exit $LASTEXITCODE");network=True
 env=dict(os.environ,VIEWFLOW_OBSERVE_FRAMES='0',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='1')
 subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py','4k-ndis-network'],env=env,check=True)
finally:
 try:
  if network:ps("wpr -stop '"+root+"\\ndis-kernel.etl'; exit $LASTEXITCODE")
 finally:
  if started:ps('netsh trace stop; exit $LASTEXITCODE')
ps('wpr -status; netsh trace show status; exit 0')
subprocess.run(['python3','/tmp/viewflow-run-network-reader.py','ndis-kernel','49073'],check=True)
subprocess.run(['python3','/tmp/viewflow-run-ndis-reader.py','ndis-network','49073'],check=True)
