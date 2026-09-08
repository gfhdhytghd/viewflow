@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
if not exist alpha-mask-objects mkdir alpha-mask-objects
cl /nologo /EHsc /std:c++20 /O2 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX /Iplatform\windows-video-compositor platform\windows-composition-preview\sparse_alpha_mask_test.cpp platform\windows-video-compositor\video_compositor.cpp platform\windows-composition-preview\vfgp_parser.cpp /Fo:alpha-mask-objects\ /Fe:viewflow_sparse_alpha_mask_test.exe /link /SUBSYSTEM:WINDOWS d3d11.lib d2d1.lib dxgi.lib dwmapi.lib windowsapp.lib mfplat.lib mfuuid.lib ole32.lib wmcodecdspuuid.lib d3dcompiler.lib winmm.lib advapi32.lib imm32.lib shell32.lib propsys.lib gdi32.lib user32.lib
exit /b %errorlevel%
