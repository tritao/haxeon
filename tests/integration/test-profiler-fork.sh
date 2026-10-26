#!/usr/bin/env bash
# A forked child of a recording process stops recording instead of hanging once the profiler's pool fills.
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
