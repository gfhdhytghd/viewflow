@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE perf_alpha_runner.cpp /Fe:build\Release\viewflow_reverse_perf_alpha_runner.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
exit /b %errorlevel%
