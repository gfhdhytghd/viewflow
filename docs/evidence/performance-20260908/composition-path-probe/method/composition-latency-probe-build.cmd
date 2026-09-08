@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX tools\windows_composition_latency_probe.cpp /Fe:viewflow_windows_composition_latency_probe.exe /Fo:composition-latency-probe.obj /link /SUBSYSTEM:WINDOWS d3d11.lib d3dcompiler.lib d2d1.lib dcomp.lib dwmapi.lib dxgi.lib windowsapp.lib user32.lib shell32.lib winmm.lib ole32.lib
exit /b %errorlevel%
