from pathlib import Path
import subprocess,base64
root=Path('/tmp/viewflow-windows-isolated-root.txt').read_text().strip()
file='platform/windows-composition-preview/CMakeLists.txt'
subprocess.run(['scp','-q','-o','BatchMode=yes',file,'wilf@172.16.105.70:'+root.replace(chr(92),'/')+'/'+file],check=True)
s="$ProgressPreference='SilentlyContinue';$ErrorActionPreference='Stop';$cmake='C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\cmake.exe'; Set-Location '"+root+"'; & $cmake -S platform/windows-composition-preview -B composition-latency-probe-cmake-build -G 'Visual Studio 17 2022' -A x64; if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}; & $cmake --build composition-latency-probe-cmake-build --config Release --target viewflow_windows_composition_latency_probe; exit $LASTEXITCODE"
r=subprocess.run(['ssh','-o','BatchMode=yes','wilf@172.16.105.70','powershell','-NoProfile','-EncodedCommand',base64.b64encode(s.encode('utf-16le')).decode()],capture_output=True,timeout=240)
Path('/tmp/viewflow-composition-probe-cmake-build.log').write_bytes(r.stdout+r.stderr);print(r.stdout.decode(errors='replace'));r.check_returncode()
