cmake_minimum_required(VERSION 3.21)
include("${CMAKE_CURRENT_SOURCE_DIR}/../../../cmake/nativekit-module.cmake")
project(haxeon_nativekit_filesystem VERSION ${NK_VERSION} LANGUAGES C CXX)
haxeon_nativekit_module(filesystem)
