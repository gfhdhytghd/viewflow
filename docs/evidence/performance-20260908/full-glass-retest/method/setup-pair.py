from pathlib import Path
import tempfile,uuid,subprocess,json,os,base64,hashlib
os.umask(0o077)
marker=Path('/tmp/viewflow-full-glass-work.json')
if marker.exists():raise RuntimeError('existing retest workspace; inspect before reuse')
local=Path(tempfile.mkdtemp(prefix='viewflow-full-glass-'))
base=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc';remote=base+'\\'+local.name
info={'local':str(local),'remote':remote,'base':base};marker.write_text(json.dumps(info,indent=2)+'\n')
def run(*args):subprocess.run(args,check=True,stdout=subprocess.DEVNULL)
def ps(code):
 s="$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+code
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=40)
 if r.returncode:raise RuntimeError((r.stdout+r.stderr).decode(errors='replace'))
 return r.stdout
run('openssl','genpkey','-algorithm','ED25519','-out',str(local/'ca.key'))
run('openssl','req','-x509','-new','-key',str(local/'ca.key'),'-out',str(local/'ca.pem'),'-days','7','-subj','/CN=Viewflow-isolated-full-glass-test','-addext','basicConstraints=critical,CA:TRUE','-addext','keyUsage=critical,keyCertSign,cRLSign')
for role in ['source','receiver']:
 run('openssl','genpkey','-algorithm','ED25519','-out',str(local/(role+'.key')))
 run('openssl','req','-new','-key',str(local/(role+'.key')),'-out',str(local/(role+'.csr')),'-subj','/CN=glass-'+role+'.test')
 (local/(role+'.ext')).write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:glass-'+role+'.test\nextendedKeyUsage=serverAuth,clientAuth\n')
 run('openssl','x509','-req','-in',str(local/(role+'.csr')),'-CA',str(local/'ca.pem'),'-CAkey',str(local/'ca.key'),'-CAcreateserial','-out',str(local/(role+'.pem')),'-days','7','-extfile',str(local/(role+'.ext')))
stream=uuid.uuid4().hex
media=dict(color_codec='h264',stream_id=stream,geometry_epoch=1,config_generation=1,width=3968,height=2432,max_width=4096,max_height=2560,max_tiles=1,max_encoded_bytes=16777216,max_decoded_bytes=134217728,refresh_hz=60)
receive=dict(media,bind='0.0.0.0:49073',expected_peer_ip='172.16.105.62',certificate=remote+'\\receiver.pem',private_key=remote+'\\receiver.key',certificate_authority=remote+'\\ca.pem',native_presenter=base+'\\native-trace-controls-build\\Release\\viewflow_windows_composition_preview.exe',startup_timeout_ms=30000,media_idle_timeout_ms=30000,clock_silence_timeout_ms=30000,disposition_recovery=True)
source=dict(occlusion='opaque',capture_provider='viewflow',disposition_recovery=True,bind='0.0.0.0:0',remote='172.16.105.70:49073',server_name='glass-receiver.test',certificate=str(local/'source.pem'),private_key=str(local/'source.key'),certificate_authority=str(local/'ca.pem'),compositor_pid=1,fps=60,startup_timeout_ms=30000,media_idle_timeout_ms=30000,media=media,windows=[dict(window_id=uuid.uuid4().hex,address='0x1',width=3848,height=2408,geometry_epoch=1)])
(local/'receive.json').write_text(json.dumps(receive,indent=2)+'\n');(local/'send.json').write_text(json.dumps(source,indent=2)+'\n')
ps("if(Test-Path '"+remote+"'){throw 'remote workspace exists'};if(Get-NetUDPEndpoint -LocalPort 49073 -ErrorAction SilentlyContinue){throw 'test UDP port is already in use'};New-Item -ItemType Directory -Path '"+remote+"'|Out-Null")
for name in ['receive.json','receiver.pem','receiver.key','ca.pem']:
 run('scp','-q',str(local/name),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+name)
run('target/release/vf-media-peer','validate-send','--config',str(local/'send.json'))
print(ps("& '"+base+"\\target\\release\\vf-media-peer.exe' validate-receive --config '"+remote+"\\receive.json';exit $LASTEXITCODE").decode())
info['config_hashes']={name:hashlib.sha256((local/name).read_bytes()).hexdigest() for name in ['send.json','receive.json']};marker.write_text(json.dumps(info,indent=2)+'\n');print(json.dumps(info,indent=2))
