# The Windows runner of Circuit Run (docs/design/PROJECT_BUILDS.md). It is the app's to change: the executable's name, its
# resources (version information, icon: app.rc.in) and manifest (app.manifest), and packaging belong here. What the app is (its
# module, its native packages, its name and version) comes from the fragment `haxeon build` generates, so this file needs no
# change when the app's code or dependencies do. It builds with MSVC, as the SDK's libraries are built.
#
#   haxeon build                      generates the fragment, then builds this project into build/windows/app/
#   cmake -S windows -B build/windows -G Ninja && cmake --build build/windows
#                                     builds it without haxeon from a Visual Studio developer prompt, once a build has
#                                     generated the fragment
cmake_minimum_required(VERSION 3.24)
project(haxeon-circuit-run C CXX RC)

set(HAXEON_GENERATED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../build/generated/windows" CACHE PATH
  "The fragment haxeon build generates for this runner")
include("${HAXEON_GENERATED_DIR}/haxeon.cmake")

# The Haxeon this runner was written for: an SDK of another minor version reports that the runner needs updating
# (docs/design/PROJECT_BUILDS.md, runner versions).
find_package(Haxeon 0.3 REQUIRED CONFIG)

# A Windows program, which opens no console window from Explorer and prints to the terminal that starts it.
haxeon_add_app(haxeon-circuit-run)
# An app that wants a console window of its own, always, is a console program instead:
# set_target_properties(haxeon-circuit-run PROPERTIES WIN32_EXECUTABLE OFF)  # a console window of its own (log window, server)

# The version resource takes four numbers: [app].version's, padded with zeros.
string(REGEX MATCHALL "[0-9]+" HAXEON_APP_VERSION_NUMBERS "${HAXEON_APP_VERSION}")
list(APPEND HAXEON_APP_VERSION_NUMBERS 0 0 0 0)
list(SUBLIST HAXEON_APP_VERSION_NUMBERS 0 4 HAXEON_APP_VERSION_NUMBERS)
list(JOIN HAXEON_APP_VERSION_NUMBERS "," HAXEON_APP_VERSION_NUMBERS)
configure_file(app.rc.in app.rc @ONLY)
target_sources(haxeon-circuit-run PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/app.rc" app.manifest)
