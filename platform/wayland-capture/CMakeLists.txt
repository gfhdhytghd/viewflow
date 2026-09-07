cmake_minimum_required(VERSION 3.20)
project(viewflow_wayland_toplevel_capture C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)
find_program(WAYLAND_SCANNER wayland-scanner REQUIRED)

set(PROTOCOL_DIR /usr/share/wayland-protocols/staging)
set(PROTOCOLS
  ${PROTOCOL_DIR}/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml
  ${PROTOCOL_DIR}/ext-image-capture-source/ext-image-capture-source-v1.xml
  ${PROTOCOL_DIR}/ext-image-copy-capture/ext-image-copy-capture-v1.xml)
set(GENERATED_HEADERS)
set(GENERATED_SOURCES)
foreach(protocol IN LISTS PROTOCOLS)
  get_filename_component(stem ${protocol} NAME_WE)
  set(header ${CMAKE_CURRENT_BINARY_DIR}/${stem}-client-protocol.h)
  set(source ${CMAKE_CURRENT_BINARY_DIR}/${stem}-protocol.c)
  add_custom_command(OUTPUT ${header} ${source}
    COMMAND ${WAYLAND_SCANNER} client-header ${protocol} ${header}
    COMMAND ${WAYLAND_SCANNER} private-code ${protocol} ${source}
    DEPENDS ${protocol}
    VERBATIM)
  list(APPEND GENERATED_HEADERS ${header})
  list(APPEND GENERATED_SOURCES ${source})
endforeach()

add_executable(viewflow-wayland-toplevel-capture
  toplevel_capture.c ${GENERATED_HEADERS} ${GENERATED_SOURCES})
target_compile_features(viewflow-wayland-toplevel-capture PRIVATE c_std_11)
target_compile_definitions(viewflow-wayland-toplevel-capture PRIVATE _GNU_SOURCE)
target_compile_options(viewflow-wayland-toplevel-capture PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_include_directories(viewflow-wayland-toplevel-capture PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
target_link_libraries(viewflow-wayland-toplevel-capture PRIVATE PkgConfig::WAYLAND)

include(CTest)
if(BUILD_TESTING)
  add_executable(viewflow-wayland-toplevel-capture-tests
    tests.c ${GENERATED_HEADERS} ${GENERATED_SOURCES})
  target_compile_features(viewflow-wayland-toplevel-capture-tests PRIVATE c_std_11)
  target_compile_definitions(viewflow-wayland-toplevel-capture-tests PRIVATE _GNU_SOURCE)
  target_compile_options(viewflow-wayland-toplevel-capture-tests PRIVATE -Wall -Wextra -Wpedantic -Werror -Wno-unused-function -UNDEBUG)
  target_include_directories(viewflow-wayland-toplevel-capture-tests PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
  target_link_libraries(viewflow-wayland-toplevel-capture-tests PRIVATE PkgConfig::WAYLAND)
  add_test(NAME viewflow-wayland-toplevel-capture-tests COMMAND viewflow-wayland-toplevel-capture-tests)
endif()
