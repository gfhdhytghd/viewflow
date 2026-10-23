from pathlib import Path
import subprocess,base64,xml.etree.ElementTree as ET,hashlib,json
b=Path(__file__).resolve().parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\display-4k-baseline-20260908'
def ps(s,timeout=120):
 r=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout);r.check_returncode();return r.stdout
subprocess.run(['scp','-q','wilf@172.16.105.70:C:/VirtualDisplayDriver/vdd_settings.xml',str(b/'vdd-before.xml')],check=True)
old=(b/'vdd-before.xml').read_bytes();doc=ET.fromstring(old);rs=doc.find('resolutions');assert len(rs)==1 and rs[0].findtext('width')=='6144' and rs[0].findtext('height')=='3456'
x=ET.Element('resolution');ET.SubElement(x,'width').text='3840';ET.SubElement(x,'height').text='2400';ET.SubElement(x,'refresh_rate').text='60';rs.insert(0,x);ET.indent(doc,'  ')
new=ET.tostring(doc,encoding='utf-8',xml_declaration=True)+b'\n';(b/'vdd-with-4k.xml').write_bytes(new)
(b/'mode-change-plan.json').write_text(json.dumps({'old_sha256':hashlib.sha256(old).hexdigest(),'new_sha256':hashlib.sha256(new).hexdigest(),'target_width':3840,'target_height':2400,'target_hz':60,'existing_6k_mode_preserved':True},indent=2)+'\n')
cmd='@echo off\ncall "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"\nif errorlevel 1 exit /b %errorlevel%\ncl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE set-4k.cpp /Fe:set-4k.exe /Fo:set-4k.obj /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib\nexit /b %errorlevel%\n'
p=b/'build-mode.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for p in [p,b/'set-4k.cpp',b/'vdd-with-4k.xml']:
 subprocess.run(['scp','-q',str(p),'wilf@172.16.105.70:'+remote.replace('\\','/')+'/'+p.name],check=True)
r=ps("Set-Location '"+remote+"';cmd /c 'build-mode.cmd > build-mode.log 2>&1';$code=$LASTEXITCODE;Get-Content build-mode.log;exit $code");(b/'build-mode.log').write_bytes(r)
r=ps("[pscustomobject]@{admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);mode_tool=(Get-FileHash '"+remote+"\\set-4k.exe').Hash;current_config=(Get-FileHash 'C:\\VirtualDisplayDriver\\vdd_settings.xml').Hash;device=(Get-PnpDevice -InstanceId 'ROOT\\DISPLAY\\0000').Status}|ConvertTo-Json")
(b/'mode-ready.json').write_bytes(r);print(r.decode())
