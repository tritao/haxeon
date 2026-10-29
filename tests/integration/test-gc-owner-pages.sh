#!/usr/bin/env bash
# Allocation owners (patchable modules) keep their blocks in pages of their own, so a module's live blocks are counted
# from the mark bits and its allocations take the same fast path as any other.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-owner.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$root/.tools/hashlink}
build() {
	if command -v "${CC:-cc}" >/dev/null 2>&1; then
		"${CC:-cc}" -I"$root/vendor/hashlink/src" "$root/tests/native/$1.c" -L"$library" -lhl -lpthread -o "$work/$1"
	elif command -v cl >/dev/null 2>&1; then
		# MSVC from a Visual Studio command prompt
		MSYS2_ARG_CONV_EXCL='*' cl -nologo -O2 -I"$(cygpath -w "$root/vendor/hashlink/src")" "$(cygpath -w "$root/tests/native/$1.c")" \
			-Fo"$(cygpath -w "$work")\\" -Fe"$(cygpath -w "$work/$1.exe")" -link -LIBPATH:"$(cygpath -w "$library")" libhl.lib >/dev/null
	fi
}
run() {
	PATH="$library:$PATH" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$@"
}
if ! command -v "${CC:-cc}" >/dev/null 2>&1 && ! command -v cl >/dev/null 2>&1; then
	# Windows without MSVC on the path (run from a Visual Studio command prompt to include this test)
	echo "SKIP: no C compiler for the native owner tests"
	exit 0
fi
for test in gc_owner_pages gc_owner_tlab gc_owner_classes; do build "$test"; done
exe=
[ -f "$work/gc_owner_pages.exe" ] && exe=.exe
for mode in 0 1; do
	HL_GC_ALLOC_FAST=$mode run "$work/gc_owner_pages$exe"
done
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
