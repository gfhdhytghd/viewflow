from pathlib import Path
import shutil
base=Path('/home/wilf/data/viewflow/docs/evidence/performance-20260909-windows-linux');b=base/'root-capture-stop';assert not b.exists();(b/'source').mkdir(parents=True);(b/'method').mkdir()
source=base/'direct-source-stop/source';count=0
for f in sorted(source.rglob('*')):
 if f.is_file():
  rel=f.relative_to(source);current=Path('/home/wilf/data/viewflow')/rel
  if current.is_file():
   dest=b/'source'/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(current,dest);count+=1
s=(base/'direct-source-stop/method/stage-build.py').read_text().replace('reverse-direct-source-stop-20260909','reverse-root-capture-stop-20260909');(b/'method/stage-build.py').write_text(s)
s=(base/'direct-source-stop/method/build.cmd').read_text();s=s.replace('viewflow_windows_reverse viewflow_reverse_perf_fixture viewflow_reverse_perf_runner viewflow_reverse_alpha_async_probe','viewflow_windows_reverse viewflow_reverse_wire_test viewflow_reverse_geometry_test viewflow_wgc_capture_contract_test')
s=s.replace('exit /b %errorlevel%\n', 'exit /b %errorlevel%\n',1)
needle='exit /b %errorlevel%\n';pos=s.rfind(needle);assert pos>=0;s=s[:pos]+'''if errorlevel 1 exit /b %errorlevel%
"C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\Common7\\IDE\\CommonExtensions\\Microsoft\\CMake\\CMake\\bin\\ctest.exe" --test-dir build -C Release --output-on-failure
exit /b %errorlevel%
'''+s[pos+len(needle):]
(b/'method/build.cmd').write_text(s);(b/'method/prepare.py').write_text(Path(__file__).read_text());print('root source files',count)
