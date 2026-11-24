#!/usr/bin/env bash
# The C backend's parity test (docs/design/AOT_BACKEND.md): each program listed in tests/aot/programs.txt (or named on the
# command line) is compiled for `hl` and for `hlc`, both are run, and their exit codes, stdout and stderr must match. A compile
# the C backend stops with "C backend:" counts as unsupported, not as a failure.
#   tests/aot/test-aot-programs.sh [-v] [--all] [--sanitize] [NAME...]
# NAME is a tests/programs file without .hx, or a path to a .hx file; --all takes every program of expected-exits.tsv.
# --sanitize builds the C with AddressSanitizer and UndefinedBehaviorSanitizer, and the check of a float converted out of its
# target's range, which `undefined` leaves out (gcc or clang); a report stops the program, so it fails the comparison.
# The C is built through cmake/aot with the SDK's CMake package (HAXEON_SDK, default out/sdk). TEST_JOBS programs run at once
# (default 4); TOOLCHAIN is the C compiler CMake builds with (gcc, clang, clang-cl, cl, or a path; default CMake's choice, CC);
# HLC_BUILD_MODE is the hlc build's mode (default development, whose frames are exact; release inlines). AOT_PROGRAMS_COMPILER, when
# set, is a compiler executable that does both compiles instead of the compiler on the VM, which stock Haxe built: the aot-compiler
# suite sets it to the compiler built ahead of time, so the C backend's own code also runs as Haxeon compiles it.
set -uo pipefail
root_dir=$(cd "$(dirname "$0")/../.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
source "$root_dir/scripts/lib/env.sh"
source "$root_dir/scripts/lib/haxeon-compiler.sh"
if [[ -n ${AOT_PROGRAMS_COMPILER:-} ]]; then
	haxeon_compile() { (cd "$root_dir" && "$AOT_PROGRAMS_COMPILER" "$@"); }
fi
verbose=0
sanitize=0
programs=()
while (($# > 0)); do
	case $1 in
	-v) verbose=1 ;;
	--sanitize) sanitize=1 ;;
	--all) while IFS= read -r program; do programs+=("$program"); done < <(grep -v '^#' "$root_dir/tests/programs/expected-exits.tsv" | cut -f1 | sed '/^$/d') ;;
	*) programs+=("$1") ;;
	esac
	shift
done
if ((${#programs[@]} == 0)); then
	while IFS= read -r program; do programs+=("$program"); done < <(grep -v '^#' "$root_dir/tests/aot/programs.txt" | sed '/^$/d')
fi
out_dir=${HAXEON_AOT_OUTPUT_DIR:-$haxeon_suite_out/aot-tests}
sdk=${HAXEON_SDK:-$root_dir/out/sdk}
toolchain=${TOOLCHAIN:-}
build_mode=${HLC_BUILD_MODE:-development}
jobs=${TEST_JOBS:-4}
ninja=ninja
for pinned in "$root_dir/.tools/ninja/ninja" "$root_dir/.tools/ninja/ninja.exe"; do
	if [[ -x $pinned ]]; then ninja=$pinned; fi
done
development=$([[ $build_mode == development ]] && echo ON || echo OFF)
sanitizer_flags=()
if ((sanitize)); then
	sanitizers="-fsanitize=address,undefined,float-cast-overflow -fno-sanitize-recover=all -fno-omit-frame-pointer"
	sanitizer_flags=(-DCMAKE_C_FLAGS="$sanitizers" -DCMAKE_EXE_LINKER_FLAGS="$sanitizers")
	# The collector scans the native stack for references: a frame AddressSanitizer moved to the heap would hide them.
	export ASAN_OPTIONS=detect_leaks=0:detect_stack_use_after_return=0
	export UBSAN_OPTIONS=print_stacktrace=1
fi
# Why a sanitized build cannot run program NAME, or nothing.
sanitize_skip() {
	case $1 in
	gc-dump-paths) echo "a heap dump writes the native stack as it is, AddressSanitizer's poisoned redzones included" ;;
	esac
}
mkdir -p "$out_dir"

# Builds the executable WORK/NAME from the C in WORK/NAME.c.
build_c() {
	local work=$1 name=$2
	cmake -S "$root_dir/cmake/aot" -B "$work/build" -G Ninja -DCMAKE_MAKE_PROGRAM="$ninja" -DHaxeon_DIR="$sdk/cmake" \
		-DC_SOURCES="$work/$name.c" -DOUTPUT="$work/$name" -DDEVELOPMENT="$development" ${toolchain:+-DCMAKE_C_COMPILER="$toolchain"} ${sanitizer_flags[@]+"${sanitizer_flags[@]}"} \
		&& cmake --build "$work/build"
}
export TZ=Asia/Kolkata

# Compiles and runs one program both ways; writes its verdict to WORK/result: ok, FAIL ..., UNSUPPORTED ... or SKIP ...
check_program() {
	local program=$1 source_file root name work
	if [[ $program == *.hx ]]; then source_file=$program; root=$(dirname "$program"); else source_file=tests/programs/$program.hx; root=tests/programs; fi
	name=$(basename "$source_file" .hx)
	work="$out_dir/$name"
	rm -rf "$work"
	mkdir -p "$work"
	if ((sanitize)) && [[ -n $(sanitize_skip "$name") ]]; then
		echo "SKIP $name (sanitized: $(sanitize_skip "$name"))" > "$work/result"
		return
	fi
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
	if ! haxeon_compile --target=hlc --build-mode="$build_mode" --output="$work/$name" --entry="$name" --root="$root" \
		--root=stdlib "$source_file" > "$work/hlc.log" 2>&1; then
		if grep -q "C backend:" "$work/hlc.log"; then
			echo "UNSUPPORTED $name: $(grep -o 'C backend: .*' "$work/hlc.log" | head -1 | cut -c1-160)" > "$work/result"
		else
			echo "FAIL $name (hlc compile: $(grep -m1 'Uncaught\|failed' "$work/hlc.log" | cut -c1-160))" > "$work/result"
		fi
		return
	fi
	if ! build_c "$work" "$name" > "$work/c-build.log" 2>&1; then
		echo "FAIL $name (C build: $(grep -m1 'error' "$work/c-build.log" | cut -c1-160); $work/c-build.log)" > "$work/result"
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
