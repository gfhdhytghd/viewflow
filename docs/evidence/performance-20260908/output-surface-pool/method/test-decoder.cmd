@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX integrated-source\tools\output-pool-decoder-test.cpp integrated-source\platform\windows-video-compositor\video_compositor.cpp /Fe:output-pool-decoder-test.exe /link mfplat.lib mfuuid.lib ole32.lib d3d11.lib dxgi.lib wmcodecdspuuid.lib d3dcompiler.lib
if errorlevel 1 exit /b %errorlevel%
output-pool-decoder-test.exe fixture.h264 0 > decoder-off.log 2> decoder-off-stderr.log
if errorlevel 1 exit /b %errorlevel%
output-pool-decoder-test.exe fixture.h264 1 > decoder-on.log 2> decoder-on-stderr.log
exit /b %errorlevel%
