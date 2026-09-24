#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$repo_dir/out/cxx_msvc_projection"

hxi_path="$repo_dir/out/cxx_msvc_profile.hxi"
"$repo_dir/scripts/haxeon-ffi-import" \
	--language=c++ \
	--std=c++20 \
	--cxx-lifetimes \
	--target=x86_64-pc-windows-msvc \
	--library=cxx_msvc_fixture \
	--interface=CxxMsvcFixture \
	--haxe-output-dir="$repo_dir/out/cxx_msvc_projection" \
	--output="$hxi_path" \
	"$repo_dir/tests/ffi/cxx_lifetime_fixture.hpp"

grep -q 'interface CxxMsvcFixture @target("x86_64-pc-windows-msvc")' "$hxi_path"
grep -q '@symbol("??0Widget@cxxlife@@QEAA@H@Z")' "$hxi_path"
grep -q '@symbol("??_DWidget@cxxlife@@QEAAXXZ")' "$hxi_path"
grep -q 'public static function create(value:Int):Widget' "$repo_dir/out/cxx_msvc_projection/Widget.hx"
grep -q 'public function close():Void' "$repo_dir/out/cxx_msvc_projection/Widget.hx"
echo "PASS MSVC x64 C++ import profile preserves target layouts, symbols, and lifetime projection"
