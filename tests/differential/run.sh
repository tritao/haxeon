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

# The source Haxeon compiles for a case: the realtime file as it is, or, for a case whose source names its own module (`using
# Main.Tools`, `@:using(Main.ShapeTools)`, which is how Haxe names a type of the file it is in), a copy named Main.hx as Haxe's is.
realtime_case_source() {
	local name=$1
	local module=${2:-}
	if [[ "$module" == main ]]; then
		local realtime_dir
		realtime_dir=$(mktemp -d "$out_dir/realtime.XXXXXX")
		cp "$root_dir/tests/differential/$name.realtime.hx" "$realtime_dir/Main.hx"
		echo "$realtime_dir/Main.hx"
	else
		echo "tests/differential/$name.realtime.hx"
	fi
}

run_case() {
	local name=$1
	local expected_status=${2:-}
	local reference_target=${3:-hl}
	local official_source="$root_dir/tests/differential/$name.official.hx"
	# Named from the repository root, where realtime_compile runs: `trace` prints the path a file is given by.
	local realtime_source
	realtime_source=$(realtime_case_source "$name" "${4:-}")
	local official_output="$out_dir/$name.official.hl"
	local realtime_output="$out_dir/$name.realtime.hl"
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official.XXXXXX")
	trap 'rm -rf "$official_dir"' RETURN
	cp "$official_source" "$official_dir/Main.hx"

	"$haxe" -cp "$official_dir" -main Main -hl "$official_output"
	realtime_compile "$realtime_source" "$realtime_output" >/dev/null

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
	local official_dir realtime_source
	official_dir=$(mktemp -d "$out_dir/official-failure.XXXXXX")
	cp "$root_dir/tests/differential/$name.official.hx" "$official_dir/Main.hx"
	realtime_source=$(realtime_case_source "$name" "${2:-}")
	set +e
	"$haxe" -cp "$official_dir" -main Main -hl "$out_dir/$name.official.hl" >/dev/null 2>&1
	local official_status=$?
	realtime_compile "$realtime_source" "$out_dir/$name.realtime.hl" >/dev/null 2>&1
	local realtime_status=$?
	set -e
	rm -rf "$official_dir"
	if [[ $official_status -eq 0 || $realtime_status -eq 0 ]]; then
		echo "$name: expected both compilers to reject source (official=$official_status realtime=$realtime_status)" >&2
		exit 1
	fi
	echo "PASS: $name official and realtime compilers both reject invalid source"
}

# Compile warnings of one kind: the line and message of each, once, from both compilers. Haxe prints
# `Main.hx:77: lines 77-79 : Warning : (WStaticInitOrder) Warning : maybe loop ...`, as often as it reaches it; Haxeon
# `tests/differential/x.realtime.hx:77:1: W1002: maybe loop ...`, once, naming a type of the file's module `x.realtime` as
# `x.Type` (the file name's first part reads as a package). The program's run is compared by run_case.
run_warning_case() {
	local name=$1
	local message=$2
	local official_dir
	official_dir=$(mktemp -d "$out_dir/official-warning.XXXXXX")
	trap 'rm -rf "$official_dir"' RETURN
	cp "$root_dir/tests/differential/$name.official.hx" "$official_dir/Main.hx"
	local official_warnings realtime_warnings
	official_warnings=$(cd "$official_dir" && "$haxe" -cp . -main Main -hl "$out_dir/$name.warning.official.hl" 2>&1 |
		sed -n "s/^Main\.hx:\([0-9]*\):.*Warning : \($message.*\)$/\1 \2/p" | sort -u)
	realtime_warnings=$(realtime_compile "tests/differential/$name.realtime.hx" "$out_dir/$name.warning.realtime.hl" 2>&1 >/dev/null |
		sed -n "s/^tests\/differential\/$name\.realtime\.hx:\([0-9]*\):[0-9]*: W[0-9]*: \($message.*\)$/\1 \2/p" |
		sed "s/ $name\./ /" | sort -u)
	if [[ -z "$official_warnings" ]]; then
		echo "$name: the reference printed no \"$message\" warning" >&2
		exit 1
	fi
	if [[ "$official_warnings" != "$realtime_warnings" ]]; then
		echo "$name: warnings differ" >&2
		diff -u <(echo "$official_warnings") <(echo "$realtime_warnings") >&2 || true
		exit 1
	fi
	echo "PASS: $name official and realtime compilers warn alike ($(echo "$official_warnings" | wc -l) warnings)"
}

# A compile error: the line, column and message of the first error each compiler reports. Haxe prints
# `Main.hx:12: characters 11-16 : Counter has no field reset`, Haxeon `.../Main.hx:12:11: E1005: Counter has no field reset`; both
# compile the case as Main.hx, so the types of its module are named alike. The modules in `name.modules/`, if any, are beside it.
run_error_case() {
	local name=$1
	local official_dir realtime_source
	realtime_source=$(realtime_case_source "$name" main)
	official_dir=$(mktemp -d "$out_dir/official-error.XXXXXX")
	trap 'rm -rf "$official_dir"' RETURN
	cp "$root_dir/tests/differential/$name.official.hx" "$official_dir/Main.hx"
	if [[ -d "$root_dir/tests/differential/$name.modules" ]]; then
		cp "$root_dir/tests/differential/$name.modules/"*.hx "$official_dir/"
		cp "$root_dir/tests/differential/$name.modules/"*.hx "$(dirname "$realtime_source")/"
	fi
	# Both compilers fail, so their status is not checked here (pipefail).
	local official_error realtime_error
	official_error=$(cd "$official_dir" && "$haxe" -cp . -main Main -hl "$out_dir/$name.error.official.hl" 2>&1 |
		sed -n 's/^Main\.hx:\([0-9]*\): characters \([0-9]*\)-[0-9]* : \(.*\)$/\1:\2 \3/p' | head -n 1 || true)
	realtime_error=$(realtime_compile "$realtime_source" "$out_dir/$name.error.realtime.hl" 2>&1 >/dev/null |
		sed -n 's/^.*\/Main\.hx:\([0-9]*\):\([0-9]*\): E[0-9]*: \(.*\)$/\1:\2 \3/p' | head -n 1 || true)
	rm -rf "$(dirname "$realtime_source")"
	if [[ -z "$official_error" ]]; then
		echo "$name: the reference reported no error" >&2
		exit 1
	fi
	if [[ "$official_error" != "$realtime_error" ]]; then
		echo "$name: errors differ" >&2
		diff -u <(echo "$official_error") <(echo "$realtime_error") >&2 || true
		exit 1
	fi
	echo "PASS: $name official and realtime compilers report the same error ($official_error)"
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

# Cases are independent; run them concurrently and report in order. At most TEST_JOBS (else one per CPU) run at a time:
# all of them at once (several hundred processes, each compiling) ran a 16 GB runner out of memory.
jobs_limit=${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
pids=()
logs=()
in_background() {
	# Bash 3.2 (macOS) has no `wait -n`: wait for a slot by polling the running jobs.
	while (( $(jobs -rp | wc -l) >= jobs_limit )); do sleep 0.1; done
	local log="$out_dir/$2.$1.log"
	("$@") >"$log" 2>&1 &
	pids+=($!)
	logs+=("$log")
}
in_background run_case arithmetic
in_background run_case fibonacci
in_background run_case control-flow
in_background run_case nullable
in_background run_case observable-output
in_background run_case bytes-access 0
in_background run_case bytes-bounds 0
in_background run_case bytes-encoding 0
in_background run_case compiler-audit
in_background run_case exception-capture-order 0
# Haxe 4.3.7's HL backend loses the final local write before this throw;
# its interpreter preserves it. Keep this case against the interpreter oracle.
in_background run_case exception-loop-control 0 interp
in_background run_case assignment-evaluation-order 0
in_background run_case interface-default-arguments 0
in_background run_case optional-argument-types 0
in_background run_case local-function-defaults 0
# A local inline function is its body at each call; it is never a value and never calls itself (LocalInlineFunctions).
in_background run_case local-inline-functions 0
in_background run_compile_failure local-inline-function-value
in_background run_compile_failure local-inline-function-recursive
in_background run_case local-inline-function-shadowed-capture 0
in_background run_case value-default-arguments 0
in_background run_case function-value-optional-arguments 0
in_background run_case local-inference-empty-array 0
in_background run_case local-inference-unassigned-local 0
in_background run_case local-inference-null-initializer 0
in_background run_case local-inference-empty-map 0
in_background run_case local-inference-object-literal-context 0
in_background run_case local-inference-int-float-widening 0
in_background run_case local-inference-unbound-dynamic 0
# A later use's expected type no longer types what flows in before it (docs/design/STRUCTURE_VALUES.md, slice 6).
in_background run_compile_failure local-inference-push-int-as-float
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
# Every member of an abstract is typed, called or not.
in_background run_case abstract-uncalled-members 0
in_background run_compile_failure abstract-uncalled-member-error
# An abstract's from/to conversions unify as Haxe's do: Int meets Float, a class its base; one abstract never chains to another.
in_background run_case abstract-from-to-widening 0
in_background run_compile_failure abstract-from-to-not-chained
# A generic abstract's construction infers its type arguments as Haxe does: from the arguments, then the expected type.
in_background run_case abstract-construction-inference 0
in_background run_compile_failure abstract-construction-inference-mismatch
# An abstract's static variables, in Haxe's initialization order (AbstractStatics).
in_background run_case abstract-statics 0
in_background run_compile_failure abstract-static-private
# An enum abstract has an abstract's members besides its values; a value has the abstract's type.
in_background run_case enum-abstract-members 0
in_background run_compile_failure enum-abstract-value-type
in_background run_case switch-enum-abstract-value-names 0
in_background run_case cast-expression-extent 0
in_background run_case array-index-dynamic 0
in_background run_case enum-creation 0 hl main
in_background run_case abstract-to-string 0
in_background run_case abstract-keyword-value 0
# A lambda whose body is an `if` without an `else` is a Void function.
in_background run_case lambda-if-without-else 0
# Static properties with accessors, of a class and of an abstract (StaticProperties).
in_background run_case static-properties 0
in_background run_compile_failure static-property-never-write
in_background run_compile_failure static-property-missing-accessor
in_background run_case instance-properties 0
# An assignment used as a value is the setter's result where a setter stores it, else the value stored.
in_background run_case assignment-values 0
in_background run_case abstract-generic-structure 0
in_background run_case constrained-type-parameter-members 0
in_background run_case constrained-type-parameter-assignment 0
in_background run_compile_failure uncalled-generic-error
in_background run_compile_failure uncalled-generic-method-error
in_background run_error_case missing-field-call-instance
in_background run_error_case missing-field-call-chained
in_background run_error_case missing-field-call-static
in_background run_error_case missing-field-call-abstract
in_background run_error_case missing-field-call-abstract-static
in_background run_error_case missing-field-call-bytes
in_background run_error_case missing-field-call-nullable
in_background run_error_case missing-field-call-function
in_background run_error_case missing-field-call-subtype
in_background run_error_case local-function-assignment
in_background run_compile_failure generic-field-own-parameters-error
in_background run_case generic-nullable-parameter-read 0
in_background run_case generic-nullable-element-inference 0
in_background run_compile_failure instance-property-never-write
in_background run_compile_failure instance-property-never-read
in_background run_compile_failure instance-property-missing-accessor
# An interface's variables and properties: an access through the interface reaches the object's variable or accessor.
in_background run_case interface-variables 0
in_background run_compile_failure interface-variable-missing
in_background run_compile_failure interface-variable-access-mismatch
in_background run_compile_failure interface-property-never-write
# @:hlNative on a function with a body binds the native; the body is typed and never runs.
in_background run_case hlnative-body 0
in_background run_compile_failure hlnative-body-error
in_background run_case abstract-module-members 0
# `(value : Type)` is Haxe's type check: the value unifies with the type and converts to it; it never casts.
in_background run_case type-check 0
in_background run_compile_failure type-check-mismatch
in_background run_compile_failure type-check-downcast
# Static initialization in Haxe's order (src/compiler/ir/pipeline/StaticInitializationOrder.hx).
in_background run_case static-init-order 0
in_background run_case static-init-order-reach 0
# A loop in that order warns as Haxe does ("maybe loop in static generation of"), at the class.
in_background run_warning_case static-init-order "maybe loop in static generation"
in_background run_warning_case static-init-order-reach "maybe loop in static generation"
in_background run_case static-init-order-loop 0
in_background run_warning_case static-init-order-loop "maybe loop in static generation"
in_background run_case switch-null-coverage 0
in_background run_case switch-guarded-catch-all 0
in_background run_case switch-bool 0
in_background run_case switch-nullable-enum-abstract 0
# A lowercase name in a pattern captures even where a function or variable of that name is in scope.
in_background run_case pattern-capture-shadows-name 0
# Haxe's Lambda over arrays and maps (stdlib/Lambda.hx).
in_background run_case lambda-functions 0
in_background run_case lambda-empty-literal 0
in_background run_case lambda-flatten 0
# A generic call's type argument a later statement fixes: Haxeon specializes the call when it types it.
in_background run_known_divergence lambda-unfixed-before-call
# A callback's result fills the type parameters it mentions, and an empty literal's element settles at the call (08d893179).
in_background run_case callback-result-structure-variable 0
in_background run_case callback-result-left-open 0
in_background run_case callback-result-typedef-parameter 0
in_background run_case generic-empty-literal-arguments 0
# `value.match(pattern)`: a switch with one case that binds no names, as in Haxe.
in_background run_case enum-match 0
in_background run_compile_failure enum-match-pattern-variable
in_background run_compile_failure enum-match-payload-variable
in_background run_compile_failure enum-match-capture
# Static extensions (`using`, `@:using`) in Haxe's order, after the value's own members (src/compiler/types/typing/StaticExtensions.hx).
in_background run_case using-static-extensions 0 hl main
in_background run_compile_failure using-private-static main
in_background run_compile_failure using-base-statics main
in_background run_compile_failure using-class-reference main
in_background run_compile_failure using-extension-arguments main
in_background run_compile_failure using-no-first-argument main
in_background run_case using-extension-values 0 hl main
in_background run_compile_failure using-type-parameter-missing main
in_background run_known_divergence using-extension-value-open
# Type.enumConstructor, Type.enumParameters and Haxe's global EnumValueTools (src/compiler/types/typing/EnumReflection.hx).
in_background run_case enum-reflection 0 hl main
in_background run_compile_failure enum-value-tools-arguments
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
# An object literal's structure stays open while its unit is typed and gains the optional fields of the structures it meets
# (docs/design/STRUCTURE_VALUES.md, slice 5). Gaining from two structures, or after a narrower use, needs width (slice 4).
in_background run_case structure-open-literal 0
in_background run_case structure-open-literal-optional-field 0
in_background run_known_divergence structure-open-literal-two-uses
in_background run_compile_failure structure-open-literal-conflicting-field
in_background run_compile_failure structure-open-literal-required-field
in_background run_compile_failure structure-open-literal-returned
in_background run_compile_failure structure-declared-no-gain
in_background run_case structure-function-fields 0
in_background run_compile_failure structure-function-field-rebind
in_background run_case structure-property-fields 0
in_background run_compile_failure structure-property-field-write
# A class instance as a structure waits for structures lowered as views of one object (docs/design/STRUCTURE_VALUES.md, step 4).
in_background run_known_divergence structure-from-class
in_background run_compile_failure generic-enum-constructor-mixed-arguments
in_background run_compile_failure tuple-switch-missing-case
# A tuple switch statement may leave values of its first decided Int or String element unmatched, as Haxe's matcher allows.
in_background run_case tuple-switch-statement-open 0
in_background run_compile_failure tuple-switch-statement-later-gap
in_background run_compile_failure tuple-switch-statement-constructor-gap
# Structure patterns match as the tuple switch of the fields they name (src/compiler/types/typing/StructurePatterns.hx).
in_background run_case structure-patterns 0
in_background run_compile_failure structure-pattern-missing-constructor
in_background run_compile_failure structure-pattern-value-missing
in_background run_compile_failure structure-pattern-unknown-field
# `case null` beside structure patterns; a switch of `_`, names and `null` over any value.
in_background run_case structure-null-case 0
in_background run_compile_failure structure-pattern-null-missing
# Extractor patterns match as nested switches (src/compiler/types/typing/ExtractorPatterns.hx).
in_background run_case extractor-patterns 0
in_background run_compile_failure extractor-pattern-value-missing
in_background run_compile_failure extractor-pattern-missing-constructor
# A whole-case extractor on a tuple switch reads no value; an element's does (extractor-nested).
in_background run_compile_failure extractor-tuple-whole
# Extractors nested in a pattern match under it, sharing their evaluation as Haxe does.
in_background run_case extractor-nested 0
in_background run_compile_failure extractor-nested-missing
# Indexing a Dynamic value reads and writes the array it holds (haxeon.DynamicOps.index, setIndex).
in_background run_case dynamic-index 0
in_background run_case dynamic-index-storage 0
in_background run_compile_failure dynamic-index-string-key
# Rest parameters: `...values:T` is a haxe.Rest<T> of the arguments from its position on (RestArguments).
in_background run_case rest-parameters 0 hl main
in_background run_case rest-function-type 0
in_background run_compile_failure rest-parameter-not-last
in_background run_compile_failure rest-spread-not-last
in_background run_compile_failure rest-spread-no-rest
in_background run_compile_failure rest-argument-type
in_background run_compile_failure tuple-switch-nested-null-missing
in_background run_compile_failure switch-nested-null-missing
in_background run_compile_failure switch-bool-missing
in_background run_case switch-shared-patterns 0
in_background run_case local-scoping 0
in_background run_case capture-storage 0
in_background run_case capture-shadowed-in-lambda 0
in_background run_case local-redeclared-same-block 0
in_background run_compile_failure switch-pattern-missing-binding
in_background run_compile_failure switch-pattern-binding-type
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
