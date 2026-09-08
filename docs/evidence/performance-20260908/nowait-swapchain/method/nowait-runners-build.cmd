@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 nowait-0-runner.cpp /Fe:isolated-receiver-runner-nowait-0.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 nowait-1-runner.cpp /Fe:isolated-receiver-runner-nowait-1.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
if errorlevel 1 exit /b %errorlevel%
exit /b 0
