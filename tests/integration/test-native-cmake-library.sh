#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-cmake-library.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/tiny/native" "$fixture/tiny/ffi" "$fixture/tiny/src" "$fixture/app/src"

cat > "$fixture/tiny/haxeon.json" <<'JSON'
{
  "version": 1,
  "package": { "name": "tiny" },
  "sourceRoots": ["src"],
  "ffi": { "interfaces": ["ffi/tiny.hxi"] },
  "native": { "cmake": {
    "source": "native", "target": "tiny_core", "library": "tiny_core",
    "inputs": ["native/CMakeLists.txt", "native/tiny.c"]
  } },
  "target": "host"
}
JSON
cat > "$fixture/tiny/native/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required(VERSION 3.21)
project(tiny_core LANGUAGES C)
add_library(tiny_core SHARED tiny.c)
CMAKE
cat > "$fixture/tiny/native/tiny.c" <<'C'
int tiny_answer(void) { return 42; }
C
cat > "$fixture/tiny/ffi/tiny.hxi" <<'HXI'
interface Tiny @target("portable-abi64") @library("tiny_core") {
  extern fn tiny_answer() -> i32;
}
HXI
cat > "$fixture/app/haxeon.json" <<'JSON'
{
  "version": 1,
  "package": { "name": "tiny-app" },
  "entry": "Main",
  "sourceRoots": ["src"],
  "dependencies": { "tiny": { "path": "../tiny" } },
  "target": "host"
}
JSON
cat > "$fixture/app/src/Main.hx" <<'HX'
class Main {
  static function main():Int return Tiny.tiny_answer();
}
HX

set +e
"$repo_dir/scripts/haxeon" run --project="$fixture/app/haxeon.json" >"$fixture/run.log" 2>&1
status=$?
set -e
if [[ $status -ne 42 ]]; then
  cat "$fixture/run.log" >&2
  echo "expected native CMake library call to return 42, got $status" >&2
  exit 1
fi
test -s "$fixture/app/build/host/native/tiny/libtiny_core.so"
"$repo_dir/scripts/haxeon" build --project="$fixture/app/haxeon.json" >"$fixture/rebuild.log" 2>&1
if ! grep -q 'native-cmake-configure:tiny.*clean (fingerprint match)' "$fixture/rebuild.log" ||
    ! grep -q 'compile-project:tiny-app.*clean (fingerprint match)' "$fixture/rebuild.log"; then
  cat "$fixture/rebuild.log" >&2
  exit 1
fi
echo "PASS: CMake library output is built and found by dependents"
