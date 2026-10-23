@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN /we4700 /we4701 source\lifecycle_fixture.cpp /Fe:viewflow_reverse_lifecycle_fixture.exe /link user32.lib gdi32.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /std:c++20 /EHsc /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN /we4700 /we4701 source\lifecycle_runner.cpp /Fe:viewflow_reverse_lifecycle_runner.exe /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
exit /b %errorlevel%
