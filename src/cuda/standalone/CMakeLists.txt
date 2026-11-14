# SPDX-FileCopyrightText: Copyright (C) 2026 Software Radio Systems Limited
# SPDX-License-Identifier: BSD-3-Clause-Open-MPI

cmake_minimum_required(VERSION 3.20)
project(lowphy_cuda LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

set(CMAKE_CUDA_ARCHITECTURES "90;87" CACHE STRING "CUDA architectures" FORCE)

set(PROTO_RU "${CMAKE_CURRENT_SOURCE_DIR}/../../../external/proto-ru" CACHE PATH "Path to the ProtO-RU submodule")
set(OCUDU_BUILD "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/ocudu" CACHE PATH "Path to the OCUDU build tree")
set(OCUDU_FAIR_BUILD "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/ocudu-fair" CACHE PATH "OCUDU build with ENABLE_FFTW=ON and MARCH=x86-64-v4")
set(FFTW3F_ROOT "/home/tanglab/.local/fftw3" CACHE PATH "User-local FFTW3F prefix")

find_package(CUDAToolkit REQUIRED)

add_library(lowphy_cuda STATIC
  kernels/bfp_kernels.cu
  kernels/ofdm_cufft.cu
  kernels/pipeline.cu)
target_include_directories(lowphy_cuda PUBLIC include)
target_compile_options(lowphy_cuda PRIVATE
  $<$<COMPILE_LANGUAGE:CUDA>:-O3>)
target_link_libraries(lowphy_cuda PUBLIC CUDA::cudart CUDA::cufft)

set(OCUDU_LIBRARIES
  "${OCUDU_BUILD}/lib/phy/lower/modulation/libocudu_lower_phy_modulation.a"
  "${OCUDU_BUILD}/lib/ofh/compression/libocudu_ofh_compression.a"
  "${OCUDU_BUILD}/lib/phy/support/libocudu_phy_support.a"
  "${OCUDU_BUILD}/lib/phy/generic_functions/libocudu_dft.a"
  "${OCUDU_BUILD}/lib/ocuduvec/libocuduvec.a"
  "${OCUDU_BUILD}/lib/ran/libocudu_ran.a"
  "${OCUDU_BUILD}/lib/support/libocudu_support.a"
  "${OCUDU_BUILD}/lib/support/math/libocudu_support_math.a"
  "${OCUDU_BUILD}/lib/ocudulog/libocudulog.a"
  "${OCUDU_BUILD}/lib/instrumentation/libocudu_instrumentation.a"
  "${OCUDU_BUILD}/external/fmt/libfmt.a")

set(OCUDU_INCLUDE_DIRS
  "${PROTO_RU}/include"
  "${PROTO_RU}/external"
  "${PROTO_RU}/external/fmt/include"
  "${PROTO_RU}/lib/ofh/compression"
  "${PROTO_RU}/lib/phy/lower/modulation")

add_executable(test_lowphy
  tests/test_lowphy.cpp
  tests/ofdm_radix2_reference.cu)
target_include_directories(test_lowphy PRIVATE include ${OCUDU_INCLUDE_DIRS})
target_compile_definitions(test_lowphy PRIVATE BUILD_TYPE_RELEASE NDEBUG)
target_compile_options(test_lowphy PRIVATE -O3 -march=native)

target_link_libraries(test_lowphy PRIVATE
  lowphy_cuda
  "-Wl,--start-group"
  ${OCUDU_LIBRARIES}
  "-Wl,--end-group"
  "/home/tanglab/miniconda3/lib/libyaml-cpp.so"
  pthread
  dl
  m)

add_executable(test_pipeline
  tests/test_pipeline.cpp)
target_include_directories(test_pipeline PRIVATE include ${OCUDU_INCLUDE_DIRS})
target_compile_definitions(test_pipeline PRIVATE BUILD_TYPE_RELEASE NDEBUG)
target_compile_options(test_pipeline PRIVATE -O3 -march=native)

target_link_libraries(test_pipeline PRIVATE
  lowphy_cuda
  "-Wl,--start-group"
  ${OCUDU_LIBRARIES}
  "-Wl,--end-group"
  "/home/tanglab/miniconda3/lib/libyaml-cpp.so"
  pthread
  dl
  m)

set(OCUDU_FAIR_LIBRARIES
  "${OCUDU_FAIR_BUILD}/lib/phy/lower/modulation/libocudu_lower_phy_modulation.a"
  "${OCUDU_FAIR_BUILD}/lib/ofh/compression/libocudu_ofh_compression.a"
  "${OCUDU_FAIR_BUILD}/lib/phy/support/libocudu_phy_support.a"
  "${OCUDU_FAIR_BUILD}/lib/phy/generic_functions/libocudu_dft.a"
  "${OCUDU_FAIR_BUILD}/lib/ocuduvec/libocuduvec.a"
  "${OCUDU_FAIR_BUILD}/lib/ran/libocudu_ran.a"
  "${OCUDU_FAIR_BUILD}/lib/support/libocudu_support.a"
  "${OCUDU_FAIR_BUILD}/lib/support/math/libocudu_support_math.a"
  "${OCUDU_FAIR_BUILD}/lib/ocudulog/libocudulog.a"
  "${OCUDU_FAIR_BUILD}/lib/instrumentation/libocudu_instrumentation.a"
  "${OCUDU_FAIR_BUILD}/external/fmt/libfmt.a")

add_executable(test_cpu_baseline
  tests/test_cpu_baseline.cpp)
target_include_directories(test_cpu_baseline PRIVATE include ${OCUDU_INCLUDE_DIRS} "${FFTW3F_ROOT}/include")
target_compile_definitions(test_cpu_baseline PRIVATE BUILD_TYPE_RELEASE NDEBUG)
target_compile_options(test_cpu_baseline PRIVATE -O3 -march=x86-64-v4)

target_link_libraries(test_cpu_baseline PRIVATE
  "-Wl,--start-group"
  ${OCUDU_FAIR_LIBRARIES}
  "-Wl,--end-group"
  "${FFTW3F_ROOT}/lib/libfftw3f.so"
  "/home/tanglab/miniconda3/lib/libyaml-cpp.so"
  pthread
  dl
  m)
