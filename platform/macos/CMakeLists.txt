cmake_minimum_required(VERSION 3.24)
if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
  message(FATAL_ERROR "The macOS probe requires macOS and the Apple SDK")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")
project(viewflow_macos LANGUAGES OBJC)
add_executable(viewflow-macos-probe probe.m)
target_compile_options(viewflow-macos-probe PRIVATE -fobjc-arc -Wall -Wextra -Werror)
target_link_libraries(viewflow-macos-probe PRIVATE
  "-framework Foundation" "-framework ApplicationServices"
  "-framework ScreenCaptureKit" "-framework Metal")
enable_testing()
add_test(NAME probe-help COMMAND viewflow-macos-probe --help)
