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

find_package(CUDAToolkit REQUIRED)

add_library(lowphy_cuda STATIC
  kernels/bfp_kernels.cu
  kernels/ofdm_cufft.cu)
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
