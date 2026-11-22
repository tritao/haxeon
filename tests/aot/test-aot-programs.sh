#!/usr/bin/env bash
# The C backend's parity test (docs/design/AOT_BACKEND.md): each program listed in tests/aot/programs.txt (or named on the
# command line) is compiled for `hl` and for `hlc`, both are run, and their exit codes, stdout and stderr must match. A compile
# the C backend stops with "C backend:" counts as unsupported, not as a failure.
#   tests/aot/test-aot-programs.sh [-v] [--all] [NAME...]
# NAME is a tests/programs file without .hx, or a path to a .hx file; --all takes every program of expected-exits.tsv.
# TEST_JOBS programs run at once (default 4); TOOLCHAIN is the hlc build's --toolchain (gcc, clang, clang-cl, cl; default the
# hlc SDK's target's);
# HLC_BUILD_MODE is the hlc build's mode (default development, whose frames are exact; release inlines).
set -uo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
source "$root_dir/scripts/lib/env.sh"
source "$root_dir/scripts/lib/haxeon-compiler.sh"
verbose=0
programs=()
while (($# > 0)); do
	case $1 in
	-v) verbose=1 ;;
	--all) mapfile -t -O "${#programs[@]}" programs < <(grep -v '^#' "$root_dir/tests/programs/expected-exits.tsv" | cut -f1 | sed '/^$/d') ;;
	*) programs+=("$1") ;;
	esac
	shift
done
if ((${#programs[@]} == 0)); then
	mapfile -t programs < <(grep -v '^#' "$root_dir/tests/aot/programs.txt" | sed '/^$/d')
fi
out_dir=${HAXEON_AOT_OUTPUT_DIR:-$haxeon_suite_out/aot-tests}
sdk=${HAXEON_HLC_SDK:-$(dirname "$hashlink_dir")/hlc-sdk}
toolchain=${TOOLCHAIN:-}
build_mode=${HLC_BUILD_MODE:-development}
jobs=${TEST_JOBS:-4}
mkdir -p "$out_dir"
export TZ=Asia/Kolkata

# Compiles and runs one program both ways; writes its verdict to WORK/result: ok, FAIL ..., UNSUPPORTED ... or SKIP ...
check_program() {
	local program=$1 source_file root name work
	if [[ $program == *.hx ]]; then source_file=$program; root=$(dirname "$program"); else source_file=tests/programs/$program.hx; root=tests/programs; fi
	name=$(basename "$source_file" .hx)
	work="$out_dir/$name"
	rm -rf "$work"
	mkdir -p "$work"
	run() {
		local prefix=$1
		shift
		(cd "$root_dir" && timeout 60 "$@" > "$work/$prefix.out" 2> "$work/$prefix.err")
		echo $? > "$work/$prefix.exit"
	}
	if ! haxeon_compile --output="$work/$name.hl" --entry="$name" --root="$root" --root=stdlib "$source_file" > "$work/hl.log" 2>&1; then
		echo "SKIP $name (the hl compile fails)" > "$work/result"
		return
	fi
	run hl "$haxeon_hl" "$work/$name.hl"
	if ! haxeon_compile --target=hlc --build-mode="$build_mode" ${toolchain:+--toolchain="$toolchain"} --c-sdk="$sdk" --output="$work/$name" --entry="$name" --root="$root" \
		--root=stdlib "$source_file" > "$work/hlc.log" 2>&1; then
		if grep -q "C backend:" "$work/hlc.log"; then
			echo "UNSUPPORTED $name: $(grep -o 'C backend: .*' "$work/hlc.log" | head -1 | cut -c1-160)" > "$work/result"
		else
			echo "FAIL $name (hlc compile: $(grep -m1 'Uncaught\|failed' "$work/hlc.log" | cut -c1-160))" > "$work/result"
		fi
		return
	fi
	run hlc "$work/$name"
	if cmp -s "$work/hl.exit" "$work/hlc.exit" && cmp -s "$work/hl.out" "$work/hlc.out" && cmp -s "$work/hl.err" "$work/hlc.err"; then
		echo "ok $name" > "$work/result"
	else
		echo "FAIL $name (exit $(cat "$work/hl.exit") vs $(cat "$work/hlc.exit"); $work)" > "$work/result"
	fi
}

pids=()
for program in "${programs[@]}"; do
	if ((${#pids[@]} >= jobs)); then
		wait "${pids[0]}"
		pids=("${pids[@]:1}")
	fi
	check_program "$program" &
	pids+=($!)
done
wait
passed=0 failed=0 unsupported=0 skipped=0
for program in "${programs[@]}"; do
	result=$(cat "$out_dir/$(basename "$program" .hx)/result" 2>/dev/null || echo "FAIL $program (no result)")
	case $result in
	ok*) passed=$((passed + 1)); ((verbose)) && echo "$result" ;;
	UNSUPPORTED*) unsupported=$((unsupported + 1)); ((verbose)) && echo "$result" ;;
	SKIP*) skipped=$((skipped + 1)); echo "$result" ;;
	*) failed=$((failed + 1)); echo "$result" ;;
	esac
done
echo "aot programs: $passed passed, $failed failed, $unsupported unsupported, $skipped skipped"
((failed == 0))
