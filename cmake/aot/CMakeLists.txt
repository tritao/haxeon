# The executable of a program compiled ahead of time (`--target=hlc`, docs/design/AOT_BACKEND.md), from the C the compiler
# wrote, through the SDK's haxeon_add_c_executable: what `haxeon dev aot` and tests/aot build with.
#
#   cmake -S cmake/aot -B BUILD -G Ninja -DHaxeon_DIR=SDK/cmake -DC_SOURCES=OUTPUT.c -DOUTPUT=OUTPUT [-DDEVELOPMENT=ON]
#   cmake --build BUILD
#
# makes OUTPUT (OUTPUT.exe and its OUTPUT.pdb on Windows with MSVC). The C compiler is CMake's choice: CC, or
# -DCMAKE_C_COMPILER, or a toolchain file for another target (MinGW). DEVELOPMENT is a development build's exact frames.
# The executable looks for the shared libraries it loads in its own directory first, where a console program's release
# build puts its native packages' libraries (`haxeon build --build-mode release`).
cmake_minimum_required(VERSION 3.24)
project(aot_program C)

if(NOT C_SOURCES OR NOT OUTPUT)
  message(FATAL_ERROR "cmake/aot needs -DC_SOURCES=<directory --target=hlc wrote> and -DOUTPUT=<executable>")
endif()
find_package(Haxeon REQUIRED CONFIG)

if(DEVELOPMENT)
  haxeon_add_c_executable(program SOURCES_DIR "${C_SOURCES}" DEVELOPMENT)
else()
  haxeon_add_c_executable(program SOURCES_DIR "${C_SOURCES}")
endif()
get_filename_component(_output "${OUTPUT}" ABSOLUTE)
get_filename_component(_directory "${_output}" DIRECTORY)
get_filename_component(_name "${_output}" NAME)
set_target_properties(program PROPERTIES OUTPUT_NAME "${_name}" RUNTIME_OUTPUT_DIRECTORY "${_directory}")
# Windows searches the executable's directory itself.
if(APPLE)
  set_target_properties(program PROPERTIES BUILD_RPATH "@executable_path" INSTALL_RPATH "@executable_path")
elseif(UNIX)
  set_target_properties(program PROPERTIES BUILD_RPATH "\$ORIGIN" INSTALL_RPATH "\$ORIGIN")
endif()
