@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE wait-resolution-probe.cpp /Fe:wait-resolution-probe.exe /link /SUBSYSTEM:WINDOWS shell32.lib user32.lib winmm.lib
exit /b %errorlevel%
