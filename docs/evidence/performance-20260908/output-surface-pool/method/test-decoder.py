from pathlib import Path
import subprocess,base64,json,re
b=Path(__file__).resolve().parent.parent
remote=r'C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\output-surface-pool-20260908'
def ps(s,timeout=120):
 return subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(("$ErrorActionPreference='Stop';"+s).encode('utf-16le')).decode()],capture_output=True,timeout=timeout)
fixture=b/'method/fixture.h264'
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','color=c=0x60a0e0:s=3840x2400:r=60','-frames:v','1','-c:v','libx264','-threads','1','-preset','fast','-profile:v','high','-pix_fmt','yuv420p','-color_range','tv','-colorspace','bt709','-color_primaries','bt709','-color_trc','bt709','-x264-params','keyint=1:repeat-headers=1:annexb=1','-f','h264','-y',str(fixture)],check=True)
cmd='''@echo off
call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX integrated-source\\tools\\output-pool-decoder-test.cpp integrated-source\\platform\\windows-video-compositor\\video_compositor.cpp /Fe:output-pool-decoder-test.exe /link mfplat.lib mfuuid.lib ole32.lib d3d11.lib dxgi.lib wmcodecdspuuid.lib d3dcompiler.lib
if errorlevel 1 exit /b %errorlevel%
output-pool-decoder-test.exe fixture.h264 0 > decoder-off.log 2> decoder-off-stderr.log
if errorlevel 1 exit /b %errorlevel%
output-pool-decoder-test.exe fixture.h264 1 > decoder-on.log 2> decoder-on-stderr.log
exit /b %errorlevel%
'''
p=b/'method/test-decoder.cmd';p.write_bytes(cmd.replace('\n','\r\n').encode())
for path,target in [(p,'test-decoder.cmd'),(b/'source/tools/output-pool-decoder-test.cpp',r'integrated-source\tools\output-pool-decoder-test.cpp'),(fixture,'fixture.h264')]:subprocess.run(['scp','-q',str(path),'wilf@172.16.105.70:'+(remote+'\\'+target).replace('\\','/')],check=True)
r=ps("Set-Location '"+remote+"';cmd.exe /d /c 'test-decoder.cmd > decoder-build.log 2>&1';$code=$LASTEXITCODE;Get-Content decoder-build.log;exit $code",240)
(b/'method/decoder-build.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode('gb18030',errors='replace'))
for name in ['decoder-off.log','decoder-off-stderr.log','decoder-on.log','decoder-on-stderr.log']:
 subprocess.run(['scp','-q','wilf@172.16.105.70:'+(remote+'\\'+name).replace('\\','/'),str(b/'method'/name)],check=True)
r.check_returncode()
rows={}
for mode in ['off','on']:
 s=(b/'method'/('decoder-'+mode+'.log')).read_text();assert 'PASS decoder_integration' in s
 by={}
 for id,hash in re.findall(r'readback id=(\d+) alpha_exact=1 bgra_fnv64=(\d+)',s):
  if int(id) in by:assert by[int(id)]==hash
  by[int(id)]=hash
 assert set(by)==set(range(1,25));rows[mode]=by
assert rows['off']==rows['on'];(b/'method/decoder-comparison.json').write_text(json.dumps({'frames':24,'alpha_exact_each_frame':True,'full_bgra_fnv64_checksums_equal':True,'checksums':rows['on']},indent=2)+'\n');print('PASS decoder comparison 24 exact alpha frames and equal full BGRA checksums')
