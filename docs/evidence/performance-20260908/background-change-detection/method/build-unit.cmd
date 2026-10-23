@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cl /nologo /O2 /EHsc /std:c++20 /DNOMINMAX /DWIN32_LEAN_AND_MEAN /DUNICODE /D_UNICODE background_difference_test.cpp /Fe:background-difference-test.exe /Fo:background-difference-test.obj /link d3d11.lib d3dcompiler.lib windowsapp.lib
if errorlevel 1 exit /b %errorlevel%
background-difference-test.exe
exit /b %errorlevel%
