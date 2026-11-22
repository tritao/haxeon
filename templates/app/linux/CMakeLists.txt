# The Linux runner of {{name}} (docs/design/PROJECT_BUILDS.md). It is the app's to change: the executable's name, the
# desktop entry and packaging belong here. What the app is (its module, its native packages, its name and identifier)
# comes from the fragment `haxeon build` generates, so this file needs no change when the app's code or dependencies do.
#
#   haxeon build                      generates the fragment, then builds this project
#   cmake -S linux -B build/linux && cmake --build build/linux
#                                     builds it without haxeon, once a build has generated the fragment
cmake_minimum_required(VERSION 3.24)
project({{package}} C CXX)

set(HAXEON_GENERATED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/generated/linux" CACHE PATH
  "The fragment haxeon build generates for this runner")
include("${HAXEON_GENERATED_DIR}/haxeon.cmake")

haxeon_add_app({{package}} MODULE "${HAXEON_MODULE}" NATIVE_TARGETS ${HAXEON_NATIVE_TARGETS})
