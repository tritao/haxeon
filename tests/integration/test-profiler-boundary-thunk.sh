#!/usr/bin/env bash
# The boundary hooks' thunk (Linux x86-64): a call into one of our own shared objects is recorded under the function's
# name, and the real function still gets exactly its arguments (in registers and on the stack, integer, double and
# variadic) and returns exactly its result (in rax, rdx, xmm0, xmm1 and in memory). A C++ exception thrown through a hooked
# function and the cancellation of a thread blocked in a hooked call unwind through it. An object loaded with dlopen after
# the hooks were installed is patched too.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-boundary-thunk.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]] || ! command -v "${CC:-cc}" >/dev/null 2>&1; then
	echo "SKIP: the boundary thunk test is Linux x86-64 only"
	exit 0
fi
"${CC:-cc}" -O1 -fPIC -shared "$root/tests/native/profiler_boundary_lib.c" -o "$work/libboundarylib.so"
"${CC:-cc}" -O1 -fPIC -shared "$root/tests/native/profiler_boundary_late.c" -L"$work" -lboundarylib -o "$work/libboundarylate.so"
"${CC:-cc}" -O1 -I"$root/vendor/hashlink/src" "$root/tests/native/profiler_boundary_args.c" \
	"$root/vendor/hashlink/src/prof_boundary_linux.c" "$root/vendor/hashlink/src/prof_boundary_x64_sysv.c" \
	-L"$work" -lboundarylib -L"$library" -lhl -ldl -lpthread -o "$work/profiler_boundary_args"
LD_LIBRARY_PATH="$work:$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" timeout 60 "$work/profiler_boundary_args"

if command -v "${CXX:-c++}" >/dev/null 2>&1; then
	"${CXX:-c++}" -O1 -fPIC -shared "$root/tests/native/profiler_boundary_throw_lib.cpp" -o "$work/libboundarythrow.so"
	"${CC:-cc}" -O1 -I"$root/vendor/hashlink/src" -c "$root/vendor/hashlink/src/prof_boundary_linux.c" -o "$work/prof_boundary_linux.o"
	"${CC:-cc}" -O1 -I"$root/vendor/hashlink/src" -c "$root/vendor/hashlink/src/prof_boundary_x64_sysv.c" -o "$work/prof_boundary_x64_sysv.o"
	"${CXX:-c++}" -O1 "$root/tests/native/profiler_boundary_unwind.cpp" "$work/prof_boundary_linux.o" "$work/prof_boundary_x64_sysv.o" \
		-L"$work" -lboundarythrow -L"$library" -lhl -ldl -lpthread -o "$work/profiler_boundary_unwind"
	LD_LIBRARY_PATH="$work:$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" timeout 60 "$work/profiler_boundary_unwind"
fi
