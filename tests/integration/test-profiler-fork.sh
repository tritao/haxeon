#!/usr/bin/env bash
# A forked child of a recording process stops recording instead of hanging once the profiler's pool fills, whether its
# records come from Haxe-side spans or from instrumented native code (Linux, when libhlprof_hooks.a is built).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-profiler-fork.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
if [[ $(uname -s) == MINGW* || $(uname -s) == MSYS* || $(uname -s) == CYGWIN* ]] || ! command -v "${CC:-cc}" >/dev/null 2>&1; then
	echo "SKIP: no fork or no C compiler for the profiler fork test"
	exit 0
fi
"${CC:-cc}" -I"$root/vendor/hashlink/src" "$root/tests/native/profiler_fork.c" -L"$library" -lhl -lpthread -o "$work/profiler_fork"
LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
	timeout 60 "$work/profiler_fork"

hooks="$library/libhlprof_hooks.a"
if [[ -f "$hooks" ]]; then
	flags=(-finstrument-functions)
	if "${CC:-cc}" --version 2>/dev/null | grep -q clang; then flags=(-finstrument-functions-after-inlining); fi
	"${CC:-cc}" "${flags[@]}" -fPIC -I"$root/vendor/hashlink/src" "$root/tests/native/profiler_fork_native.c" "$hooks" -L"$library" -lhl -lpthread \
		-o "$work/profiler_fork_native"
	LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
		timeout 60 "$work/profiler_fork_native"
fi
