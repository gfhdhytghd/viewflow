@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" -S source\platform\windows-reverse -B build -G "Visual Studio 17 2022" -A x64
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --build build --config Release --target viewflow_windows_reverse viewflow_reverse_perf_fixture viewflow_reverse_perf_runner viewflow_reverse_alpha_async_probe --parallel 2
exit /b %errorlevel%
