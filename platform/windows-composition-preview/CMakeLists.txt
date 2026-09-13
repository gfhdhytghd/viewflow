cmake_minimum_required(VERSION 3.24)
project(viewflow_windows_composition_preview LANGUAGES CXX)

add_executable(viewflow_sparse_overlap_test sparse_overlap_test.cpp)
target_compile_features(viewflow_sparse_overlap_test PRIVATE cxx_std_20)

add_library(viewflow_vfgp_parser STATIC vfgp_parser.cpp)
target_compile_features(viewflow_vfgp_parser PUBLIC cxx_std_20)
target_include_directories(viewflow_vfgp_parser PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(viewflow_alpha_reuse_parser_test alpha_reuse_parser_test.cpp)
target_compile_features(viewflow_alpha_reuse_parser_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_alpha_reuse_parser_test PRIVATE viewflow_vfgp_parser)
if(MSVC)
  target_compile_options(viewflow_alpha_reuse_parser_test PRIVATE /UNDEBUG)
else()
  target_compile_options(viewflow_alpha_reuse_parser_test PRIVATE -UNDEBUG)
endif()


add_executable(viewflow_windows_composition_preview
  main.cpp
  ../windows-video-compositor/video_compositor.cpp
)
target_include_directories(viewflow_windows_composition_preview PRIVATE ../windows-video-compositor)
target_compile_features(viewflow_windows_composition_preview PRIVATE cxx_std_20)
if(MSVC)
  target_compile_options(viewflow_windows_composition_preview PRIVATE /EHsc)
endif()
target_compile_definitions(viewflow_windows_composition_preview PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(viewflow_windows_composition_preview PRIVATE viewflow_vfgp_parser d3d11 d2d1 dxgi dwmapi windowsapp mfplat mfuuid ole32 wmcodecdspuuid d3dcompiler winmm advapi32 imm32 shell32 propsys)

# Offscreen host-cost probe; never creates a window or desktop target.
add_executable(viewflow_sparse_bind_profile sparse_bind_profile.cpp
  ../windows-video-compositor/video_compositor.cpp)
target_include_directories(viewflow_sparse_bind_profile PRIVATE ../windows-video-compositor)
target_compile_features(viewflow_sparse_bind_profile PRIVATE cxx_std_20)
target_compile_definitions(viewflow_sparse_bind_profile PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(viewflow_sparse_bind_profile PRIVATE /EHsc)
endif()
target_link_libraries(viewflow_sparse_bind_profile PRIVATE viewflow_vfgp_parser d3d11 d2d1 dxgi dwmapi windowsapp mfplat mfuuid ole32 wmcodecdspuuid d3dcompiler winmm advapi32 imm32 shell32 propsys)

# Manual Composition/readback oracle; creates only a nonactivating tool window.
add_executable(viewflow_sparse_surface_gpu_test sparse_surface_gpu_test.cpp
  ../windows-video-compositor/video_compositor.cpp)
target_include_directories(viewflow_sparse_surface_gpu_test PRIVATE ../windows-video-compositor)
target_compile_features(viewflow_sparse_surface_gpu_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_sparse_surface_gpu_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(viewflow_sparse_surface_gpu_test PRIVATE /EHsc)
endif()
target_link_libraries(viewflow_sparse_surface_gpu_test PRIVATE viewflow_vfgp_parser d3d11 d2d1 dxgi dwmapi windowsapp mfplat mfuuid ole32 wmcodecdspuuid d3dcompiler winmm advapi32 imm32 shell32 propsys gdi32)

# Physical HostBackdrop oracle; owns four nonactivating windows, no input injection.
add_executable(viewflow_sparse_host_backdrop_test WIN32 sparse_host_backdrop_test.cpp
  ../windows-video-compositor/video_compositor.cpp)
target_include_directories(viewflow_sparse_host_backdrop_test PRIVATE ../windows-video-compositor)
target_compile_features(viewflow_sparse_host_backdrop_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_sparse_host_backdrop_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(viewflow_sparse_host_backdrop_test PRIVATE /EHsc)
endif()
target_link_libraries(viewflow_sparse_host_backdrop_test PRIVATE viewflow_vfgp_parser d3d11 d2d1 dxgi dwmapi windowsapp mfplat mfuuid ole32 wmcodecdspuuid d3dcompiler winmm advapi32 imm32 shell32 propsys gdi32)

# Owned-visual GPU oracle for opaque backdrop elision.
add_executable(viewflow_sparse_opaque_capture_test WIN32 sparse_opaque_capture_test.cpp
  ../windows-video-compositor/video_compositor.cpp)
target_include_directories(viewflow_sparse_opaque_capture_test PRIVATE ../windows-video-compositor)
target_compile_features(viewflow_sparse_opaque_capture_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_sparse_opaque_capture_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(viewflow_sparse_opaque_capture_test PRIVATE /EHsc)
endif()
target_link_libraries(viewflow_sparse_opaque_capture_test PRIVATE viewflow_vfgp_parser d3d11 d2d1 dxgi dwmapi windowsapp mfplat mfuuid ole32 wmcodecdspuuid d3dcompiler winmm advapi32 imm32 shell32 propsys gdi32)

# Owned-visual GPU oracle for coalesce backdrop elision.
add_executable(viewflow_sparse_coalesce_capture_test WIN32 sparse_coalesce_capture_test.cpp
  ../windows-video-compositor/video_compositor.cpp)
target_include_directories(viewflow_sparse_coalesce_capture_test PRIVATE ../windows-video-compositor)
target_compile_features(viewflow_sparse_coalesce_capture_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_sparse_coalesce_capture_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(viewflow_sparse_coalesce_capture_test PRIVATE /EHsc)
endif()
target_link_libraries(viewflow_sparse_coalesce_capture_test PRIVATE viewflow_vfgp_parser d3d11 d2d1 dxgi dwmapi windowsapp mfplat mfuuid ole32 wmcodecdspuuid d3dcompiler winmm advapi32 imm32 shell32 propsys gdi32)

# Optional shared LGPL FFmpeg distribution supplies D3D11 AV1 decoding without
# a Microsoft Store codec dependency. The legacy H264 build remains available.
set(VIEWFLOW_FFMPEG_ROOT "" CACHE PATH "FFmpeg shared development distribution")
if(VIEWFLOW_FFMPEG_ROOT)
  add_executable(viewflow_atlas_growth_gpu_test ../windows-video-compositor/atlas_growth_gpu_test.cpp
    ../windows-video-compositor/video_compositor.cpp ../windows-video-compositor/ffmpeg_decoder.cpp)
  target_compile_features(viewflow_atlas_growth_gpu_test PRIVATE cxx_std_20)
  target_compile_definitions(viewflow_atlas_growth_gpu_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX VIEWFLOW_HAVE_FFMPEG=1)
  target_include_directories(viewflow_atlas_growth_gpu_test PRIVATE "${VIEWFLOW_FFMPEG_ROOT}/include")
  target_link_libraries(viewflow_atlas_growth_gpu_test PRIVATE mfplat mfuuid ole32 d3d11 dxgi wmcodecdspuuid d3dcompiler
    "${VIEWFLOW_FFMPEG_ROOT}/lib/avcodec.lib" "${VIEWFLOW_FFMPEG_ROOT}/lib/avutil.lib")
  target_sources(viewflow_windows_composition_preview PRIVATE ../windows-video-compositor/ffmpeg_decoder.cpp)
  target_include_directories(viewflow_windows_composition_preview PRIVATE "${VIEWFLOW_FFMPEG_ROOT}/include")
  target_compile_definitions(viewflow_windows_composition_preview PRIVATE VIEWFLOW_HAVE_FFMPEG=1)
  target_link_libraries(viewflow_windows_composition_preview PRIVATE
    "${VIEWFLOW_FFMPEG_ROOT}/lib/avcodec.lib" "${VIEWFLOW_FFMPEG_ROOT}/lib/avutil.lib")
  file(GLOB VIEWFLOW_FFMPEG_DLLS "${VIEWFLOW_FFMPEG_ROOT}/bin/*.dll")
  foreach(runtime IN LISTS VIEWFLOW_FFMPEG_DLLS)
    add_custom_command(TARGET viewflow_windows_composition_preview POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different "${runtime}" "$<TARGET_FILE_DIR:viewflow_windows_composition_preview>")
  endforeach()
endif()

add_executable(viewflow_vfgp_parser_test vfgp_parser_test.cpp)
target_compile_features(viewflow_vfgp_parser_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_parser_test PRIVATE viewflow_vfgp_parser)

add_executable(viewflow_vfgp_parser_negative_test vfgp_parser_negative_test.cpp)
target_compile_features(viewflow_vfgp_parser_negative_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_parser_negative_test PRIVATE viewflow_vfgp_parser)

add_executable(viewflow_compressed_pipe_reader_test compressed_pipe_reader_test.cpp)
target_compile_features(viewflow_compressed_pipe_reader_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_compressed_pipe_reader_test PRIVATE VIEWFLOW_COMPRESSED_PIPE_READER_TESTING)
target_link_libraries(viewflow_compressed_pipe_reader_test PRIVATE viewflow_vfgp_parser runtimeobject windowsapp)
add_executable(viewflow_timer_resolution_guard_test timer_resolution_guard_test.cpp)
target_compile_features(viewflow_timer_resolution_guard_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_timer_resolution_guard_test PRIVATE winmm)
add_executable(viewflow_qpc_deadline_test qpc_deadline_test.cpp)
target_compile_features(viewflow_qpc_deadline_test PRIVATE cxx_std_20)
add_executable(viewflow_vfgp_deadline_admission_test vfgp_deadline_admission_test.cpp)
target_compile_features(viewflow_vfgp_deadline_admission_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_deadline_admission_test PRIVATE viewflow_vfgp_parser)
enable_testing()
add_test(NAME alpha_reuse_parser COMMAND viewflow_alpha_reuse_parser_test)
add_executable(viewflow_signalled_task_test signalled_task_test.cpp)
target_compile_features(viewflow_signalled_task_test PRIVATE cxx_std_20)
add_test(NAME signalled_task COMMAND viewflow_signalled_task_test)
add_executable(viewflow_texture_region_test ../windows-video-compositor/texture_region_test.cpp)
target_compile_features(viewflow_texture_region_test PRIVATE cxx_std_20)
add_test(NAME texture_region COMMAND viewflow_texture_region_test)
add_executable(viewflow_vfgp_recycle_test vfgp_recycle_test.cpp)
target_compile_features(viewflow_vfgp_recycle_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_recycle_test PRIVATE viewflow_vfgp_parser)
add_test(NAME vfgp_recycle COMMAND viewflow_vfgp_recycle_test)
add_test(NAME vfgp_parser COMMAND viewflow_vfgp_parser_test)
add_test(NAME vfgp_parser_negative COMMAND viewflow_vfgp_parser_negative_test)
add_test(NAME compressed_pipe_reader COMMAND viewflow_compressed_pipe_reader_test)
add_test(NAME timer_resolution_guard COMMAND viewflow_timer_resolution_guard_test)
add_test(NAME qpc_deadline COMMAND viewflow_qpc_deadline_test)
add_test(NAME vfgp_deadline_admission COMMAND viewflow_vfgp_deadline_admission_test)

add_executable(viewflow_vfgp_parser_v4_test vfgp_parser_v4_test.cpp)
target_compile_features(viewflow_vfgp_parser_v4_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_parser_v4_test PRIVATE viewflow_vfgp_parser)
add_test(NAME vfgp_parser_v4 COMMAND viewflow_vfgp_parser_v4_test)
add_executable(viewflow_vfgp_parser_v5_test vfgp_parser_v5_test.cpp)
target_compile_features(viewflow_vfgp_parser_v5_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_parser_v5_test PRIVATE viewflow_vfgp_parser)
add_test(NAME vfgp_parser_v5 COMMAND viewflow_vfgp_parser_v5_test)
add_executable(viewflow_vfgp_parser_v8_test vfgp_parser_v8_test.cpp)
target_compile_features(viewflow_vfgp_parser_v8_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_parser_v8_test PRIVATE viewflow_vfgp_parser)
if(MSVC)
  target_compile_options(viewflow_vfgp_parser_v8_test PRIVATE /UNDEBUG)
else()
  target_compile_options(viewflow_vfgp_parser_v8_test PRIVATE -UNDEBUG)
endif()
add_test(NAME vfgp_parser_v8 COMMAND viewflow_vfgp_parser_v8_test)
add_test(NAME sparse_overlap COMMAND viewflow_sparse_overlap_test)
add_executable(viewflow_vfgp_parser_v7_test vfgp_parser_v7_test.cpp)
target_compile_features(viewflow_vfgp_parser_v7_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_vfgp_parser_v7_test PRIVATE viewflow_vfgp_parser)
add_test(NAME vfgp_parser_v7 COMMAND viewflow_vfgp_parser_v7_test)
add_executable(viewflow_desktop_layout_test desktop_layout_test.cpp)
target_compile_features(viewflow_desktop_layout_test PRIVATE cxx_std_20)
add_test(NAME desktop_layout COMMAND viewflow_desktop_layout_test)
add_executable(viewflow_desktop_move_gesture_test desktop_move_gesture_test.cpp)
target_compile_features(viewflow_desktop_move_gesture_test PRIVATE cxx_std_20)
add_test(NAME desktop_move_gesture COMMAND viewflow_desktop_move_gesture_test)
add_executable(viewflow_input_recovery_record_test input_recovery_record_test.cpp)
target_compile_features(viewflow_input_recovery_record_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_input_recovery_record_test PRIVATE viewflow_vfgp_parser)
add_test(NAME input_recovery_record COMMAND viewflow_input_recovery_record_test)
add_executable(viewflow_atlas_frame_bindings_test atlas_frame_bindings_test.cpp)
target_compile_features(viewflow_atlas_frame_bindings_test PRIVATE cxx_std_20)
add_test(NAME atlas_frame_bindings COMMAND viewflow_atlas_frame_bindings_test)
add_executable(viewflow_sparse_opaque_test sparse_opaque_test.cpp)
target_compile_features(viewflow_sparse_opaque_test PRIVATE cxx_std_20)
add_test(NAME sparse_opaque COMMAND viewflow_sparse_opaque_test)
add_executable(viewflow_atlas_decode_identities_test atlas_decode_identities_test.cpp)
target_compile_features(viewflow_atlas_decode_identities_test PRIVATE cxx_std_20)
add_test(NAME atlas_decode_identities COMMAND viewflow_atlas_decode_identities_test)
add_executable(viewflow_annex_b_clean_point_test ../windows-video-compositor/annex_b_clean_point_test.cpp)
target_compile_features(viewflow_annex_b_clean_point_test PRIVATE cxx_std_20)
add_test(NAME annex_b_clean_point COMMAND viewflow_annex_b_clean_point_test)

add_executable(viewflow_warmup_admission_test warmup_admission_test.cpp)
target_compile_features(viewflow_warmup_admission_test PRIVATE cxx_std_20)
add_test(NAME warmup_admission COMMAND viewflow_warmup_admission_test)

add_executable(viewflow_expired_frame_disposition_test expired_frame_disposition_test.cpp)
target_compile_features(viewflow_expired_frame_disposition_test PRIVATE cxx_std_20)
add_test(NAME expired_frame_disposition COMMAND viewflow_expired_frame_disposition_test)

add_executable(viewflow_pointer_motion_test pointer_motion_test.cpp)
target_compile_features(viewflow_pointer_motion_test PRIVATE cxx_std_20)
add_test(NAME pointer_motion COMMAND viewflow_pointer_motion_test)
add_executable(viewflow_atlas_pointer_test atlas_pointer_test.cpp)
target_compile_features(viewflow_atlas_pointer_test PRIVATE cxx_std_20)
add_test(NAME atlas_pointer COMMAND viewflow_atlas_pointer_test)
add_executable(viewflow_keyboard_input_test keyboard_input_test.cpp)
target_compile_features(viewflow_keyboard_input_test PRIVATE cxx_std_20)
add_test(NAME keyboard_input COMMAND viewflow_keyboard_input_test)
add_executable(viewflow_keyboard_clock_bounds_test keyboard_clock_bounds_test.cpp)
target_compile_features(viewflow_keyboard_clock_bounds_test PRIVATE cxx_std_20)
add_test(NAME keyboard_clock_bounds COMMAND viewflow_keyboard_clock_bounds_test)

add_executable(viewflow_remote_input_ime_test remote_input_ime_test.cpp)
target_compile_features(viewflow_remote_input_ime_test PRIVATE cxx_std_20)
target_link_libraries(viewflow_remote_input_ime_test PRIVATE imm32)
add_test(NAME remote_input_ime COMMAND viewflow_remote_input_ime_test)

add_executable(viewflow_desktop_stacking_test desktop_stacking_test.cpp)
target_compile_features(viewflow_desktop_stacking_test PRIVATE cxx_std_20)
add_test(NAME desktop_stacking COMMAND viewflow_desktop_stacking_test)

add_executable(viewflow_frameless_window_test frameless_window_test.cpp)
target_compile_features(viewflow_frameless_window_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_frameless_window_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(viewflow_frameless_window_test PRIVATE user32)
add_test(NAME frameless_window COMMAND viewflow_frameless_window_test)

add_executable(viewflow_sparse_coalesce_test sparse_coalesce_test.cpp)
target_compile_features(viewflow_sparse_coalesce_test PRIVATE cxx_std_20)
add_test(NAME sparse_coalesce COMMAND viewflow_sparse_coalesce_test)

# Manual oracle: real HostBackdrop with moving/resizing owned windows.
add_executable(viewflow_native_background_cache_test WIN32 native_background_cache_test.cpp
  ../windows-video-compositor/video_compositor.cpp)
target_include_directories(viewflow_native_background_cache_test PRIVATE ../windows-video-compositor)
target_compile_features(viewflow_native_background_cache_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_native_background_cache_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(viewflow_native_background_cache_test PRIVATE /EHsc)
endif()
target_link_libraries(viewflow_native_background_cache_test PRIVATE viewflow_vfgp_parser d3d11 d2d1 dxgi dwmapi windowsapp mfplat mfuuid ole32 wmcodecdspuuid d3dcompiler winmm advapi32 imm32 shell32 propsys gdi32)

add_executable(viewflow_background_region_test background_region_test.cpp)
target_compile_features(viewflow_background_region_test PRIVATE cxx_std_20)
add_test(NAME background_region COMMAND viewflow_background_region_test)

# Tests use assert for executable checks (some expressions perform setup).
# Release must run those checks rather than compiling their bodies away.
get_property(preview_targets DIRECTORY PROPERTY BUILDSYSTEM_TARGETS)
foreach(preview_target IN LISTS preview_targets)
  if(preview_target MATCHES "_test$")
    if(MSVC)
      target_compile_options(${preview_target} PRIVATE /UNDEBUG)
    else()
      target_compile_options(${preview_target} PRIVATE -UNDEBUG)
    endif()
  endif()
endforeach()

# This intentionally uses only Windows SDK C++/WinRT headers. Build from an
# x64 Native Tools Command Prompt, for example:
#   cmake -S . -B build -G Ninja
#   cmake --build build --config Release

add_executable(viewflow_application_icon_test application_icon_test.cpp)
target_compile_features(viewflow_application_icon_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_application_icon_test PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(viewflow_application_icon_test PRIVATE /UNDEBUG /EHsc)
target_link_libraries(viewflow_application_icon_test PRIVATE shell32 propsys ole32 windowsapp)
add_test(NAME application_icon COMMAND viewflow_application_icon_test)

# Manual fixture marker observer; reads one scanline from the composed desktop.
add_executable(viewflow_windows_frame_observer WIN32 ../../tools/windows_frame_observer.cpp)
target_compile_features(viewflow_windows_frame_observer PRIVATE cxx_std_20)
target_compile_definitions(viewflow_windows_frame_observer PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(viewflow_windows_frame_observer PRIVATE d3d11 dxgi shell32 user32 winmm)

# Manual presentation-path probe. Owns one nonactivating 4K-content window;
# local GPU-generated markers do not measure the remote streaming pipeline.
add_executable(viewflow_windows_composition_latency_probe WIN32 ../../tools/windows_composition_latency_probe.cpp)
target_compile_features(viewflow_windows_composition_latency_probe PRIVATE cxx_std_20)
target_compile_definitions(viewflow_windows_composition_latency_probe PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
if(MSVC)
  target_compile_options(viewflow_windows_composition_latency_probe PRIVATE /EHsc)
endif()
target_link_libraries(viewflow_windows_composition_latency_probe PRIVATE d3d11 d3dcompiler d2d1 dcomp dwmapi dxgi windowsapp user32 shell32 winmm ole32)

# Window compositor render witness; its timestamps are not desktop presents.
add_executable(viewflow_windows_window_frame_observer WIN32 ../../tools/windows_window_frame_observer.cpp)
target_compile_features(viewflow_windows_window_frame_observer PRIVATE cxx_std_20)
target_compile_definitions(viewflow_windows_window_frame_observer PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_link_libraries(viewflow_windows_window_frame_observer PRIVATE d3d11 dxgi dwmapi shell32 user32 windowsapp winmm)

# The message-only test includes the real WndProc and its timer dispatch.
get_target_property(modal_timer_sources viewflow_windows_composition_preview SOURCES)
list(REMOVE_ITEM modal_timer_sources main.cpp)
add_executable(viewflow_atlas_modal_timer_test atlas_modal_timer_test.cpp ${modal_timer_sources})
target_compile_features(viewflow_atlas_modal_timer_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_atlas_modal_timer_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,COMPILE_DEFINITIONS>)
target_include_directories(viewflow_atlas_modal_timer_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,INCLUDE_DIRECTORIES>)
target_link_libraries(viewflow_atlas_modal_timer_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,LINK_LIBRARIES>)
target_compile_options(viewflow_atlas_modal_timer_test PRIVATE /EHsc /UNDEBUG)
add_test(NAME atlas_modal_timer COMMAND viewflow_atlas_modal_timer_test)

add_executable(viewflow_atlas_surface_retirement_test atlas_surface_retirement_test.cpp ${modal_timer_sources})
target_compile_features(viewflow_atlas_surface_retirement_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_atlas_surface_retirement_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,COMPILE_DEFINITIONS>)
target_include_directories(viewflow_atlas_surface_retirement_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,INCLUDE_DIRECTORIES>)
target_link_libraries(viewflow_atlas_surface_retirement_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,LINK_LIBRARIES>)
target_compile_options(viewflow_atlas_surface_retirement_test PRIVATE /EHsc /UNDEBUG)
# Like sparse_surface_gpu_test, this oracle needs an interactive compositor.
# Run it explicitly in the desktop session; SSH/session-0 lacks that capability.

add_executable(viewflow_sparse_seam_capture_test sparse_seam_capture_test.cpp ${modal_timer_sources})
target_compile_features(viewflow_sparse_seam_capture_test PRIVATE cxx_std_20)
target_compile_definitions(viewflow_sparse_seam_capture_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,COMPILE_DEFINITIONS>)
target_include_directories(viewflow_sparse_seam_capture_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,INCLUDE_DIRECTORIES>)
target_link_libraries(viewflow_sparse_seam_capture_test PRIVATE
  $<TARGET_PROPERTY:viewflow_windows_composition_preview,LINK_LIBRARIES>)
target_compile_options(viewflow_sparse_seam_capture_test PRIVATE /EHsc /UNDEBUG)
