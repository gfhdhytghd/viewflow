from pathlib import Path
import subprocess,json,base64
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();cfg=json.loads(Path('/tmp/viewflow-codec-restore-receive.json').read_bytes());cfg['color_codec']='av1';cfg['native_presenter']=root+'\\native-av1-build\\Release\\viewflow_windows_composition_preview.exe';p=Path('/tmp/viewflow-av1-window-validation.json');p.write_text(json.dumps(cfg,indent=2)+'\n')
subprocess.run(['scp','-q','-o','BatchMode=yes',str(p),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/av1-window-validation.json'],check=True)
s="& '"+root+"\\vf-media-peer-av1.exe' validate-receive --config '"+root+"\\av1-window-validation.json';exit $LASTEXITCODE"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True);Path('/tmp/viewflow-av1-window-validation.log').write_bytes(r.stdout+r.stderr);print(r.returncode,r.stdout.decode(errors='replace'));r.check_returncode()
