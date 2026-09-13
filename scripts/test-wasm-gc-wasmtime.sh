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

for case_name in add array-iterator-wasm array-slice-index array-growth-wasm array-alias-growth array-index-growth array-resize array-expression-mutation array-field-mutation array-copy-concat array-unshift array-insert array-splice array-remove array-object-mutation array-reverse dynamic-equality numeric-promotion function-wrapper std-is-of-type map-basic map-int map-primitive-types map-literal map-object map-anonymous-enum map-for-in map-key-value-for-in map-comprehension map-nullable-get nullable-map-get map-string-equality string-concat-mixed string-split string-split-edge try-catch try-nested try-array-bounds concise-try try-typed-class try-typed-mismatch try-typed-int try-multiple-catches enum-argument-string string-interpolation std-string-dynamic; do
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
	elif [[ "$artifact" == "wasm-gc-wasmtime-map-for-in" ]]; then
		expected=52
	fi
	if [[ "$result" != "$expected" ]]; then
		cat "$root_dir/out/wasmtime-stderr.txt" >&2
		echo "Wasmtime returned '$result' for $artifact, expected $expected" >&2
		exit 1
	fi
done

echo "PASS: Wasm GC modules validate and execute under $wasmtime_version"
