@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /MD /DNDEBUG /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX observer-sync-control.cpp /Fe:native-build\Release\viewflow_windows_frame_observer_sync.exe /link /SUBSYSTEM:WINDOWS d3d11.lib dxgi.lib shell32.lib user32.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /std:c++20 /O2 /MD /DNDEBUG /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX observer-async-control.cpp /Fe:native-build\Release\viewflow_windows_frame_observer.exe /link /SUBSYSTEM:WINDOWS d3d11.lib dxgi.lib shell32.lib user32.lib
if errorlevel 1 exit /b %errorlevel%
exit /b 0
