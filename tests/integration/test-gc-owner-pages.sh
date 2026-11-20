#!/usr/bin/env bash
# Allocation owners (patchable modules) keep their blocks in pages of their own, so a module's live blocks are counted
# from the mark bits and its allocations take the same fast path as any other.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gc-owner.XXXXXX")
trap 'rm -rf "$work"' EXIT
library=${HL_GC_TEST_LIBRARY_DIR:-$("$root/scripts/hashlink-path.sh")}
source "$root/scripts/lib/env.sh"
run() {
	PATH="$library:$PATH" LD_LIBRARY_PATH="$library${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$library${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$@"
}
for mode in 0 1; do
	HL_GC_ALLOC_FAST=$mode run "$(haxeon_native_test gc_owner_pages)"
	HL_GC_ALLOC_FAST=$mode run "$(haxeon_native_test gc_mark_completion)"
done
# A partial word at the end of a registered stack is not a root.
run "$(haxeon_native_test gc_stack_boundary)"
# A thread's current arena owns what it allocates, on either allocation path.
for mode in 0 1; do
	HL_GC_ALLOC_FAST=$mode run "$(haxeon_native_test gc_arenas)"
done
# An arena released without a collection is reused at once when nothing points into it, and left to the collector when
# a page, a root or a stack slot does; with write tracking off every release is left to the collector.
for tracking in 1 0; do
	for mode in 0 1; do
		HL_GC_ARENA_TRACKING=$tracking HL_GC_ALLOC_FAST=$mode run "$(haxeon_native_test gc_arena_free)" >/dev/null
	done
done
# Owned allocations come out of the thread's buffers through the inline entry.
HL_GC_ALLOC_FAST=1 run "$(haxeon_native_test gc_owner_tlab)"
# With the empty-page cache on, an owner's emptied pages stay cached until the owner is released.
HL_GC_KEEP_EMPTY=1 HL_GC_EMPTY_BUDGET=67108864 run "$(haxeon_native_test gc_owner_classes)" 2>"$work/classes.err" || { cat "$work/classes.err" >&2; exit 1; }
warnings=$(grep -c '^HL warning: more than' "$work/classes.err" || true)
if [ "$warnings" != 1 ]; then
	echo "FAIL: expected one owner-overflow warning, saw $warnings" >&2
	cat "$work/classes.err" >&2
	exit 1
fi
printf '%s\n' 'PASS: owners are counted from their pages, allocate from thread buffers, share pages past the class limit and give classes back; arenas own what they allocate and are released without a collection when nothing points in'
