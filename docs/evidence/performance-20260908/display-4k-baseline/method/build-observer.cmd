@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN windows_frame_observer.cpp /Fe:exact4k-observer.exe /Fo:exact4k-observer.obj /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib d3d11.lib dxgi.lib winmm.lib
exit /b %errorlevel%
