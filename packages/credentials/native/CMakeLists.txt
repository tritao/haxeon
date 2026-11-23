# NativeKit's credentials module, built on the nativekit package's NativeKit: its targets in an app's graph, its build in the
# shared native cache otherwise.
cmake_minimum_required(VERSION 3.21)
project(haxeon_nativekit_credentials LANGUAGES C CXX)
if(NOT COMMAND nativekit_add_module)
    find_package(NativeKitPackage REQUIRED CONFIG)
endif()
nativekit_add_module(credentials)
