from pathlib import Path
import subprocess,base64,hashlib,json,shutil
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip();base=Path('platform/windows-composition-preview')
def ps(s):
 r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=30);r.check_returncode();return r.stdout.decode(errors='replace')
ps("$r='"+root+"';if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'owned process running'}")
files=['main.cpp','sparse_shared_visuals.h','sparse_visual_reference.h','sparse_coalesce_capture_test.cpp','sparse_host_backdrop_test.cpp']
for n in files:
 assert (base/n).read_bytes()==Path('/tmp/viewflow-nowait-experiment-'+n).read_bytes()
 shutil.copyfile('/tmp/viewflow-before-nowait-'+n,base/n)
 subprocess.run(['scp','-q','-o','BatchMode=yes',str(base/n),'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+str(base/n)],check=True)
p=base/'stable_surface_layout.h';assert p.read_bytes()==Path('/tmp/viewflow-nowait-experiment-stable_surface_layout.h').read_bytes();p.unlink()
ps("$r='"+root+"';$h=$r+'\\platform\\windows-composition-preview\\stable_surface_layout.h';if((Get-FileHash $h).Hash -ne '"+hashlib.sha256(Path('/tmp/viewflow-nowait-experiment-stable_surface_layout.h').read_bytes()).hexdigest().upper()+"'){throw 'unexpected experimental header'};Remove-Item $h")
print('5 native source files restored exactly; experimental header removed; original binaries were never replaced')
