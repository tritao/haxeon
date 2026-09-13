#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
wasmtime_bin=${WASMTIME:-wasmtime}

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
if ! command -v "$wasmtime_bin" >/dev/null 2>&1; then
	echo "missing Wasmtime 47.0.0; install it or set WASMTIME to its executable" >&2
	exit 1
fi

wasmtime_version=$("$wasmtime_bin" --version)
if [[ "$wasmtime_version" != *"47.0.0"* ]]; then
	echo "expected Wasmtime 47.0.0, got: $wasmtime_version" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe_bin" --cwd "$root_dir" -cp src -cp tests/compiler --run WasmBackendMain
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm-gc --output=out/wasm-gc-wasmtime-bytes.wasm --entry=wasm-gc-bytes \
	--root=tests/programs tests/programs/wasm-gc-bytes.hx

for case_name in add expression-lambda switch-expression-block member-range trailing-object-comma block-comprehension transparent-abstract computed-field-assignment assignment-expression literal-postfix bitwise bitwise-comparison-precedence type-annotation local-function switch-guard callback-method bound-method name-collision bool-if fib while-arithmetic branch-assignment static-class static-field static-field-init instance-class instance-field-init instance-field-init-constructor default-constructor-class enum-basic enum-payload enum-payload-pattern generic-enum-field nullable-guard-return nullable-array-guard native-abstract-null nullable-enum-switch array-mutation wasm-gc-invariants increment logical-comparisons negation switch-subject-binding enum-exhaustive try-return try-branch try-loop-control try-outer-local try-branch-local try-call-local local-shadowing captured-shadowing dynamic-argument switch-expression string-switch-statement switch-inline-final throw-expression array-literal empty-array-flow-inference do-while postfix-increment optional-enum-parameter call-many function-call function-value lambda single-argument-lambda contextual-callbacks enum-array-pattern anonymous-function enum-abstract computed-property mutable-capture nested-mutable-capture captured-lambda captured-this nullable-basic nullable-compound object-array for-in loop-control modulo switch-enum multiple-implements captured-method anonymous-record array-comprehension filtered-array-comprehension range-iteration cast-expression optional-argument-forwarding default-parameter-inference generic-functions generic-abstract bounded-generic generic-class array-iterator-wasm array-slice-index array-growth-wasm array-alias-growth array-index-growth array-resize array-expression-mutation array-field-mutation array-copy-concat array-unshift array-insert array-splice array-remove array-object-mutation array-reverse dynamic-equality numeric-promotion function-wrapper inheritance-class override-method virtual-dispatch wasm-gc-reuse std-is-of-type map-basic map-int map-primitive-types map-literal map-object map-anonymous-enum map-for-in map-key-value-for-in map-comprehension map-nullable-get nullable-map-get map-string-equality string-concat-mixed string-split string-split-edge string-from-char-code bytes-codec bytes-stream-edge reflect-compare-sort generic-interface generic-contextual-callback interface-dispatch interface-inheritance interface-upcast interface-field try-catch try-nested try-array-bounds concise-try try-typed-class try-typed-mismatch try-typed-int try-multiple-catches enum-argument-string string-interpolation std-string-dynamic compiler-audit-regressions wasm-gc-string-operations; do
	"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
		--target=wasm-gc --output="out/wasm-gc-wasmtime-$case_name.wasm" --entry="$case_name" \
		--root=tests/programs "tests/programs/$case_name.hx"
done

"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm-gc --output=out/wasm-gc-wasmtime-bytes-compare.wasm --entry=wasm-bytes-compare \
	--root=tests/programs tests/programs/wasm-bytes-compare.hx

for artifact in \
	wasm-gc-model \
	wasm-eh-try-table \
	wasm-gc-type-plan \
	wasm-gc-objects \
	wasm-gc-arrays \
	wasm-gc-enums \
	wasm-gc-closures \
	wasm-gc-dynamic \
	wasm-gc-exceptions \
	wasm-gc-strings \
	wasm-gc-wasmtime-bytes \
	wasm-gc-wasmtime-add \
	wasm-gc-wasmtime-expression-lambda \
	wasm-gc-wasmtime-switch-expression-block \
	wasm-gc-wasmtime-member-range \
	wasm-gc-wasmtime-trailing-object-comma \
	wasm-gc-wasmtime-block-comprehension \
	wasm-gc-wasmtime-transparent-abstract \
	wasm-gc-wasmtime-computed-field-assignment \
	wasm-gc-wasmtime-assignment-expression \
	wasm-gc-wasmtime-literal-postfix \
	wasm-gc-wasmtime-bitwise \
	wasm-gc-wasmtime-bitwise-comparison-precedence \
	wasm-gc-wasmtime-type-annotation \
	wasm-gc-wasmtime-local-function \
	wasm-gc-wasmtime-switch-guard \
	wasm-gc-wasmtime-callback-method \
	wasm-gc-wasmtime-bound-method \
	wasm-gc-wasmtime-name-collision \
	wasm-gc-wasmtime-bool-if \
	wasm-gc-wasmtime-fib \
	wasm-gc-wasmtime-while-arithmetic \
	wasm-gc-wasmtime-branch-assignment \
	wasm-gc-wasmtime-static-class \
	wasm-gc-wasmtime-static-field \
	wasm-gc-wasmtime-static-field-init \
	wasm-gc-wasmtime-instance-class \
	wasm-gc-wasmtime-instance-field-init \
	wasm-gc-wasmtime-instance-field-init-constructor \
	wasm-gc-wasmtime-default-constructor-class \
	wasm-gc-wasmtime-enum-basic \
	wasm-gc-wasmtime-enum-payload \
	wasm-gc-wasmtime-enum-payload-pattern \
	wasm-gc-wasmtime-generic-enum-field \
	wasm-gc-wasmtime-nullable-guard-return \
	wasm-gc-wasmtime-nullable-array-guard \
	wasm-gc-wasmtime-native-abstract-null \
	wasm-gc-wasmtime-nullable-enum-switch \
	wasm-gc-wasmtime-array-mutation \
	wasm-gc-wasmtime-wasm-gc-invariants \
	wasm-gc-wasmtime-increment \
	wasm-gc-wasmtime-logical-comparisons \
	wasm-gc-wasmtime-negation \
	wasm-gc-wasmtime-switch-subject-binding \
	wasm-gc-wasmtime-enum-exhaustive \
	wasm-gc-wasmtime-try-return \
	wasm-gc-wasmtime-try-branch \
	wasm-gc-wasmtime-try-loop-control \
	wasm-gc-wasmtime-try-outer-local \
	wasm-gc-wasmtime-try-branch-local \
	wasm-gc-wasmtime-try-call-local \
	wasm-gc-wasmtime-local-shadowing \
	wasm-gc-wasmtime-captured-shadowing \
	wasm-gc-wasmtime-dynamic-argument \
	wasm-gc-wasmtime-switch-expression \
	wasm-gc-wasmtime-string-switch-statement \
	wasm-gc-wasmtime-switch-inline-final \
	wasm-gc-wasmtime-throw-expression \
	wasm-gc-wasmtime-array-literal \
	wasm-gc-wasmtime-empty-array-flow-inference \
	wasm-gc-wasmtime-do-while \
	wasm-gc-wasmtime-postfix-increment \
	wasm-gc-wasmtime-optional-enum-parameter \
	wasm-gc-wasmtime-call-many \
	wasm-gc-wasmtime-function-call \
	wasm-gc-wasmtime-function-value \
	wasm-gc-wasmtime-lambda \
	wasm-gc-wasmtime-single-argument-lambda \
	wasm-gc-wasmtime-contextual-callbacks \
	wasm-gc-wasmtime-enum-array-pattern \
	wasm-gc-wasmtime-anonymous-function \
	wasm-gc-wasmtime-enum-abstract \
	wasm-gc-wasmtime-computed-property \
	wasm-gc-wasmtime-mutable-capture \
	wasm-gc-wasmtime-nested-mutable-capture \
	wasm-gc-wasmtime-captured-lambda \
	wasm-gc-wasmtime-captured-this \
	wasm-gc-wasmtime-nullable-basic \
	wasm-gc-wasmtime-nullable-compound \
	wasm-gc-wasmtime-object-array \
	wasm-gc-wasmtime-for-in \
	wasm-gc-wasmtime-loop-control \
	wasm-gc-wasmtime-modulo \
	wasm-gc-wasmtime-switch-enum \
	wasm-gc-wasmtime-multiple-implements \
	wasm-gc-wasmtime-captured-method \
	wasm-gc-wasmtime-anonymous-record \
	wasm-gc-wasmtime-array-comprehension \
	wasm-gc-wasmtime-filtered-array-comprehension \
	wasm-gc-wasmtime-range-iteration \
	wasm-gc-wasmtime-cast-expression \
	wasm-gc-wasmtime-optional-argument-forwarding \
	wasm-gc-wasmtime-default-parameter-inference \
	wasm-gc-wasmtime-generic-functions \
	wasm-gc-wasmtime-generic-abstract \
	wasm-gc-wasmtime-bounded-generic \
	wasm-gc-wasmtime-generic-class \
	wasm-gc-wasmtime-array-iterator-wasm \
	wasm-gc-wasmtime-array-slice-index \
	wasm-gc-wasmtime-array-growth-wasm \
	wasm-gc-wasmtime-array-alias-growth \
	wasm-gc-wasmtime-array-index-growth \
	wasm-gc-wasmtime-array-resize \
	wasm-gc-wasmtime-array-expression-mutation \
	wasm-gc-wasmtime-array-field-mutation \
	wasm-gc-wasmtime-array-copy-concat \
	wasm-gc-wasmtime-array-unshift \
	wasm-gc-wasmtime-array-insert \
	wasm-gc-wasmtime-array-splice \
	wasm-gc-wasmtime-array-remove \
	wasm-gc-wasmtime-array-object-mutation \
	wasm-gc-wasmtime-array-reverse \
	wasm-gc-wasmtime-dynamic-equality \
	wasm-gc-wasmtime-numeric-promotion \
	wasm-gc-wasmtime-function-wrapper \
	wasm-gc-wasmtime-inheritance-class \
	wasm-gc-wasmtime-override-method \
	wasm-gc-wasmtime-virtual-dispatch \
	wasm-gc-wasmtime-wasm-gc-reuse \
	wasm-gc-wasmtime-std-is-of-type \
	wasm-gc-wasmtime-map-basic \
	wasm-gc-wasmtime-map-int \
	wasm-gc-wasmtime-map-primitive-types \
	wasm-gc-wasmtime-map-literal \
	wasm-gc-wasmtime-map-object \
	wasm-gc-wasmtime-map-anonymous-enum \
	wasm-gc-wasmtime-map-for-in \
	wasm-gc-wasmtime-map-key-value-for-in \
	wasm-gc-wasmtime-map-comprehension \
	wasm-gc-wasmtime-map-nullable-get \
	wasm-gc-wasmtime-nullable-map-get \
	wasm-gc-wasmtime-map-string-equality \
	wasm-gc-wasmtime-string-concat-mixed \
	wasm-gc-wasmtime-string-split \
	wasm-gc-wasmtime-string-split-edge \
	wasm-gc-wasmtime-string-from-char-code \
	wasm-gc-wasmtime-bytes-codec \
	wasm-gc-wasmtime-bytes-stream-edge \
	wasm-gc-wasmtime-reflect-compare-sort \
	wasm-gc-wasmtime-generic-interface \
	wasm-gc-wasmtime-generic-contextual-callback \
	wasm-gc-wasmtime-interface-dispatch \
	wasm-gc-wasmtime-interface-inheritance \
	wasm-gc-wasmtime-interface-upcast \
	wasm-gc-wasmtime-interface-field \
	wasm-gc-wasmtime-try-catch \
	wasm-gc-wasmtime-try-nested \
	wasm-gc-wasmtime-try-array-bounds \
	wasm-gc-wasmtime-concise-try \
	wasm-gc-wasmtime-try-typed-class \
	wasm-gc-wasmtime-try-typed-mismatch \
	wasm-gc-wasmtime-try-typed-int \
	wasm-gc-wasmtime-try-multiple-catches \
	wasm-gc-wasmtime-enum-argument-string \
	wasm-gc-wasmtime-string-interpolation \
	wasm-gc-wasmtime-std-string-dynamic \
	wasm-gc-wasmtime-compiler-audit-regressions \
	wasm-gc-wasmtime-wasm-gc-string-operations \
	wasm-gc-wasmtime-bytes-compare; do
	wasm_file="$root_dir/out/$artifact.wasm"
	result=$("$wasmtime_bin" run --invoke main "$wasm_file" 2>"$root_dir/out/wasmtime-stderr.txt") || {
		cat "$root_dir/out/wasmtime-stderr.txt" >&2
		echo "Wasmtime failed to run $artifact" >&2
		exit 1
	}
	expected=42
	if [[ "$artifact" == "wasm-gc-wasmtime-array-object-mutation" ]]; then
		expected=8
	elif [[ "$artifact" == "wasm-gc-wasmtime-array-field-mutation" ]]; then
		expected=11
	elif [[ "$artifact" == "wasm-gc-wasmtime-single-argument-lambda" ]]; then
		expected=43
	elif [[ "$artifact" == "wasm-gc-wasmtime-mutable-capture" ]]; then
		expected=78
	elif [[ "$artifact" == "wasm-gc-wasmtime-nested-mutable-capture" ]]; then
		expected=3
	elif [[ "$artifact" == "wasm-gc-wasmtime-fib" ]]; then
		expected=55
	elif [[ "$artifact" == "wasm-gc-wasmtime-static-field" ]]; then
		expected=81
	elif [[ "$artifact" == "wasm-gc-wasmtime-map-for-in" ]]; then
		expected=52
	elif [[ "$artifact" == "wasm-gc-wasmtime-interface-inheritance" ]]; then
		expected=43
	elif [[ "$artifact" == "wasm-gc-wasmtime-interface-upcast" ]]; then
		expected=5
	elif [[ "$artifact" == "wasm-gc-wasmtime-inheritance-class" ]]; then
		expected=43
	elif [[ "$artifact" == "wasm-gc-wasmtime-virtual-dispatch" ]]; then
		expected=71
	fi
	if [[ "$result" != "$expected" ]]; then
		cat "$root_dir/out/wasmtime-stderr.txt" >&2
		echo "Wasmtime returned '$result' for $artifact, expected $expected" >&2
		exit 1
	fi
done

echo "PASS: Wasm GC modules validate and execute under $wasmtime_version"
