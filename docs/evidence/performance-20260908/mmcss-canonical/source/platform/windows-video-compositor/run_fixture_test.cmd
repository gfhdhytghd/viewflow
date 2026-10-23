@echo off
"%~dp0build\Release\viewflow_windows_video_compositor_test.exe" "%~dp0..\fixture"
echo test_exit=%errorlevel%
