#!/usr/bin/env bash
# Allocation owners (patchable modules) keep their blocks in pages of their own, so a module's live blocks are counted
# from the mark bits and its allocations take the same fast path as any other.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-owner.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$("$root/scripts/hashlink-path.sh")}
source "$root/scripts/lib/env.sh"
build() {
	CFLAGS=-O2 haxeon_cc_libhl "$work/$1" "$root/tests/native/$1.c"
}
run() {
	PATH="$library:$PATH" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$@"
}
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) compiler=cl ;; *) compiler=${CC:-cc} ;; esac
if ! command -v "$compiler" >/dev/null 2>&1; then
	# Windows outside MSVC's environment (run from a Visual Studio command prompt to include this test)
	echo "SKIP: no C compiler for the native owner tests"
	exit 0
fi
for test in gc_owner_pages gc_owner_tlab gc_owner_classes gc_mark_completion gc_stack_boundary; do build "$test"; done
exe=
[ -f "$work/gc_owner_pages.exe" ] && exe=.exe
for mode in 0 1; do
	HL_GC_ALLOC_FAST=$mode run "$work/gc_owner_pages$exe"
	HL_GC_ALLOC_FAST=$mode run "$work/gc_mark_completion$exe"
done
# A partial word at the end of a registered stack is not a root.
run "$work/gc_stack_boundary$exe"
# Owned allocations come out of the thread's buffers through the inline entry.
HL_GC_ALLOC_FAST=1 run "$work/gc_owner_tlab$exe"
# With the empty-page cache on, an owner's emptied pages stay cached until the owner is released.
HL_GC_KEEP_EMPTY=1 HL_GC_EMPTY_BUDGET=67108864 run "$work/gc_owner_classes$exe" 2>"$work/classes.err" || { cat "$work/classes.err" >&2; exit 1; }
warnings=$(grep -c '^HL warning: more than' "$work/classes.err" || true)
if [ "$warnings" != 1 ]; then
	echo "FAIL: expected one owner-overflow warning, saw $warnings" >&2
	cat "$work/classes.err" >&2
	exit 1
fi
printf '%s\n' 'PASS: owners are counted from their pages, allocate from thread buffers, share pages past the class limit and give classes back'
