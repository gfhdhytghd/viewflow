@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b %errorlevel%
set CARGO_TARGET_DIR=C:\Users\wilf\Viewflow\perf-isolated-8e97c1b751fc\production-pair-20260909\target
"C:\Users\wilf\.cargo\bin\cargo.exe" build --manifest-path source\Cargo.toml --locked --release -p viewflowd --bin vf-window-perf-peer
exit /b %errorlevel%
