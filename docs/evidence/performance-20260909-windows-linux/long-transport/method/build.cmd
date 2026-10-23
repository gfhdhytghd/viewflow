@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
if not exist build\Release mkdir build\Release
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE /DNOMINMAX source\perf_fixture_long.cpp /Fe:build\Release\viewflow_reverse_perf_long_fixture.exe /link d3d11.lib dxgi.lib d3dcompiler.lib user32.lib winmm.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE source\perf_interval_long_runner.cpp /Fe:build\Release\viewflow_reverse_perf_interval_long_runner.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
exit /b %errorlevel%
