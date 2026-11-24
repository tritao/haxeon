# The macOS runner of Viewport (docs/design/PROJECT_BUILDS.md). It is the app's to change: the executable's name, the bundle's
# Info.plist, its icon and packaging belong here. What the app is (its module, its native packages, its name, identifier and
# version) comes from the fragment `haxeon build` generates, so this file needs no change when the app's code or dependencies
# do.
#
#   haxeon build                      generates the fragment, then builds this project into build/macos/app/haxeon-gpu-viewport.app
#   cmake -S macos -B build/macos && cmake --build build/macos
#                                     builds it without haxeon, once a build has generated the fragment
cmake_minimum_required(VERSION 3.24)
project(haxeon-gpu-viewport C CXX)

set(HAXEON_GENERATED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/generated/macos" CACHE PATH
  "The fragment haxeon build generates for this runner")
include("${HAXEON_GENERATED_DIR}/haxeon.cmake")

# The Haxeon this runner was written for: an SDK of another minor version reports that the runner needs updating
# (docs/design/PROJECT_BUILDS.md, runner versions).
find_package(Haxeon 0.3 REQUIRED CONFIG)

# The app as a bundle, haxeon-gpu-viewport.app, named and identified from the app manifest.
haxeon_add_app(haxeon-gpu-viewport)
set_target_properties(haxeon-gpu-viewport PROPERTIES MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in")
