@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 udp-paired-probe.cpp /Fe:udp-paired-probe.exe /link ws2_32.lib winmm.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 udp-paired-runner.cpp /Fe:udp-paired-runner.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
exit /b %errorlevel%
