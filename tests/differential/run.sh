#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/../.." && pwd)
haxe="$root_dir/.tools/haxe/haxe"
hashlink_dir=$("$root_dir/scripts/hashlink-path.sh")
hl="$hashlink_dir/hl"
out_dir="$root_dir/out/differential"
runtime_library_variable=LD_LIBRARY_PATH
if [[ "$(uname -s)" == "Darwin" ]]; then
	runtime_library_variable=DYLD_LIBRARY_PATH
fi

run_hl() {
	local library_path=$1
	shift
	local existing="${!runtime_library_variable:-}"
	if [[ -n "$existing" ]]; then
		library_path="$library_path:$existing"
	fi
	env "$runtime_library_variable=$library_path" "$hl" "$@"
}

if [[ ! -x "$haxe" || ! -x "$hl" ]]; then
	echo "missing local toolchain; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

"$root_dir/scripts/build-native.sh" >/dev/null
mkdir -p "$out_dir"

# Compile with haxeon: the HashLink build of the compiler entry point the caller pinned (HAXEON_MAIN_HL), else the cached build of this
# tree's sources.
if [[ -z ${HAXEON_MAIN_HL:-} || ! -f $HAXEON_MAIN_HL ]]; then
	HAXEON_MAIN_HL=$("$root_dir/scripts/haxeon" dev tool-path Main)
fi
realtime_compile() {
	(cd "$root_dir" && run_hl "$root_dir/out:$hashlink_dir" "$HAXEON_MAIN_HL" "$1" "$2")
}

run_case() {
	local name=$1
	local expected_status=${2:-}
	local reference_target=${3:-hl}
	local official_source="$root_dir/tests/differential/$name.official.hx"
	# Named from the repository root, where realtime_compile runs: `trace` prints the path a file is given by.
	local realtime_source="tests/differential/$name.realtime.hx"
	local official_output="$out_dir/$name.official.hl"
	local realtime_output="$out_dir/$name.realtime.hl"
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official.XXXXXX")
	trap 'rm -rf "$official_dir"' RETURN
	cp "$official_source" "$official_dir/Main.hx"

	"$haxe" -cp "$official_dir" -main Main -hl "$official_output"
	realtime_compile "tests/differential/$name.realtime.hx" "$realtime_output" >/dev/null

	set +e
	local official_log="$out_dir/$name.official.log"
	local realtime_log="$out_dir/$name.realtime.log"
	if [[ "$reference_target" == interp ]]; then
		"$haxe" -cp "$official_dir" -main Main --interp >"$official_log" 2>&1
	else
		run_hl "$hashlink_dir" "$official_output" >"$official_log" 2>&1
	fi
	local official_status=$?
	run_hl "$root_dir/out:$hashlink_dir" "$realtime_output" >"$realtime_log" 2>&1
	local realtime_status=$?
	set -e

	if [[ -n "$expected_status" && $official_status -ne $expected_status ]]; then
		echo "$name: reference fixture expected exit $expected_status, got $official_status" >&2
		cat "$official_log" >&2
		exit 1
	fi
	if [[ $official_status -ne $realtime_status ]]; then
		echo "$name: official=$official_status realtime=$realtime_status" >&2
		echo "--- official output ---" >&2
		cat "$official_log" >&2 || true
		echo "--- realtime output ---" >&2
		cat "$realtime_log" >&2 || true
		exit 1
	fi
	if ! cmp -s "$official_log" "$realtime_log"; then
		echo "$name: observable output differs" >&2
		diff -u "$official_log" "$realtime_log" >&2 || true
		exit 1
	fi
	echo "PASS: $name official and realtime behavior agree (exit $official_status)"
}

run_compile_failure() {
	local name=$1
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official-failure.XXXXXX")
	cp "$root_dir/tests/differential/$name.official.hx" "$official_dir/Main.hx"
	set +e
	"$haxe" -cp "$official_dir" -main Main -hl "$out_dir/$name.official.hl" >/dev/null 2>&1
	local official_status=$?
	realtime_compile "tests/differential/$name.realtime.hx" "$out_dir/$name.realtime.hl" >/dev/null 2>&1
	local realtime_status=$?
	set -e
	rm -rf "$official_dir"
	if [[ $official_status -eq 0 || $realtime_status -eq 0 ]]; then
		echo "$name: expected both compilers to reject source (official=$official_status realtime=$realtime_status)" >&2
		exit 1
	fi
	echo "PASS: $name official and realtime compilers both reject invalid source"
}

# A known divergence: a program stock Haxe compiles and runs (exit 0) that Haxeon rejects until the step named beside the case lands
# (each is listed in docs/reference/LANGUAGE_SUPPORT.md). The check fails once Haxeon compiles it, so the case moves to run_case.
run_known_divergence() {
	local name=$1
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official-divergence.XXXXXX")
	trap 'rm -rf "$official_dir"' RETURN
	cp "$root_dir/tests/differential/$name.official.hx" "$official_dir/Main.hx"
	"$haxe" -cp "$official_dir" -main Main -hl "$out_dir/$name.official.hl"
	set +e
	run_hl "$hashlink_dir" "$out_dir/$name.official.hl" >"$out_dir/$name.official.log" 2>&1
	local official_status=$?
	realtime_compile "tests/differential/$name.realtime.hx" "$out_dir/$name.realtime.hl" >/dev/null 2>&1
	local realtime_status=$?
	set -e
	if [[ $official_status -ne 0 ]]; then
		echo "$name: the reference should run and exit 0, got $official_status" >&2
		cat "$out_dir/$name.official.log" >&2
		exit 1
	fi
	if [[ $realtime_status -eq 0 ]]; then
		echo "$name: Haxeon now compiles this known divergence; make it a run_case and drop it from LANGUAGE_SUPPORT.md" >&2
		exit 1
	fi
	echo "PASS: $name is still a known divergence (Haxe runs it, Haxeon rejects it)"
}

# Cases are independent; run them concurrently and report in order.
pids=()
logs=()
in_background() {
	local log="$out_dir/$2.run.log"
	("$@") >"$log" 2>&1 &
	pids+=($!)
	logs+=("$log")
}
in_background run_case arithmetic
in_background run_case fibonacci
in_background run_case control-flow
in_background run_case nullable
in_background run_case observable-output
in_background run_case compiler-audit
in_background run_case exception-capture-order 0
# Haxe 4.3.7's HL backend loses the final local write before this throw;
# its interpreter preserves it. Keep this case against the interpreter oracle.
in_background run_case exception-loop-control 0 interp
in_background run_case assignment-evaluation-order 0
in_background run_case interface-default-arguments 0
in_background run_case optional-argument-types 0
in_background run_case local-function-defaults 0
in_background run_case value-default-arguments 0
in_background run_case function-value-optional-arguments 0
in_background run_case local-inference-empty-array 0
in_background run_case local-inference-unassigned-local 0
in_background run_case local-inference-null-initializer 0
in_background run_case local-inference-empty-map 0
in_background run_case local-inference-object-literal-context 0
in_background run_case local-inference-int-float-widening 0
in_background run_case local-inference-unbound-dynamic 0
in_background run_case tuple-switch 0
in_background run_case generic-enum-constructor-inference 0
in_background run_case switch-shared-constructor-name 0
in_background run_case tuple-switch-null-element 0
in_background run_case recursive-generic-enum-nested-pattern 0
in_background run_case exception-catch-wrapping 0
in_background run_case exception-throw-null 0
in_background run_case exception-details 0
in_background run_case throw-type-check 0
in_background run_case callstack-abstract 0
in_background run_case abstract-properties 0
in_background run_compile_failure abstract-property-never-write
in_background run_case abstract-module-members 0
# Static initialization in Haxe's order (src/compiler/ir/StaticInitializationOrder.hx).
in_background run_case static-init-order 0
in_background run_case static-init-order-reach 0
in_background run_case switch-null-coverage 0
in_background run_case switch-guarded-catch-all 0
in_background run_case switch-bool 0
in_background run_case switch-nullable-enum-abstract 0
# Unannotated fields take their initializer's type, typed on demand (docs/design/LAZY_DECLARATION_TYPING.md, slice 3).
in_background run_case lazy-field-comprehension 0
in_background run_case lazy-field-map-lambda 0
in_background run_case lazy-field-order 0
in_background run_case lazy-field-call 0
in_background run_case lazy-generic-field 0
in_background run_compile_failure lazy-field-mixed-array
# Unannotated functions take their result and argument types from their bodies, typed on demand (slice 4).
in_background run_case lazy-return-several 0
in_background run_case lazy-return-recursive 0
in_background run_case lazy-return-object 0
in_background run_case lazy-return-call 0
in_background run_case lazy-argument-body 0
in_background run_case lazy-accessor 0
in_background run_case lazy-argument-generic 0
in_background run_case lazy-own-type-parameters 0
in_background run_compile_failure lazy-return-int-float
in_background run_compile_failure lazy-return-void-value
in_background run_compile_failure lazy-return-child-parent
in_background run_compile_failure lazy-override-mismatch
in_background run_compile_failure type-error
in_background run_compile_failure member-initializer-access
# Width subtyping between structures waits for structures lowered as views of one object (docs/design/STRUCTURE_VALUES.md, step 4):
# a copy into the narrower record would break identity (`narrow == wide`). The three rejections below are Haxe's too.
in_background run_known_divergence anonymous-width-subtyping
in_background run_compile_failure anonymous-width-missing-field
in_background run_compile_failure anonymous-width-final-to-var
in_background run_compile_failure anonymous-width-var-to-final
in_background run_compile_failure generic-enum-constructor-mixed-arguments
in_background run_compile_failure tuple-switch-missing-case
in_background run_compile_failure tuple-switch-nested-null-missing
in_background run_compile_failure switch-nested-null-missing
in_background run_compile_failure switch-bool-missing
# Haxe 4.3.7 rejects the next two by failing with Not_found while it names the missing null; Haxeon reports E1021.
in_background run_compile_failure switch-nested-nullable-enum-abstract-missing
in_background run_compile_failure tuple-switch-nested-nullable-enum-abstract-missing
in_background run_compile_failure tuple-switch-pattern-length
in_background run_compile_failure tuple-switch-binding
in_background run_compile_failure switch-wrong-enum-pattern
in_background run_compile_failure switch-wrong-enum-pattern-call
in_background run_compile_failure switch-wrong-enum-pattern-nested
in_background run_compile_failure switch-wrong-enum-pattern-array
in_background run_compile_failure tuple-switch-wrong-enum-pattern
status=0
for index in "${!pids[@]}"; do
	wait "${pids[$index]}" || status=1
	cat "${logs[$index]}"
done
exit "$status"
