@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN marker-diagnostic.cpp /Fe:marker-diagnostic.exe /Fo:marker-diagnostic.obj /link /SUBSYSTEM:WINDOWS user32.lib shell32.lib d3d11.lib dxgi.lib winmm.lib dwmapi.lib
exit /b %errorlevel%
