import pathlib,subprocess,base64
root=pathlib.Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
for name in ['sparse_coalesce_capture_test.cpp']:
 src='platform/windows-composition-preview/'+name
 subprocess.run(['scp','-q','-o','BatchMode=yes',src,'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+src],check=True)
s="$ErrorActionPreference='Stop'; Set-Location '"+root+"'; $cmake='C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe'; & $cmake --build native-build --config Release --target viewflow_sparse_coalesce_capture_test --parallel 2 > inplace-pixels-build.log 2>&1; $code=$LASTEXITCODE; Get-Content inplace-pixels-build.log -Tail 18; if($code){exit $code}; exit 0"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell.exe','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=300);print('native build/tests',r.returncode,r.stdout.decode(errors='replace'),r.stderr.decode(errors='replace') if r.returncode else '',flush=True);raise SystemExit(r.returncode)
