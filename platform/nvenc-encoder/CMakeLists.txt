cmake_minimum_required(VERSION 3.20)
project(viewflow_nvenc_encoder LANGUAGES C CXX)

find_package(PkgConfig REQUIRED)
pkg_check_modules(AVCODEC REQUIRED IMPORTED_TARGET libavcodec libavutil)
pkg_check_modules(MEDIA_EGL REQUIRED IMPORTED_TARGET egl glesv2)

add_library(viewflow-nvenc-encoder STATIC nvenc_encoder.cpp nvenc_encoder_cabi.cpp ../linux-media/vaapi_encoder.cpp)
target_compile_features(viewflow-nvenc-encoder PUBLIC cxx_std_20)
target_compile_options(viewflow-nvenc-encoder PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_include_directories(viewflow-nvenc-encoder PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(viewflow-nvenc-encoder PUBLIC PkgConfig::AVCODEC PkgConfig::MEDIA_EGL ${CMAKE_DL_LIBS})

# Deliberately not a CTest: it initializes the installed NVIDIA driver. Run it
# manually for one bounded, synthetic-frame hardware proof.
add_executable(viewflow-nvenc-encoder-smoke smoke.cpp)
target_compile_features(viewflow-nvenc-encoder-smoke PRIVATE cxx_std_20)
target_compile_options(viewflow-nvenc-encoder-smoke PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(viewflow-nvenc-encoder-smoke PRIVATE viewflow-nvenc-encoder)

add_executable(viewflow-nvenc-encoder-cabi-smoke cabi_smoke.c)
target_compile_features(viewflow-nvenc-encoder-cabi-smoke PRIVATE c_std_11)
target_compile_options(viewflow-nvenc-encoder-cabi-smoke PRIVATE -Wall -Wextra -Wpedantic -Werror)
target_link_libraries(viewflow-nvenc-encoder-cabi-smoke PRIVATE viewflow-nvenc-encoder)

# This is intentionally an opt-in, manual probe.  The normal encoder library
# does not require a CUDA SDK or an EGL/OpenGL development environment.
option(VIEWFLOW_BUILD_NVENC_GL_CUDA_INTEROP_PROBE
       "Build the manual EGL/OpenGL texture to CUDA interop capability probe"
       OFF)
if(VIEWFLOW_BUILD_NVENC_GL_CUDA_INTEROP_PROBE)
  pkg_check_modules(VIEWFLOW_EGL_GLES REQUIRED IMPORTED_TARGET egl glesv2)
  find_path(VIEWFLOW_CUDA_INCLUDE_DIR cuda_runtime_api.h
            HINTS /opt/cuda/include /usr/local/cuda/include)
  find_path(VIEWFLOW_CUDA_GL_INTEROP_INCLUDE_DIR cuda_gl_interop.h
            HINTS /opt/cuda/include /usr/local/cuda/include)
  find_library(VIEWFLOW_CUDART_LIBRARY NAMES cudart
               HINTS /opt/cuda/lib64 /usr/local/cuda/lib64)
  if(NOT VIEWFLOW_CUDA_INCLUDE_DIR OR NOT VIEWFLOW_CUDA_GL_INTEROP_INCLUDE_DIR OR
     NOT VIEWFLOW_CUDART_LIBRARY)
    message(FATAL_ERROR
      "VIEWFLOW_BUILD_NVENC_GL_CUDA_INTEROP_PROBE=ON requires CUDA runtime and "
      "OpenGL interop headers plus libcudart (looked in /opt/cuda and /usr/local/cuda).")
  endif()

  add_executable(viewflow-nvenc-gl-cuda-interop-probe gl_cuda_interop_probe.cpp)
  target_compile_features(viewflow-nvenc-gl-cuda-interop-probe PRIVATE cxx_std_20)
  target_compile_options(viewflow-nvenc-gl-cuda-interop-probe PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_include_directories(viewflow-nvenc-gl-cuda-interop-probe PRIVATE
                             ${VIEWFLOW_CUDA_INCLUDE_DIR} ${VIEWFLOW_CUDA_GL_INTEROP_INCLUDE_DIR})
  target_link_libraries(viewflow-nvenc-gl-cuda-interop-probe PRIVATE
                        PkgConfig::VIEWFLOW_EGL_GLES ${VIEWFLOW_CUDART_LIBRARY})
endif()

option(VIEWFLOW_BUILD_NVENC_GL_CUDA_ENCODE_PROBE
       "Build the manual GPU-resident EGL/OpenGL to CUDA to NVENC probe"
       OFF)
if(VIEWFLOW_BUILD_NVENC_GL_CUDA_ENCODE_PROBE)
  pkg_check_modules(VIEWFLOW_ENCODE_EGL_GLES REQUIRED IMPORTED_TARGET egl glesv2)
  find_program(VIEWFLOW_NVCC_EXECUTABLE nvcc HINTS /opt/cuda/bin /usr/local/cuda/bin)
  find_path(VIEWFLOW_ENCODE_CUDA_INCLUDE_DIR cuda_runtime_api.h
            HINTS /opt/cuda/include /usr/local/cuda/include)
  find_path(VIEWFLOW_ENCODE_CUDA_GL_INTEROP_INCLUDE_DIR cuda_gl_interop.h
            HINTS /opt/cuda/include /usr/local/cuda/include)
  find_library(VIEWFLOW_ENCODE_CUDART_LIBRARY NAMES cudart
               HINTS /opt/cuda/lib64 /usr/local/cuda/lib64)
  find_library(VIEWFLOW_ENCODE_CUDA_DRIVER_LIBRARY NAMES cuda
               HINTS /usr/lib /usr/lib64 /opt/cuda/lib64 /usr/local/cuda/lib64)
  if(NOT VIEWFLOW_NVCC_EXECUTABLE OR NOT VIEWFLOW_ENCODE_CUDA_INCLUDE_DIR OR
     NOT VIEWFLOW_ENCODE_CUDA_GL_INTEROP_INCLUDE_DIR OR NOT VIEWFLOW_ENCODE_CUDART_LIBRARY OR
     NOT VIEWFLOW_ENCODE_CUDA_DRIVER_LIBRARY)
    message(FATAL_ERROR
      "VIEWFLOW_BUILD_NVENC_GL_CUDA_ENCODE_PROBE=ON requires nvcc, CUDA runtime/OpenGL "
      "interop headers, libcudart, and the NVIDIA CUDA driver library.")
  endif()
  if(NOT DEFINED CMAKE_CUDA_COMPILER)
    set(CMAKE_CUDA_COMPILER "${VIEWFLOW_NVCC_EXECUTABLE}")
  endif()
  enable_language(CUDA)
  add_executable(viewflow-nvenc-gl-cuda-encode-probe gl_cuda_nvenc_encode_probe.cu)
  target_compile_features(viewflow-nvenc-gl-cuda-encode-probe PRIVATE cxx_std_20)
  set_target_properties(viewflow-nvenc-gl-cuda-encode-probe PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_compile_options(viewflow-nvenc-gl-cuda-encode-probe PRIVATE
                         $<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Wpedantic;-Werror>)
  target_include_directories(viewflow-nvenc-gl-cuda-encode-probe PRIVATE
                             ${VIEWFLOW_ENCODE_CUDA_INCLUDE_DIR} ${VIEWFLOW_ENCODE_CUDA_GL_INTEROP_INCLUDE_DIR})
  target_link_libraries(viewflow-nvenc-gl-cuda-encode-probe PRIVATE
                        PkgConfig::AVCODEC PkgConfig::VIEWFLOW_ENCODE_EGL_GLES
                        ${VIEWFLOW_ENCODE_CUDART_LIBRARY} ${VIEWFLOW_ENCODE_CUDA_DRIVER_LIBRARY})
  add_executable(viewflow-dmabuf-cuda-import-probe dmabuf_cuda_import_probe.cu)
  target_compile_features(viewflow-dmabuf-cuda-import-probe PRIVATE cxx_std_20)
  set_target_properties(viewflow-dmabuf-cuda-import-probe PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_compile_options(viewflow-dmabuf-cuda-import-probe PRIVATE
                         $<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Wpedantic;-Werror>)
  target_include_directories(viewflow-dmabuf-cuda-import-probe PRIVATE
                             ${VIEWFLOW_ENCODE_CUDA_INCLUDE_DIR} ${VIEWFLOW_ENCODE_CUDA_GL_INTEROP_INCLUDE_DIR})
  target_link_libraries(viewflow-dmabuf-cuda-import-probe PRIVATE
                        PkgConfig::AVCODEC PkgConfig::VIEWFLOW_ENCODE_EGL_GLES
                        ${VIEWFLOW_ENCODE_CUDART_LIBRARY} ${VIEWFLOW_ENCODE_CUDA_DRIVER_LIBRARY})
  add_executable(viewflow-gpu-rgba-prepare-test gpu_rgba_prepare_test.cu gpu_rgba_prepare.cu)
  set_target_properties(viewflow-gpu-rgba-prepare-test PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_include_directories(viewflow-gpu-rgba-prepare-test PRIVATE ${VIEWFLOW_ENCODE_CUDA_INCLUDE_DIR})
  target_link_libraries(viewflow-gpu-rgba-prepare-test PRIVATE ${VIEWFLOW_ENCODE_CUDART_LIBRARY})
endif()

# Deliberately opt-in: this is a bounded synthetic CUDA proof for the private
# straight-RGBA shadow repair stage and does not change the encoder library.
option(VIEWFLOW_BUILD_GPU_SHADOW_REPAIR_TEST
       "Build the manual CUDA shadow-repair CPU/GPU oracle test"
       OFF)
if(VIEWFLOW_BUILD_GPU_SHADOW_REPAIR_TEST)
  find_program(VIEWFLOW_SHADOW_REPAIR_NVCC_EXECUTABLE nvcc HINTS /opt/cuda/bin /usr/local/cuda/bin)
  find_path(VIEWFLOW_SHADOW_REPAIR_CUDA_INCLUDE_DIR cuda_runtime_api.h
            HINTS /opt/cuda/include /usr/local/cuda/include)
  find_library(VIEWFLOW_SHADOW_REPAIR_CUDART_LIBRARY NAMES cudart
               HINTS /opt/cuda/lib64 /usr/local/cuda/lib64)
  if(NOT VIEWFLOW_SHADOW_REPAIR_NVCC_EXECUTABLE OR NOT VIEWFLOW_SHADOW_REPAIR_CUDA_INCLUDE_DIR OR
     NOT VIEWFLOW_SHADOW_REPAIR_CUDART_LIBRARY)
    message(FATAL_ERROR
      "VIEWFLOW_BUILD_GPU_SHADOW_REPAIR_TEST=ON requires nvcc, CUDA runtime headers, and libcudart.")
  endif()
  if(NOT DEFINED CMAKE_CUDA_COMPILER)
    set(CMAKE_CUDA_COMPILER "${VIEWFLOW_SHADOW_REPAIR_NVCC_EXECUTABLE}")
  endif()
  enable_language(CUDA)
  add_executable(viewflow-gpu-shadow-repair-test gpu_shadow_repair_test.cu gpu_shadow_repair.cu)
  set_target_properties(viewflow-gpu-shadow-repair-test PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_compile_features(viewflow-gpu-shadow-repair-test PRIVATE cxx_std_20)
  target_compile_options(viewflow-gpu-shadow-repair-test PRIVATE
                         $<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Wpedantic;-Werror>)
  target_include_directories(viewflow-gpu-shadow-repair-test PRIVATE ${VIEWFLOW_SHADOW_REPAIR_CUDA_INCLUDE_DIR})
  target_link_libraries(viewflow-gpu-shadow-repair-test PRIVATE ${VIEWFLOW_SHADOW_REPAIR_CUDART_LIBRARY})
endif()

option(VIEWFLOW_BUILD_GPU_DMABUF_ENCODER
       "Build DMA-BUF media encoding with VA-API and optional NVIDIA support"
       OFF)
if(VIEWFLOW_BUILD_GPU_DMABUF_ENCODER)
  pkg_check_modules(VIEWFLOW_DMABUF_ENCODER_EGL REQUIRED IMPORTED_TARGET egl glesv2)
  pkg_check_modules(VIEWFLOW_DRM REQUIRED IMPORTED_TARGET libdrm)
  add_library(viewflow-gpu-dmabuf-encoder STATIC gpu_dmabuf_encoder.cpp vaapi_dmabuf_encoder.cpp portable_dmabuf_import.cpp
              ../linux-media/vaapi_encoder.cpp gpu_dmabuf_encoder_cabi.cpp)
  target_compile_features(viewflow-gpu-dmabuf-encoder PUBLIC cxx_std_20)
  target_compile_options(viewflow-gpu-dmabuf-encoder PRIVATE -Wall -Wextra -Werror)
  target_include_directories(viewflow-gpu-dmabuf-encoder PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_link_libraries(viewflow-gpu-dmabuf-encoder PUBLIC PkgConfig::AVCODEC PkgConfig::VIEWFLOW_DMABUF_ENCODER_EGL PkgConfig::VIEWFLOW_DRM ${CMAKE_DL_LIBS})
  option(VIEWFLOW_ENABLE_CUDA "Build the optional NVIDIA media module" ON)
  find_program(VIEWFLOW_DMABUF_ENCODER_NVCC nvcc HINTS /opt/cuda/bin /usr/local/cuda/bin)
  find_path(VIEWFLOW_DMABUF_ENCODER_CUDA_INCLUDE cuda_runtime_api.h HINTS /opt/cuda/include /usr/local/cuda/include)
  find_library(VIEWFLOW_DMABUF_ENCODER_CUDART NAMES cudart HINTS /opt/cuda/lib64 /usr/local/cuda/lib64)
  find_library(VIEWFLOW_DMABUF_ENCODER_CUDA_DRIVER NAMES cuda HINTS /usr/lib /usr/lib64 /opt/cuda/lib64 /usr/local/cuda/lib64)
  if(VIEWFLOW_ENABLE_CUDA AND VIEWFLOW_DMABUF_ENCODER_NVCC AND VIEWFLOW_DMABUF_ENCODER_CUDA_INCLUDE AND VIEWFLOW_DMABUF_ENCODER_CUDART AND VIEWFLOW_DMABUF_ENCODER_CUDA_DRIVER)
  if(NOT DEFINED CMAKE_CUDA_COMPILER)
    set(CMAKE_CUDA_COMPILER "${VIEWFLOW_DMABUF_ENCODER_NVCC}")
  endif()
  enable_language(CUDA)
  add_library(viewflow-cuda-encoder SHARED gpu_dmabuf_encoder.cu gpu_rgba_prepare.cu gpu_shadow_repair.cu gpu_atlas_compose.cu gpu_sparse_atlas.cu cuda_encoder_backend.cpp)
  set_target_properties(viewflow-cuda-encoder PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_compile_features(viewflow-cuda-encoder PUBLIC cxx_std_20)
  target_include_directories(viewflow-cuda-encoder PUBLIC ${CMAKE_CURRENT_SOURCE_DIR} ${VIEWFLOW_DMABUF_ENCODER_CUDA_INCLUDE})
  target_link_libraries(viewflow-cuda-encoder PUBLIC PkgConfig::AVCODEC PkgConfig::VIEWFLOW_DMABUF_ENCODER_EGL ${VIEWFLOW_DMABUF_ENCODER_CUDART} ${VIEWFLOW_DMABUF_ENCODER_CUDA_DRIVER})
  add_dependencies(viewflow-gpu-dmabuf-encoder viewflow-cuda-encoder)
  set(CMAKE_BUILD_RPATH "${CMAKE_CURRENT_BINARY_DIR}")
  # Manual hardware oracle, deliberately not an automatic CTest.
  add_executable(viewflow-gpu-sparse-atlas-test gpu_sparse_atlas_test.cu gpu_sparse_atlas.cu)
  set_target_properties(viewflow-gpu-sparse-atlas-test PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_include_directories(viewflow-gpu-sparse-atlas-test PRIVATE ${VIEWFLOW_DMABUF_ENCODER_CUDA_INCLUDE})
  target_link_libraries(viewflow-gpu-sparse-atlas-test PRIVATE ${VIEWFLOW_DMABUF_ENCODER_CUDART})
  add_executable(viewflow-gpu-atlas-compose-test gpu_atlas_compose_test.cu gpu_atlas_compose.cu)
  set_target_properties(viewflow-gpu-atlas-compose-test PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_include_directories(viewflow-gpu-atlas-compose-test PRIVATE ${VIEWFLOW_DMABUF_ENCODER_CUDA_INCLUDE})
  target_link_libraries(viewflow-gpu-atlas-compose-test PRIVATE ${VIEWFLOW_DMABUF_ENCODER_CUDART})
  add_executable(viewflow-portable-cuda-oracle portable_cuda_oracle.cpp gpu_rgba_prepare.cu gpu_shadow_repair.cu gpu_sparse_atlas.cu)
  target_compile_features(viewflow-portable-cuda-oracle PRIVATE cxx_std_20)
  set_target_properties(viewflow-portable-cuda-oracle PROPERTIES CUDA_STANDARD 17 CUDA_STANDARD_REQUIRED YES)
  target_include_directories(viewflow-portable-cuda-oracle PRIVATE ${VIEWFLOW_DMABUF_ENCODER_CUDA_INCLUDE})
  target_link_libraries(viewflow-portable-cuda-oracle PRIVATE ${VIEWFLOW_DMABUF_ENCODER_CUDART})
  else()
    file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/libviewflow-cuda-encoder.so")
  endif() # optional NVIDIA module
  add_executable(viewflow-gpu-dmabuf-encoder-integration-test gpu_dmabuf_encoder_integration_test.cu)
  set_source_files_properties(gpu_dmabuf_encoder_integration_test.cu PROPERTIES LANGUAGE CXX)
  target_compile_features(viewflow-gpu-dmabuf-encoder-integration-test PRIVATE cxx_std_20)
  target_link_libraries(viewflow-gpu-dmabuf-encoder-integration-test PRIVATE viewflow-gpu-dmabuf-encoder)
  add_executable(viewflow-gpu-sparse-encoder-test gpu_sparse_encoder_test.cpp)
  target_compile_features(viewflow-gpu-sparse-encoder-test PRIVATE cxx_std_20)
  target_link_libraries(viewflow-gpu-sparse-encoder-test PRIVATE viewflow-gpu-dmabuf-encoder)


endif()

option(VIEWFLOW_BUILD_EGL_DMABUF_PROBE
       "Build the manual owned EGL texture DMA-BUF capability probe"
       OFF)
if(VIEWFLOW_BUILD_EGL_DMABUF_PROBE)
  pkg_check_modules(VIEWFLOW_DMABUF_EGL_GLES REQUIRED IMPORTED_TARGET egl glesv2)
  add_executable(viewflow-egl-dmabuf-probe egl_dmabuf_export_probe.cpp)
  target_compile_features(viewflow-egl-dmabuf-probe PRIVATE cxx_std_20)
  target_compile_options(viewflow-egl-dmabuf-probe PRIVATE -Wall -Wextra -Wpedantic -Werror)
  target_link_libraries(viewflow-egl-dmabuf-probe PRIVATE PkgConfig::VIEWFLOW_DMABUF_EGL_GLES)
endif()

include(CTest)
option(VIEWFLOW_TEST_GPU_EXPIRY "Enable test-only GPU preparation expiry injection" OFF)
if(VIEWFLOW_TEST_GPU_EXPIRY)
  if(NOT BUILD_TESTING OR NOT TARGET viewflow-cuda-encoder)
    message(FATAL_ERROR "GPU expiry injection requires GPU encoder and BUILD_TESTING")
  endif()
  target_compile_definitions(viewflow-cuda-encoder PRIVATE VIEWFLOW_TEST_GPU_EXPIRY)
  target_compile_definitions(viewflow-gpu-dmabuf-encoder-integration-test PRIVATE VIEWFLOW_TEST_GPU_EXPIRY)
  target_link_libraries(viewflow-gpu-dmabuf-encoder-integration-test PRIVATE viewflow-cuda-encoder)
endif()
if(BUILD_TESTING)
  add_executable(viewflow-gpu-import-cleanup-test gpu_import_cleanup_test.cpp)
  target_compile_features(viewflow-gpu-import-cleanup-test PRIVATE cxx_std_20)
  target_compile_options(viewflow-gpu-import-cleanup-test PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_test(NAME viewflow-gpu-import-cleanup-test COMMAND viewflow-gpu-import-cleanup-test)
  if(VIEWFLOW_BUILD_GPU_DMABUF_ENCODER)
    add_executable(viewflow-gpu-dmabuf-encoder-cabi-test gpu_dmabuf_encoder_cabi_test.c)
    target_compile_features(viewflow-gpu-dmabuf-encoder-cabi-test PRIVATE c_std_11)
    target_compile_options(viewflow-gpu-dmabuf-encoder-cabi-test PRIVATE -Wall -Wextra -Wpedantic -Werror -UNDEBUG)
    target_link_libraries(viewflow-gpu-dmabuf-encoder-cabi-test PRIVATE viewflow-gpu-dmabuf-encoder)
    add_test(NAME viewflow-gpu-dmabuf-encoder-cabi-test COMMAND viewflow-gpu-dmabuf-encoder-cabi-test)
    if(TARGET viewflow-gpu-dmabuf-encoder-integration-test)
      add_test(NAME viewflow-gpu-dmabuf-encoder-integration-test
               COMMAND viewflow-gpu-dmabuf-encoder-integration-test)
    endif()
  endif()
  add_executable(viewflow-shadow-math-tests gpu_shadow_math_test.cpp)
  target_compile_features(viewflow-shadow-math-tests PRIVATE cxx_std_20)
  target_compile_options(viewflow-shadow-math-tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
  add_test(NAME viewflow-shadow-math-tests COMMAND viewflow-shadow-math-tests)
  add_executable(viewflow-nvenc-encoder-tests tests.cpp)
  target_compile_features(viewflow-nvenc-encoder-tests PRIVATE cxx_std_20)
  target_compile_options(viewflow-nvenc-encoder-tests PRIVATE -Wall -Wextra -Wpedantic -Werror -UNDEBUG)
  target_link_libraries(viewflow-nvenc-encoder-tests PRIVATE viewflow-nvenc-encoder)
  add_test(NAME viewflow-nvenc-encoder-tests COMMAND viewflow-nvenc-encoder-tests)
  add_executable(viewflow-nvenc-encoder-cabi-tests cabi_tests.c)
  target_compile_features(viewflow-nvenc-encoder-cabi-tests PRIVATE c_std_11)
  target_compile_options(viewflow-nvenc-encoder-cabi-tests PRIVATE -Wall -Wextra -Wpedantic -Werror -UNDEBUG)
  target_link_libraries(viewflow-nvenc-encoder-cabi-tests PRIVATE viewflow-nvenc-encoder)
  add_test(NAME viewflow-nvenc-encoder-cabi-tests COMMAND viewflow-nvenc-encoder-cabi-tests)
endif()

add_executable(viewflow-sparse-atlas-plan-test sparse_atlas_plan_test.cpp)
target_compile_features(viewflow-sparse-atlas-plan-test PRIVATE cxx_std_20)

if(BUILD_TESTING)
  target_compile_options(viewflow-sparse-atlas-plan-test PRIVATE -UNDEBUG)
  add_test(NAME viewflow-sparse-atlas-plan-test COMMAND viewflow-sparse-atlas-plan-test)
endif()

if(BUILD_TESTING)
  add_executable(viewflow-portable-rgba-test portable_rgba_test.cpp)
  target_compile_features(viewflow-portable-rgba-test PRIVATE cxx_std_20)
  target_compile_options(viewflow-portable-rgba-test PRIVATE -UNDEBUG -Wall -Wextra -Werror)
  add_test(NAME viewflow-portable-rgba-test COMMAND viewflow-portable-rgba-test)
endif()
