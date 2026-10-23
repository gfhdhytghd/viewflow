@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" -S source\platform\windows-reverse -B build -G "Visual Studio 17 2022" -A x64
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --build build --config Release --target viewflow_windows_reverse viewflow_reverse_wire_test viewflow_reverse_geometry_test viewflow_wgc_capture_contract_test viewflow_reverse_frame_changes_test viewflow_reverse_performance_mode_test viewflow_reverse_alpha_async_probe --parallel 2
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\ctest.exe" --test-dir build -C Release --output-on-failure
exit /b %errorlevel%
