@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" -S integrated-source\platform\windows-composition-preview -B native-build -G "Visual Studio 17 2022" -A x64 "-DVIEWFLOW_FFMPEG_ROOT=C:\Users\wilf\AppData\Local\Temp\viewflow-codec-bench\ffmpeg-n8.1-latest-win64-lgpl-shared-8.1"
if errorlevel 1 exit /b %errorlevel%
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --build native-build --config Release --target viewflow_windows_composition_preview viewflow_native_background_cache_test viewflow_background_region_test viewflow_sparse_coalesce_test viewflow_sparse_opaque_test --parallel 2
if errorlevel 1 exit /b %errorlevel%
exit /b %errorlevel%
