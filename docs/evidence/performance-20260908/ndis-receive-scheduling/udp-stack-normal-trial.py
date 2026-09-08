from pathlib import Path
import subprocess,base64,os,hashlib,json
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
def ps(s):
 s="$ProgressPreference='SilentlyContinue'; $OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $ErrorActionPreference='Stop'; "+s
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True)
 print(r.stdout.decode(errors='replace'),flush=True);r.check_returncode();return r.stdout.decode(errors='replace')
paths=['target/release/vf-media-peer','crates/viewflowd/src/atlas_socket_trace.rs','platform/nvenc-encoder/gpu_dmabuf_encoder.cu'];Path('/tmp/viewflow-udp-stack-normal-trial-source-sha256.json').write_text(json.dumps({p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in paths},indent=2)+'\n')
started=False
try:
 status=ps('wpr -status; exit 0');assert 'WPR is not recording' in status
 ps("wpr -start '"+root+"\\udp-stack.wprp!ViewflowUdpStack'; exit $LASTEXITCODE");started=True
 env=dict(os.environ,VIEWFLOW_OBSERVE_FRAMES='0',VIEWFLOW_ALPHA_COPY_PROFILE='1',VIEWFLOW_ALPHA_OUTPUT_COPY='0',VIEWFLOW_TRIAL_GPU_TIMINGS='all',VIEWFLOW_GPU_TILE_COPY='0',VIEWFLOW_QUIC_POLL='0',VIEWFLOW_QUIC_SOCKET_TRACE='1');env.pop('VIEWFLOW_QUIC_BURST_PACKETS',None)
 subprocess.run(['python3','/tmp/viewflow-full-resolution-trial.py','4k-udp-stack-normal'],env=env,check=True)
finally:
 if started:ps("wpr -stop '"+root+"\\udp-stack-normal.etl'; exit $LASTEXITCODE")
ps('wpr -status; exit 0')
subprocess.run(['python3','/tmp/viewflow-run-udp-stack-normal-reader.py'],check=True)
