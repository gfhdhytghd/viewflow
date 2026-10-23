@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE background-cache-runner.cpp /Fe:background-cache-runner.exe /Fo:background-cache-runner.obj /link /SUBSYSTEM:WINDOWS shell32.lib
exit /b %errorlevel%
