cmake_minimum_required(VERSION 3.24)
project(haxeon_android_app LANGUAGES C CXX)

include("${HAXEON_GENERATED_DIR}/haxeon.cmake")
find_package(Haxeon REQUIRED)
haxeon_add_native_packages(TOOLCHAIN_OUTPUT)
