# SPDX-License-Identifier: GPL-3.0-only
cmake_minimum_required(VERSION 3.27)
project(viewflow-hyprland VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(CTest)
include(GNUInstallDirs)
find_package(PkgConfig REQUIRED)
pkg_check_modules(HYPRLAND REQUIRED IMPORTED_TARGET hyprland>=0.56)
pkg_check_modules(XKBCOMMON REQUIRED IMPORTED_TARGET xkbcommon)
pkg_check_modules(LIBINPUT REQUIRED IMPORTED_TARGET libinput)

add_library(viewflow-hyprland SHARED
    src/main.cpp
    src/metadata_bridge.cpp
    src/socket_sink.cpp
    src/input_capture.cpp
    src/input_capture_core.cpp
    src/desktop_window_controller.cpp
    src/window_input_target.cpp
    src/window_pointer_session.cpp
    src/window_pointer_controller.cpp
    src/window_keyboard_state.cpp
    src/window_keyboard_session.cpp
)
target_include_directories(viewflow-hyprland PRIVATE include src)
target_link_libraries(viewflow-hyprland PRIVATE PkgConfig::HYPRLAND PkgConfig::XKBCOMMON PkgConfig::LIBINPUT ${CMAKE_DL_LIBS})
target_compile_options(viewflow-hyprland PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Wconversion
    -Wsign-conversion
    --no-gnu-unique
)
set_target_properties(viewflow-hyprland PROPERTIES PREFIX "" OUTPUT_NAME "viewflow-hyprland")

install(TARGETS viewflow-hyprland LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})

if(BUILD_TESTING)
    add_executable(viewflow-touchpad-capture-test tests/touchpad_capture_test.cpp)
    target_include_directories(viewflow-touchpad-capture-test PRIVATE src)
    target_compile_options(viewflow-touchpad-capture-test PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror -UNDEBUG)
    add_test(NAME viewflow-touchpad-capture-test COMMAND viewflow-touchpad-capture-test)
    add_executable(viewflow-window-input-lifecycle-test tests/window_input_lifecycle_test.cpp)
    target_include_directories(viewflow-window-input-lifecycle-test PRIVATE src)
    target_compile_options(viewflow-window-input-lifecycle-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-window-input-lifecycle-test COMMAND viewflow-window-input-lifecycle-test)
    add_executable(viewflow-window-input-motion-test tests/window_input_motion_test.cpp)
    target_include_directories(viewflow-window-input-motion-test PRIVATE src)
    target_compile_options(viewflow-window-input-motion-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-window-input-motion-test COMMAND viewflow-window-input-motion-test)
    add_executable(viewflow-window-keyboard-state-test tests/window_keyboard_state_test.cpp src/window_keyboard_state.cpp)
    target_include_directories(viewflow-window-keyboard-state-test PRIVATE src)
    target_link_libraries(viewflow-window-keyboard-state-test PRIVATE PkgConfig::XKBCOMMON)
    target_compile_options(viewflow-window-keyboard-state-test PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror)
    add_test(NAME viewflow-window-keyboard-state-test COMMAND viewflow-window-keyboard-state-test)
    add_executable(viewflow-pointer-timing-ring-test tests/pointer_timing_ring_test.cpp)
    target_include_directories(viewflow-pointer-timing-ring-test PRIVATE src)
    target_link_libraries(viewflow-pointer-timing-ring-test PRIVATE ${CMAKE_DL_LIBS})
    target_compile_options(viewflow-pointer-timing-ring-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-pointer-timing-ring-test COMMAND viewflow-pointer-timing-ring-test)
    add_executable(viewflow-window-pointer-command-test tests/window_pointer_command_test.cpp)
    target_include_directories(viewflow-window-pointer-command-test PRIVATE include src)
    target_compile_options(viewflow-window-pointer-command-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-window-pointer-command-test COMMAND viewflow-window-pointer-command-test)
    add_executable(viewflow-hyprland-protocol-test tests/protocol_test.cpp)
    target_include_directories(viewflow-hyprland-protocol-test PRIVATE include)
    target_compile_options(viewflow-hyprland-protocol-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-hyprland-protocol-test COMMAND viewflow-hyprland-protocol-test)

    add_executable(viewflow-hyprland-socket-test tests/socket_sink_test.cpp src/socket_sink.cpp)
    target_include_directories(viewflow-hyprland-socket-test PRIVATE include src)
    target_link_libraries(viewflow-hyprland-socket-test PRIVATE PkgConfig::HYPRLAND)
    target_compile_options(viewflow-hyprland-socket-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-hyprland-socket-test COMMAND viewflow-hyprland-socket-test)

    add_executable(viewflow-hyprland-input-core-test tests/input_capture_core_test.cpp src/input_capture_core.cpp)
    target_include_directories(viewflow-hyprland-input-core-test PRIVATE include src)
    target_compile_options(viewflow-hyprland-input-core-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-hyprland-input-core-test COMMAND viewflow-hyprland-input-core-test)
endif()

if(BUILD_TESTING)
    add_executable(viewflow-ime-popup-scope-test tests/ime_popup_scope_test.cpp)
    target_include_directories(viewflow-ime-popup-scope-test PRIVATE src)
    target_compile_options(viewflow-ime-popup-scope-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
    add_test(NAME viewflow-ime-popup-scope-test COMMAND viewflow-ime-popup-scope-test)
endif()
