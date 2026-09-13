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

for artifact in \
	wasm-gc-model \
	wasm-gc-type-plan \
	wasm-gc-objects \
	wasm-gc-arrays \
	wasm-gc-enums \
	wasm-gc-closures \
	wasm-gc-dynamic \
	wasm-gc-strings; do
	wasm_file="$root_dir/out/$artifact.wasm"
	result=$("$wasmtime_bin" run --invoke main "$wasm_file" 2>"$root_dir/out/wasmtime-stderr.txt") || {
		cat "$root_dir/out/wasmtime-stderr.txt" >&2
		echo "Wasmtime failed to run $artifact" >&2
		exit 1
	}
	if [[ "$result" != "42" ]]; then
		cat "$root_dir/out/wasmtime-stderr.txt" >&2
		echo "Wasmtime returned '$result' for $artifact, expected 42" >&2
		exit 1
	fi
done

echo "NOTE: GC EH and operations that synthesize EH remain covered by Node until lowering uses standardized try_table instructions"
echo "PASS: Wasm GC modules validate and execute under $wasmtime_version"
