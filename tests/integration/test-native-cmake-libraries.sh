#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cmake-libraries.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/tiny/native" "$fixture/tiny/ffi" "$fixture/tiny/src" "$fixture/app/src"

cat > "$fixture/tiny/haxeon.json" <<'JSON'
{
  "version": 1,
  "package": {"name": "tiny"},
  "sourceRoots": ["src"],
  "ffi": {"interfaces": ["ffi/alpha.hxi", "ffi/beta.hxi"]},
  "native": {"cmake": {
    "source": "native", "target": "tiny_native", "libraries": ["tiny_alpha", "tiny_beta"],
    "inputs": ["native/CMakeLists.txt", "native/alpha.c", "native/beta.c"]
  }},
  "target": "host"
}
JSON
cat > "$fixture/tiny/native/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(tiny_native LANGUAGES C)
add_library(tiny_alpha SHARED alpha.c)
set_target_properties(tiny_alpha PROPERTIES VERSION 1.0 SOVERSION 1)
add_library(tiny_beta SHARED beta.c)
target_link_libraries(tiny_beta PRIVATE tiny_alpha)
add_custom_target(tiny_native DEPENDS tiny_alpha tiny_beta)
CMAKE
echo 'int tiny_alpha(void) { static int calls = 0; return ++calls; }' > "$fixture/tiny/native/alpha.c"
echo 'extern int tiny_alpha(void); int tiny_beta(void) { return 40 + tiny_alpha(); }' > "$fixture/tiny/native/beta.c"
cat > "$fixture/tiny/ffi/alpha.hxi" <<'HXI'
interface TinyAlpha @target("portable-abi64") @library("tiny_alpha") {
  extern fn tiny_alpha() -> i32;
}
HXI
cat > "$fixture/tiny/ffi/beta.hxi" <<'HXI'
interface TinyBeta @target("portable-abi64") @library("tiny_beta") {
  extern fn tiny_beta() -> i32;
}
HXI
cat > "$fixture/app/haxeon.json" <<'JSON'
{
  "version": 1, "package": {"name": "tiny-app"}, "entry": "Main", "sourceRoots": ["src"],
  "dependencies": {"tiny": {"path": "../tiny"}}, "target": "host"
}
JSON
cat > "$fixture/app/src/Main.hx" <<'HX'
class Main {
  static function main():Int {
    var first = TinyAlpha.tiny_alpha();
    return first + TinyBeta.tiny_beta();
  }
}
HX

run_expected() {
  local expected=$1
  set +e
  "$repo_dir/scripts/haxeon" run --project="$fixture/app/haxeon.json" >"$fixture/run.log" 2>&1
  local status=$?
  set -e
  if [[ $status -ne $expected ]]; then
    cat "$fixture/run.log" >&2
    echo "expected aggregate library call to return $expected, got $status" >&2
    exit 1
  fi
}

run_expected 43
output="$fixture/app/build/host/native/tiny"
test -s "$output/libtiny_alpha.so"
test -s "$output/libtiny_beta.so"
test ! -e "$output/tiny.hdll"
"$repo_dir/scripts/haxeon" build --project="$fixture/app/haxeon.json" >"$fixture/rebuild.log" 2>&1
if ! grep -q 'native-cmake-configure:tiny.*clean (fingerprint match)' "$fixture/rebuild.log" ||
    ! grep -q 'compile-project:tiny-app.*clean (fingerprint match)' "$fixture/rebuild.log"; then
  cat "$fixture/rebuild.log" >&2
  exit 1
fi

# CMake must recreate a missing secondary output; bytecode does not need recompilation.
rm -- "$output/libtiny_beta.so"
run_expected 43
test -s "$output/libtiny_beta.so"
grep -q 'compile-project:tiny-app.*clean (fingerprint match)' "$fixture/run.log"

# Delegation must still notice changes in CMake's own dependency graph.
echo 'extern int tiny_alpha(void); int tiny_beta(void) { return 41 + tiny_alpha(); }' > "$fixture/tiny/native/beta.c"
run_expected 44
grep -q 'compile-project:tiny-app.*clean (fingerprint match)' "$fixture/run.log"

# A target that succeeds without producing a promised library is a failed build.
sed -i 's/"tiny_alpha", "tiny_beta"/"tiny_alpha", "tiny_beta", "never_built"/' "$fixture/tiny/haxeon.json"
if "$repo_dir/scripts/haxeon" build --project="$fixture/app/haxeon.json" >"$fixture/missing.log" 2>&1; then
  echo "expected a missing declared library to fail the build" >&2
  exit 1
fi
grep -q 'did not produce required output .*libnever_built.so' "$fixture/missing.log"
echo "PASS: aggregate CMake targets share linked library state, repair outputs, and reject incomplete builds"
