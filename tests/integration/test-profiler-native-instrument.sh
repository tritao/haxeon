#!/usr/bin/env bash
# Native instrumentation (Windows x64 with MSVC, Linux with GCC or Clang): the instrumented flavor compiles native.sources
# and native.cmake packages with /Gh /GH (compiler instrument flags on Linux), their calls nest under the Haxe calls into
# them, the runtime names them (from each module's PDB on Windows, its symbol table on Linux), and the native scope's
# exclude leaves a source alone. On Windows run it from a Visual Studio x64 developer prompt.
set -euo pipefail

windows=0
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*) windows=1 ;;
	Linux) ;;
	*)
		echo "SKIP: native instrumentation is Windows x64 and Linux only"
		exit 0
		;;
esac

repo_dir=$(cd "$(dirname "$0")/../.." && pwd)
# MSBuild's file tracker fails on long paths, so the projects live directly under the temporary directory.
scratch=$(mktemp -d /tmp/hpni-XXXXXX)
trap 'rm -rf "$scratch"' EXIT
if [[ $windows == 1 ]]; then
	hashlink_include=$(cygpath -m "$repo_dir/vendor/hashlink/src")
else
	hashlink_include="$repo_dir/vendor/hashlink/src"
fi
mkdir -p "$scratch/app/src/app" "$scratch/plain/src/plain" "$scratch/plain/native" "$scratch/cm/src/cm" "$scratch/cm/native/vendor"

cat > "$scratch/plain/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"plain"},"sourceRoots":["src"],"native":{"sources":["native/plain.c"]}}
JSON
cat > "$scratch/plain/native/plain.c" <<'C'
#define HL_NAME(n) plain_##n
#include <hl.h>

#ifdef _MSC_VER
#	define NOINLINE __declspec(noinline)
#else
#	define NOINLINE __attribute__((noinline))
#endif

static NOINLINE int plain_leaf(int n) {
	int x = 0;
	for( int i = 0; i < n; i++ ) x += i % 3;
	return x;
}

HL_PRIM int HL_NAME(value)(void) { return plain_leaf(1000) + plain_leaf(500); }

DEFINE_PRIM_WITH_NAME(_I32, value, _NO_ARG, plain_value);
C
cat > "$scratch/plain/src/plain/Plain.hx" <<'HAXE'
package plain;

@:hlNative("plain", "plain_value")
extern function value():Int;
HAXE

cat > "$scratch/cm/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"cm"},"sourceRoots":["src"],"native":{"cmake":{"source":"native","target":"cm"}}}
JSON
cat > "$scratch/cm/native/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.24)
project(cm C)
add_subdirectory(vendor)
add_library(cm SHARED cm.c)
target_include_directories(cm PRIVATE "$hashlink_include")
target_link_libraries(cm PRIVATE cmvendor)
set_target_properties(cm PROPERTIES PREFIX "" SUFFIX ".hdll" LIBRARY_OUTPUT_DIRECTORY "\${HAXEON_NATIVE_OUTPUT_DIR}" RUNTIME_OUTPUT_DIRECTORY "\${HAXEON_NATIVE_OUTPUT_DIR}")
CMAKE
printf '%s\n' 'add_library(cmvendor STATIC kept.c skipped.c)' 'set_target_properties(cmvendor PROPERTIES POSITION_INDEPENDENT_CODE ON)' \
	> "$scratch/cm/native/vendor/CMakeLists.txt"
printf '%s\n' '#ifdef _MSC_VER' '#define NOINLINE __declspec(noinline)' '#else' '#define NOINLINE __attribute__((noinline))' '#endif' \
	'NOINLINE int cm_skipped(int n) { int x = 0; for (int i = 0; i < n; i++) x ^= i; return x; }' \
	> "$scratch/cm/native/vendor/skipped.c"
printf '%s\n' '#ifdef _MSC_VER' '#define NOINLINE __declspec(noinline)' '#else' '#define NOINLINE __attribute__((noinline))' '#endif' \
	'int cm_skipped(int n);' 'NOINLINE int cm_kept(int n) { return cm_skipped(n) + 1; }' \
	> "$scratch/cm/native/vendor/kept.c"
cat > "$scratch/cm/native/cm.c" <<'C'
#define HL_NAME(n) cm_##n
#include <hl.h>

int cm_kept(int n);

HL_PRIM int HL_NAME(value)(void) { return cm_kept(2000); }

DEFINE_PRIM_WITH_NAME(_I32, value, _NO_ARG, cm_value);
C
cat > "$scratch/cm/src/cm/Cm.hx" <<'HAXE'
package cm;

@:hlNative("cm", "cm_value")
extern function value():Int;
HAXE

cat > "$scratch/app/haxeon.json" <<'JSON'
{"version":1,"package":{"name":"app"},"entry":"app.Main","sourceRoots":["src"],"target":"host","outputDir":"build",
 "dependencies":{"plain":{"path":"../plain"},"cm":{"path":"../cm"}},
 "instrument":{"native":{"exclude":["vendor/skipped.c"]}}}
JSON
cat > "$scratch/app/src/app/Main.hx" <<'HAXE'
package app;

class Main {
	static function main():Void {
		var total = 0;
		for (i in 0...20) {
			haxeon.ProfileFrame.mark();
			total += plain.Plain.value() + cm.Cm.value();
		}
		haxeon.ProfileFrame.idle();
		Sys.println("native instrument test " + total);
	}
}
HAXE

# Every call is kept: the native calls checked here take nanoseconds.
timeout 600s "$repo_dir/scripts/haxeon" run --project "$scratch/app/haxeon.json" --profile --profile-min-call=0 \
	--profile-output "$scratch/capture/profile.hlpc" > "$scratch/run.log" 2>&1 || {
	cat "$scratch/run.log" >&2
	exit 1
}
if [[ $windows == 1 ]]; then
	test -s "$scratch/app/build-instrument/host/native/plain/plain.pdb"
fi
"$repo_dir/.tools/hashlink/hlprof-live" export --format perfetto --output "$scratch/trace.json" "$scratch/capture/profile.hlpc"
python3 - "$scratch/trace.json" <<'PY'
import collections
import json
import sys

events = json.load(open(sys.argv[1], encoding="utf-8"))
events = events["traceEvents"] if isinstance(events, dict) else events
counts = collections.Counter(e["name"] for e in events if e.get("ph") == "B")
for name, count in [("plain_value", 20), ("plain_leaf", 40), ("cm_value", 20), ("cm_kept", 20)]:
    assert counts[name] == count, (name, counts[name], counts.most_common(12))
assert counts["cm_skipped"] == 0, "an excluded source was instrumented"
# Each native call nests under the Haxe call into it.
parents, stacks = collections.Counter(), collections.defaultdict(list)
for e in events:
    if e.get("ph") == "B":
        stack = stacks[e["tid"]]
        parents[(stack[-1] if stack else None, e["name"])] += 1
        stack.append(e["name"])
    elif e.get("ph") == "E" and stacks[e["tid"]]:
        stacks[e["tid"]].pop()
assert parents[("app.Main.main", "plain_value")] == 20 and parents[("plain_value", "plain_leaf")] == 40, parents
assert parents[("app.Main.main", "cm_value")] == 20 and parents[("cm_value", "cm_kept")] == 20, parents
PY
echo "PASS: native.sources and native.cmake calls are instrumented, named and nested, and excluded sources are not"
