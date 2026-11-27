#!/usr/bin/env bash
# A CMake package built on another's (as UI, audio and credentials build on the nativekit package): outside an app's
# graph each has its own tree in the shared native cache, the dependent's configure finds the dependency's build with
# find_package through CMAKE_PREFIX_PATH, the dependency is built once, and the published libraries share one copy of it.
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$repo_dir/scripts/lib/env.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cmake-dependency.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
export HAXEON_NATIVE_CACHE="$fixture/native-cache"
mkdir -p "$fixture/base/native" "$fixture/base/src" "$fixture/top/native" "$fixture/top/src" "$fixture/app/src"

cat > "$fixture/base/haxeon.json" <<'JSON'
{
  "version": 1, "package": {"name": "base"}, "sourceRoots": ["src"],
  "ffi": {"interfaces": ["base.hxi"]},
  "native": {"cmake": {"source": "native", "target": "base_count", "library": "base_count"}},
  "target": "host"
}
JSON
cat > "$fixture/base/native/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(base_native LANGUAGES C)
add_library(base_count SHARED count.c)
set_target_properties(base_count PROPERTIES VERSION 1.0 SOVERSION 1)
install(TARGETS base_count EXPORT BaseTargets)
export(EXPORT BaseTargets NAMESPACE Base:: FILE "${CMAKE_BINARY_DIR}/BaseConfig.cmake")
CMAKE
echo 'int base_count(void) { static int calls = 0; return ++calls; }' > "$fixture/base/native/count.c"
cat > "$fixture/base/base.hxi" <<'HXI'
interface Base @target("portable-abi64") @library("base_count") {
  extern fn base_count() -> i32;
}
HXI

cat > "$fixture/top/haxeon.json" <<'JSON'
{
  "version": 1, "package": {"name": "top"}, "sourceRoots": ["src"],
  "dependencies": {"base": {"path": "../base"}},
  "ffi": {"interfaces": ["top.hxi"]},
  "native": {"cmake": {"source": "native", "target": "top_count", "library": "top_count"}},
  "target": "host"
}
JSON
cat > "$fixture/top/native/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(top_native LANGUAGES C)
find_package(Base REQUIRED CONFIG)
add_library(top_count SHARED count.c)
target_link_libraries(top_count PRIVATE Base::base_count)
CMAKE
echo 'extern int base_count(void); int top_count(void) { return 40 + base_count(); }' > "$fixture/top/native/count.c"
cat > "$fixture/top/top.hxi" <<'HXI'
interface Top @target("portable-abi64") @library("top_count") {
  extern fn top_count() -> i32;
}
HXI

cat > "$fixture/app/haxeon.json" <<'JSON'
{
  "version": 1, "package": {"name": "dependency-app"}, "entry": "Main", "sourceRoots": ["src"],
  "dependencies": {"top": {"path": "../top"}, "base": {"path": "../base"}}, "target": "host"
}
JSON
cat > "$fixture/app/src/Main.hx" <<'HX'
class Main {
  static function main():Int {
    var first = Base.base_count();
    return first + Top.top_count();
  }
}
HX

# 1 + (40 + 2): the second call counts on in the same copy of base_count.
set +e
"$repo_dir/scripts/haxeon" run --project="$fixture/app/haxeon.json" >"$fixture/run.log" 2>&1
status=$?
set -e
if [[ $status -ne 43 ]]; then
  cat "$fixture/run.log" >&2
  echo "FAIL: expected the dependent library to share base_count's state (43), got $status" >&2
  exit 1
fi
trees=$(find "$HAXEON_NATIVE_CACHE" -mindepth 2 -maxdepth 2 -type d -name 'base-*' | wc -l)
if [[ $trees -ne 1 ]]; then
  echo "FAIL: base was built in $trees trees of the native cache, not one" >&2
  exit 1
fi
if [[ $(uname -s) == Linux ]]; then
  top="$fixture/app/build/host/native/top/$(haxeon_shared_library top_count)"
  readelf -d "$top" | grep -q 'R.*PATH.*\$ORIGIN:\$ORIGIN/\.\./base' || {
    readelf -d "$top" >&2
    echo "FAIL: the published top_count does not find base_count in base's published directory first" >&2
    exit 1
  }
fi
echo "PASS: a CMake package builds on another's tree in the native cache, which is built once and loaded once"
