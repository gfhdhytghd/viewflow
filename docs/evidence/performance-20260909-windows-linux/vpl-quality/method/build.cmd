@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN /we4700 /we4701 source\perf_fixture.cpp /Fe:viewflow_reverse_perf_fixture.exe /link user32.lib d3d11.lib dxgi.lib d3dcompiler.lib winmm.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN /we4700 /we4701 source\perf_runner.cpp /Fe:viewflow_reverse_perf_runner.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
exit /b %errorlevel%
