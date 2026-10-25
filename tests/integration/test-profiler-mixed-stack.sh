#!/usr/bin/env bash
# Mixed-mode samples (Linux and macOS): a sample taken in native code, or in Haxe code that native code called back,
# holds the native frames between the Haxe ones, in order. The sampler follows the frame-pointer chain, which Haxeon
# keeps in the native packages it builds. A function that is not exported is named from the image's symbol table, and
# the frames of HashLink's launcher above the program are left out.
set -euo pipefail

case "$(uname -s)" in
	Linux | Darwin) ;;
	*)
		echo "SKIP: Windows samples are walked with unwind data, covered by test-profiler-native-instrument.sh"
		exit 0
		;;
esac

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hpms-XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/app/src/app" "$scratch/mixed/src/mixed" "$scratch/mixed/native"

cat > "$scratch/mixed/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"mixed"},"sourceRoots":["src"],"native":{"sources":["native/mixed.c"]}}
JSON
cat > "$scratch/mixed/native/mixed.c" <<'C'
#define HL_NAME(n) mixed_##n
#include <hl.h>
#include <time.h>

static volatile int mixed_sink;

static double mixed_now( void ) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return now.tv_sec + now.tv_nsec / 1e9;
}

/* Spins in native code, so samples stop here. */
__attribute__((noinline)) int mixed_spin_leaf( double seconds ) {
	double end = mixed_now() + seconds;
	while( mixed_now() < end )
		for( int i = 0; i < 1000; i++ ) mixed_sink += i;
	return mixed_sink;
}

/* Not exported: dladdr has no name for it, so the exporter names it from the symbol table. */
static __attribute__((noinline)) void mixed_inner( vclosure *callback ) {
	if( callback->hasValue ) ((void (*)(void*))callback->fun)(callback->value);
	else ((void (*)(void))callback->fun)();
	mixed_sink++; /* keeps the call from becoming a tail call */
}

__attribute__((noinline)) void mixed_outer( vclosure *callback ) {
	mixed_inner(callback);
	mixed_sink++;
}

HL_PRIM void HL_NAME(through)( vclosure *callback ) { mixed_outer(callback); mixed_sink++; }
HL_PRIM int HL_NAME(spin)( double seconds ) { return mixed_spin_leaf(seconds) + 1; }

DEFINE_PRIM_WITH_NAME(_VOID, through, _FUN(_VOID, _NO_ARG), mixed_through);
DEFINE_PRIM_WITH_NAME(_I32, spin, _F64, mixed_spin);
C
cat > "$scratch/mixed/src/mixed/Mixed.hx" <<'HAXE'
package mixed;

@:hlNative("mixed", "mixed_through")
extern function through(callback:Void->Void):Void;

@:hlNative("mixed", "mixed_spin")
extern function spin(seconds:Float):Int;
HAXE

cat > "$scratch/app/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"app"},"entry":"app.Main","sourceRoots":["src"],"target":"host","outputDir":"build",
 "dependencies":{"mixed":{"path":"../mixed"}}}
JSON
cat > "$scratch/app/src/app/Main.hx" <<'HAXE'
package app;

class Main {
	static var total = 0;

	static function spinInHaxe():Void {
		var end = Sys.time() + 0.4;
		while (Sys.time() < end)
			for (i in 0...1000)
				total += i;
	}

	static function main():Void {
		mixed.Mixed.through(spinInHaxe);
		total += mixed.Mixed.spin(0.4);
		Sys.println("mixed stack test " + (total != 0));
	}
}
HAXE

timeout 600s "$repo_dir/scripts/haxeon" run --project "$scratch/app/haxeon.json" --profile=sampling \
	--profile-output "$scratch/capture/profile.hlpc" > "$scratch/run.log" 2>&1 || {
	cat "$scratch/run.log" >&2
	exit 1
}
grep -q "mixed stack test true" "$scratch/run.log"
"$repo_dir/.tools/hashlink/hlprof-live" export --format folded "$scratch/capture/profile.hlpc" > "$scratch/folded.txt"
python3 - "$scratch/folded.txt" <<'PY'
import re
import sys

stacks = []
for line in open(sys.argv[1], encoding="utf-8"):
    stack, _, count = line.rstrip("\n").rpartition(" ")
    stacks.append((stack.split(";"), int(count)))


def samples(predicate):
    return sum(count for frames, count in stacks if predicate(frames))


def ordered(frames, patterns):
    """True when frames hold a frame matching each pattern, root to leaf, in this order."""
    position = 0
    for pattern in patterns:
        while position < len(frames) and not re.search(pattern, frames[position]):
            position += 1
        if position == len(frames):
            return False
        position += 1
    return True


total = sum(count for _, count in stacks)
assert total > 0, "no samples"
launcher = [f for f, _ in stacks if re.match(r"(hl|libhl\.[^+]*|hl_dyn_call\w*|hl_call_method)\+0x", f[0])]
assert not launcher, "stacks start in HashLink's launcher: " + ";".join(launcher[0])
# Haxe calls native code that calls back into Haxe: the native frames sit between the Haxe ones, the static one named
# like the exported ones.
callback = samples(lambda f: ordered(f, [r"app\.Main\.main", r"mixed_outer", r"^mixed_inner\+0x", r"app\.Main\.spinInHaxe"]))
# Native code that does the work itself: the native leaf under the Haxe call into it.
native = samples(lambda f: ordered(f, [r"app\.Main\.main", r"mixed_spin_leaf"]))
in_callback = samples(lambda f: any("spinInHaxe" in x for x in f))
in_native = samples(lambda f: any("mixed_spin_leaf" in x for x in f))
report = f"{total} samples: {in_callback} in the callback ({callback} with its native frames), {in_native} in native code ({native} under main)"
assert in_callback > 10 and in_native > 10, report
# Allow a few samples taken while a frame was being set up or torn down.
assert callback >= in_callback * 0.9, report + "\n" + "\n".join(";".join(f) for f, _ in stacks if any("spinInHaxe" in x for x in f))[:4000]
assert native >= in_native * 0.9, report
print(report)
PY
echo "PASS: samples hold the native frames between Haxe frames, in order"
