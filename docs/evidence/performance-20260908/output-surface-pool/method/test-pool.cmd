@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 integrated-source\tools\output-pool-test.cpp /Fe:output-pool-test.exe /Fo:output-pool-test.obj /link d3d11.lib dxgi.lib
if errorlevel 1 exit /b %errorlevel%
output-pool-test.exe
exit /b %errorlevel%
