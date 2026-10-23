@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE /DNOMINMAX perf_topology_fixture.cpp /Fe:build\Release\viewflow_reverse_perf_topology_fixture.exe /link d3d11.lib dxgi.lib d3dcompiler.lib user32.lib winmm.lib
exit /b %errorlevel%
