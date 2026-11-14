#!/usr/bin/env bash
# The gate: one command that builds the compiler, runs the suites in a fixed configuration, and writes a summary that reports quote.
#
#   scripts/gate.sh quick|wave|full [jobs]
#
#   quick  the NUL guard, whole-tree type check, default driver, and UI Showcase builds on HL/Wasm32/Wasm GC
#   wave   quick, then the driver again with HAXEON_CHECK_REUSE=1 (adds the warm-edit rebuilds and the reuse comparisons), then the Wasm
#          backend script (scripts/test-wasm-backend.sh; a broken Wasm fixture once reached main because no gate ran it) and the
#          self-hosting compile (tests/integration/test-compiler-embedding.sh: Haxeon compiles the compiler's own sources, which stock
#          Haxe does not check) and the external-tool build (a tool outside the tree links the compiler sources through common.hxml)
#   full   wave, then scripts/test.sh (the integration scripts CI runs)
#
# The compiler entry point and the build tool are built once, here, and handed to the driver; if either build fails the gate stops.
# The tracked tree must be clean (GATE_ALLOW_DIRTY=1 records "dirty" instead of refusing). Results go to out/gate/<commit>-<mode>-<time>/:
# a log per suite and summary.txt, whose lines are what a gate report quotes. The exit code is 0 only if every suite passed.
set -uo pipefail
mode=${1:?usage: gate.sh quick|wave|full [jobs]}
jobs=${2:-4}
case "$mode" in quick | wave | full) ;; *) echo "unknown mode: $mode" >&2; exit 2 ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2
commit=$(git rev-parse --short=8 HEAD)
state=clean
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	if [ "${GATE_ALLOW_DIRTY:-0}" != 1 ]; then
		echo "gate: the tracked tree has changes; commit them or set GATE_ALLOW_DIRTY=1" >&2
		git status --short --untracked-files=no >&2
		exit 2
	fi
	state=dirty
fi
stamp=$(date +%Y%m%d-%H%M%S)
out=$root/out/gate/$commit-$mode-$stamp
mkdir -p "$out"
summary=$out/summary.txt
hashlink_dir=$("$root/scripts/hashlink-path.sh")
work=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-gate.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
load() { cut -d' ' -f1 /proc/loadavg; }
started=$SECONDS
overall=0

{
	echo "commit: $commit ($state) branch: $(git branch --show-current)"
	echo "mode: $mode jobs: $jobs"
	echo "date: $(date -Is) load at start: $(load) cores: $(nproc)"
} >"$summary"

echo "gate: building the compiler entry point and the build tool"
export HAXEON_MAIN_HL=$work/haxeon-main.hl HAXEON_BUILD_HL=$work/haxeon-build.hl
if ! { "$root/scripts/build-native.sh" >"$out/build-native.log" 2>&1 &&
	"$root/.tools/haxe/haxe" --cwd "$root" common.hxml -hl "$HAXEON_MAIN_HL" -main Main >"$out/build-main.log" 2>&1 &&
	"$root/.tools/haxe/haxe" --cwd "$root" common.hxml -hl "$HAXEON_BUILD_HL" -main build.HaxeonBuild >"$out/build-tool.log" 2>&1; }; then
	echo "build: FAILED (see $out/build-*.log)" >>"$summary"
	echo "exit: 1" >>"$summary"
	cat "$summary"
	exit 1
fi
echo "build: ok" >>"$summary"

# Counts the program cases a driver log shows passing, by build kind.
coverage() {
	local log=$1
	local live plain warm pruned prunedWarm
	live=$(grep -c '^PASS: .* source compiled and executed' "$log" || true)
	plain=$(grep -c '^PASS: .* (plain build) source compiled and executed' "$log" || true)
	warm=$(grep -c '^PASS: .* (warm edit rebuilds) source compiled and executed' "$log" || true)
	pruned=$(grep -c '^PASS: .* (plain build, no early prune) source compiled and executed' "$log" || true)
	prunedWarm=$(grep -c '^PASS: .* (warm edit rebuilds, no early prune) source compiled and executed' "$log" || true)
	live=$((live - plain - warm - pruned - prunedWarm))
	echo "programs: $live live, $plain plain, $pruned plain+no-early-prune, warm-edit: $([ "$warm" -gt 0 ] && echo "yes ($warm)" || echo no), warm-edit+no-early-prune: $([ "$prunedWarm" -gt 0 ] && echo "yes ($prunedWarm)" || echo no)"
}

# suite <name> <command...>: runs it, logs it, and records its result line.
suite() {
	local name=$1
	shift
	local began=$SECONDS status=0
	echo "gate: $name"
	"$@" >"$out/$name.log" 2>&1 || status=$?
	local result
	result=$(grep -E '^Test driver: ' "$out/$name.log" | tail -1)
	echo "$name: exit $status, $((SECONDS - began)) s${result:+, $result}" >>"$summary"
	case "$name" in driver-*) echo "$name coverage: $(coverage "$out/$name.log")" >>"$summary" ;; esac
	[ "$status" -eq 0 ] || overall=1
}

suite nul-guard bash "$root/tests/integration/test-no-nul-literals.sh"
# Every module of the compiler and the build tool type-checks, not only the ones the entry point reaches: a switch over an IR enum in a module only
# tests compile (IrInterpreter) once broke the wave.
suite type-check-all "$root/.tools/haxe/haxe" --cwd "$root" common.hxml -cp tests/compiler \
	--macro "include('compiler')" --macro "include('build')" \
	-hl "$work/type-check-all.hl" --no-output -main Main
suite driver-default env -u HAXEON_CHECK_REUSE "$root/scripts/test-driver.sh" "$jobs"
# Example callers are outside the compiler and UI fixture roots; final-prop API ports must check the app too.
suite ui-showcase env -u HAXEON_COMPILER_HL bash "$root/packages/ui/tools/test-showcase-builds.sh"
if [ "$mode" != quick ]; then
	suite driver-checked env HAXEON_CHECK_REUSE=1 "$root/scripts/test-driver.sh" "$jobs"
	suite wasm-backend "$root/scripts/test-wasm-backend.sh"
	suite self-hosting bash "$root/tests/integration/test-compiler-embedding.sh"
	suite external-tool bash "$root/tests/integration/test-external-tool-build.sh"
fi
if [ "$mode" = full ]; then
	# scripts/test.sh stops at its first failing stage, and several stages are red on main (the formatter, the Wasm fixtures, the
	# profiler and native-kit integrations), so a "full" gate runs a copy that continues past failures and reports every stage:
	# the summary lists the failing ones, and a report compares that list with the same run at origin/main.
	continue_copy=$work/test-continue.sh
	sed -e 's/^set -euo pipefail/set -uo pipefail/' \
		-e 's@^root_dir=.*@root_dir=${HAXEON_GATE_ROOT:?}@' "$root/scripts/test.sh" >"$continue_copy"
	chmod +x "$continue_copy"
	suite full-test-sh env HAXEON_GATE_ROOT="$root" "$continue_copy"
	stages=$(grep -cE '^TIMING: [A-Za-z0-9_.-]+: [0-9]+s \(exit [0-9]+\)' "$out/full-test-sh.log" || true)
	failing=$(grep -E '^TIMING: [A-Za-z0-9_.-]+: [0-9]+s \(exit [1-9][0-9]*\)' "$out/full-test-sh.log" | sed -E 's/^TIMING: ([^:]+):.*/\1/' | sort | tr '\n' ' ')
	echo "full-test-sh stages: $stages, failing: ${failing:-none}" >>"$summary"
fi

{
	echo "elapsed: $((SECONDS - started)) s load at end: $(load)"
	echo "exit: $overall"
} >>"$summary"
cat "$summary"
exit "$overall"
