@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN window-style-probe.cpp /Fe:window-style-probe.exe /Fo:window-style-probe.obj /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib d3d11.lib dxgi.lib winmm.lib dwmapi.lib windowsapp.lib CoreMessaging.lib gdi32.lib
exit /b %errorlevel%
