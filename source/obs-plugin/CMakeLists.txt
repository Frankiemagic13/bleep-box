cmake_minimum_required(VERSION 3.20)
project(bleep-box VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The build workflow fills these in (see .github/workflows/build.yml)
set(OBS_INCLUDE_DIR "" CACHE PATH "Folder with the libobs headers (obs-studio/libobs)")
set(OBS_LIB "" CACHE FILEPATH "obs.lib import library")

if(NOT OBS_INCLUDE_DIR OR NOT OBS_LIB)
  message(FATAL_ERROR "Set OBS_INCLUDE_DIR and OBS_LIB")
endif()

add_library(bleep-box MODULE src/bleep-box.cpp)
target_include_directories(bleep-box PRIVATE "${OBS_INCLUDE_DIR}")
target_link_libraries(bleep-box PRIVATE "${OBS_LIB}" ole32 ws2_32)
target_compile_definitions(bleep-box PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX WIN32_LEAN_AND_MEAN UNICODE _UNICODE)
target_compile_options(bleep-box PRIVATE /W3 /utf-8)
set_target_properties(bleep-box PROPERTIES PREFIX "" MSVC_RUNTIME_LIBRARY "MultiThreaded")
