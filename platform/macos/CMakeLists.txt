cmake_minimum_required(VERSION 3.24)
if(NOT CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
  message(FATAL_ERROR "The macOS probe requires macOS and the Apple SDK")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum macOS version")
project(viewflow_macos LANGUAGES OBJC OBJCXX CXX)
add_executable(viewflow-macos-probe probe.m)
target_compile_options(viewflow-macos-probe PRIVATE -fobjc-arc -Wall -Wextra -Werror)
target_link_libraries(viewflow-macos-probe PRIVATE
  "-framework Foundation" "-framework ApplicationServices"
  "-framework ScreenCaptureKit" "-framework Metal")
enable_testing()
add_test(NAME probe-help COMMAND viewflow-macos-probe --help)

add_executable(viewflow-macos-windows window_main.mm window_codec.mm window_source.mm window_presenter.mm window_pixels.mm)
target_compile_features(viewflow-macos-windows PRIVATE cxx_std_20)
set_target_properties(viewflow-macos-windows PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
target_compile_options(viewflow-macos-windows PRIVATE -fobjc-arc -Wall -Wextra -Werror)
target_link_libraries(viewflow-macos-windows PRIVATE
  "-framework AppKit" "-framework ApplicationServices" "-framework ScreenCaptureKit"
  "-framework CoreImage" "-framework CoreMedia" "-framework CoreVideo"
  "-framework VideoToolbox" "-framework QuartzCore" "-framework Metal")
add_test(NAME windows-help COMMAND viewflow-macos-windows --help)
add_test(NAME windows-codec COMMAND viewflow-macos-windows --codec-self-test)
add_executable(viewflow-window-annex-test ../reverse-common/annex_b_test.cpp)
target_compile_features(viewflow-window-annex-test PRIVATE cxx_std_20)
target_compile_options(viewflow-window-annex-test PRIVATE -UNDEBUG)
add_test(NAME windows-annex-b COMMAND viewflow-window-annex-test)
add_executable(viewflow-window-keys-test window_keys_test.cpp)
target_compile_features(viewflow-window-keys-test PRIVATE cxx_std_20)
target_compile_options(viewflow-window-keys-test PRIVATE -UNDEBUG)
add_test(NAME windows-key-mapping COMMAND viewflow-window-keys-test)
