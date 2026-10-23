@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /I source source\probe.cpp /Fe:probe.exe /link d3dcompiler.lib d3d11.lib dxgi.lib ole32.lib
exit /b %errorlevel%
