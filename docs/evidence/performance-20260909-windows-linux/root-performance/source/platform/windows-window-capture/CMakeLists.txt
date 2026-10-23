cmake_minimum_required(VERSION 3.24)
project(viewflow_windows_window_capture LANGUAGES CXX)

add_executable(viewflow_wgc_capture_contract_test
  tests/wgc_capture_contract_test.cpp
)
target_compile_features(viewflow_wgc_capture_contract_test PRIVATE cxx_std_20)
target_include_directories(viewflow_wgc_capture_contract_test PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
)
# The contract executable uses assert for its checks. Keep those expressions
# live under Release so CTest cannot report a false pass with NDEBUG defined.
if(MSVC)
  target_compile_options(viewflow_wgc_capture_contract_test PRIVATE /UNDEBUG)
else()
  target_compile_options(viewflow_wgc_capture_contract_test PRIVATE -UNDEBUG)
endif()

enable_testing()
add_test(NAME viewflow_wgc_capture_contract COMMAND viewflow_wgc_capture_contract_test)
add_test(
  NAME viewflow_wgc_window_only_source
  COMMAND ${CMAKE_COMMAND}
    -DSOURCE=${CMAKE_CURRENT_SOURCE_DIR}/wgc_window_capture.cpp
    -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/check_window_only_source.cmake
)

if(WIN32)
  add_library(viewflow_windows_window_capture STATIC wgc_window_capture.cpp)
  target_compile_features(viewflow_windows_window_capture PUBLIC cxx_std_20)
  target_include_directories(viewflow_windows_window_capture PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
  )
  target_compile_definitions(viewflow_windows_window_capture PRIVATE
    UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX
  )
  if(MSVC)
    target_compile_options(viewflow_windows_window_capture PRIVATE /EHsc /W4 /WX)
  else()
    target_compile_options(viewflow_windows_window_capture PRIVATE -Wall -Wextra -Wpedantic -Werror)
  endif()
  target_link_libraries(viewflow_windows_window_capture PRIVATE
    d3d11 dxgi dwmapi windowsapp runtimeobject
  )
else()
  message(STATUS "Windows.Graphics.Capture implementation is Windows-only; building portable contract test only")
endif()
