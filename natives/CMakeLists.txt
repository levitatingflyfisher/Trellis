# libwhisper.so = whisper.cpp (pinned, statically absorbed) + the wfs shim.
# One artifact per platform; the app binds ONLY the wfs_* exports.
cmake_minimum_required(VERSION 3.22)
project(wfs LANGUAGES C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# The pinned upstream (see README.md for tag + sha). Static libs so the
# final .so is self-contained — one file to place next to the app.
# CACHE FORCE, not a plain set: whisper.cpp/ggml declare this with
# option() under a policy where a plain variable does not win, and a
# shared ggml would leave the shim with dangling DT_NEEDED on device.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
# CPU-only by contract (the shim also pins use_gpu=false at runtime).
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_CUDA OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
# Portable binaries: no -march=native — a family's hardware varies.
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
# No OpenMP: Android ships no libomp.so and the NDK's would be one more
# binary to carry; ggml's own thread pool takes over (n_threads still
# honored through whisper_full_params).
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/whisper.cpp EXCLUDE_FROM_ALL)

add_library(whisper_shim SHARED shim/wfs_shim.c)
set_target_properties(whisper_shim PROPERTIES OUTPUT_NAME whisper)
target_link_libraries(whisper_shim PRIVATE whisper)
target_include_directories(whisper_shim
    PRIVATE third_party/whisper.cpp/include third_party/whisper.cpp/ggml/include)
