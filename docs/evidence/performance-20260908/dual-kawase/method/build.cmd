@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX approximate_blur_probe.cpp /Fe:approximate_blur_probe.exe /Fo:approximate_blur_probe.obj /link d3d11.lib d2d1.lib dxgi.lib windowsapp.lib ole32.lib d3dcompiler.lib
exit /b %errorlevel%
