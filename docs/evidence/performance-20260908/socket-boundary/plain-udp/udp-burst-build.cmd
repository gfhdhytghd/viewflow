@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 udp-burst-probe.cpp /Fe:udp-burst-probe.exe /link ws2_32.lib
exit /b %errorlevel%
