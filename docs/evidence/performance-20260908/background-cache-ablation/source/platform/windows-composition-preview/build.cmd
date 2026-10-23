@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
cd /d "%~dp0"
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
if errorlevel 1 exit /b %errorlevel%
cmake --build build --config Release
