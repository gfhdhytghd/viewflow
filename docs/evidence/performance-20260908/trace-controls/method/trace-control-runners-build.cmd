@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 trace-control-full-runner.cpp /Fe:isolated-receiver-runner-trace-full.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 trace-control-noquery-runner.cpp /Fe:isolated-receiver-runner-trace-noquery.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 trace-control-minimal-runner.cpp /Fe:isolated-receiver-runner-trace-minimal.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
if errorlevel 1 exit /b %errorlevel%
exit /b 0
