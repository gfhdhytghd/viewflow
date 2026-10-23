@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE set-4k.cpp /Fe:set-4k.exe /Fo:set-4k.obj /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib
exit /b %errorlevel%
