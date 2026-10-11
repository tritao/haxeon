#!/usr/bin/env bash
# Builds the C runtimes Haxeon links into wasm32 modules. The standard artifacts need no clang to use; the
# runtime-neutral variants import only a module-local fuel-charge helper in addition to linear memory.
#   scripts/build-wasm-runtime.sh          rebuild stdlib/haxeon/wasm/linear-runtime.wasm
#                                          and the runtime-neutral heap and crypto variants
#   scripts/build-wasm-runtime.sh --check  fail if the committed module differs from a fresh build
#                                          (skipped, not failed, without clang)
#   scripts/build-wasm-runtime.sh --neutral-only / --check-neutral
#                                          build or check only the opt-in runtime-neutral variants
# HAXEON_WASM_CLANG names the clang to use; otherwise an Emscripten SDK's clang next to this checkout is used.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-build}
case "$mode" in
build | --check | --neutral-only | --check-neutral) ;;
*) echo "usage: $0 [--check|--neutral-only|--check-neutral]" >&2; exit 2 ;;
esac
output="$root_dir/stdlib/haxeon/wasm/linear-runtime.wasm"
neutral_output="$root_dir/stdlib/haxeon/wasm/linear-runtime-neutral.wasm"
crypto_output="$root_dir/stdlib/haxeon/wasm/crypto-runtime.wasm"
neutral_crypto_output="$root_dir/stdlib/haxeon/wasm/crypto-runtime-neutral.wasm"
clang=${HAXEON_WASM_CLANG:-}
if [[ -z "$clang" ]]; then
	for candidate in "$root_dir/../nativekit/.tools/emsdk/upstream/bin/clang" "$root_dir/../../materia/nativekit/.tools/emsdk/upstream/bin/clang"; do
		if [[ -x "$candidate" ]]; then
			clang=$candidate
			break
		fi
	done
fi
if [[ -z "$clang" || ! -x "$clang" ]]; then
	# Checking needs clang too; without one the committed module cannot be compared, which is not a failure.
	if [[ "${1:-}" == "--check" || "${1:-}" == "--check-neutral" ]]; then
		echo "SKIP: Wasm runtime freshness (no clang with a wasm32 target; set HAXEON_WASM_CLANG)"
		exit 0
	fi
	echo "build-wasm-runtime.sh: no clang with a wasm32 target; set HAXEON_WASM_CLANG" >&2
	exit 1
fi

temp_dir=$(mktemp -d)
trap 'rm -rf -- "${temp_dir:?}"' EXIT
if [[ "$mode" != "--neutral-only" && "$mode" != "--check-neutral" ]]; then
	"$clang" --target=wasm32 -O2 -nostdlib -mbulk-memory -fno-exceptions -ffreestanding \
		-Wall -Wextra -Werror \
		-Wl,--no-entry -Wl,--import-memory -Wl,--strip-all -Wl,--allow-undefined \
		-o "$temp_dir/linear-runtime.wasm" "$root_dir"/native/wasm/*.c

	"$clang" --target=wasm32 -O2 -nostdlib -mbulk-memory -fno-exceptions -ffreestanding \
		-Wall -Wextra -Werror \
		-Wl,--no-entry -Wl,--import-memory -Wl,--strip-all \
		-o "$temp_dir/crypto-runtime.wasm" "$root_dir"/native/wasm/crypto/*.c
fi

"$clang" --target=wasm32 -O2 -nostdlib -mbulk-memory -fno-exceptions -ffreestanding \
	-DHAXEON_WASM_RUNTIME_NEUTRAL \
		-Wall -Wextra -Werror \
		-Wl,--no-entry -Wl,--import-memory -Wl,--strip-all -Wl,--allow-undefined \
		-o "$temp_dir/linear-runtime-neutral.wasm" "$root_dir"/native/wasm/*.c

"$clang" --target=wasm32 -O2 -nostdlib -mbulk-memory -fno-exceptions -ffreestanding \
	-DHAXEON_WASM_RUNTIME_NEUTRAL \
	-Wall -Wextra -Werror \
	-Wl,--no-entry -Wl,--import-memory -Wl,--strip-all -Wl,--allow-undefined \
	-o "$temp_dir/crypto-runtime-neutral.wasm" "$root_dir"/native/wasm/crypto/*.c

# Standard modules define functions only. The neutral variants also carry wasm-ld's private C stack global and
# empty table; the compiler links the global and rejects every call_indirect or element-section use of that table.
runtime_paths=()
if [[ "$mode" != "--neutral-only" && "$mode" != "--check-neutral" ]]; then
	runtime_paths+=("$temp_dir/linear-runtime.wasm" "$temp_dir/crypto-runtime.wasm")
fi
runtime_paths+=("$temp_dir/linear-runtime-neutral.wasm" "$temp_dir/crypto-runtime-neutral.wasm")
node - "${runtime_paths[@]}" <<'JS'
for (const runtimePath of process.argv.slice(2)) {
const module = new WebAssembly.Module(require("fs").readFileSync(runtimePath));
const neutral = runtimePath.includes("-neutral.wasm");
for (const entry of WebAssembly.Module.imports(module)) {
  const allowed = (entry.module === "env" && entry.name === "memory" && entry.kind === "memory")
    || (entry.module === "haxeon_guest" && entry.kind === "function");
  if (!allowed) throw new Error(`the wasm32 runtime imports ${entry.module}.${entry.name} (${entry.kind})`);
}
if (neutral) {
	const fuelImports = WebAssembly.Module.imports(module).filter(entry => entry.module === "haxeon_guest");
	if (!fuelImports.some(entry => entry.name === "fuel_charge" && entry.kind === "function")
		|| fuelImports.some(entry => !["collect", "fuel_charge"].includes(entry.name) || entry.kind !== "function"))
		throw new Error(`the runtime-neutral module ${runtimePath} has an unexpected guest import surface`);
}
for (const entry of WebAssembly.Module.exports(module))
  if (entry.kind !== "function") throw new Error(`the wasm32 runtime exports ${entry.kind} ${entry.name}`);
const bytes = require("fs").readFileSync(runtimePath);
for (let offset = 8; offset < bytes.length;) {
  const id = bytes[offset++];
  let size = 0, shift = 0, byte;
  do { byte = bytes[offset++]; size |= (byte & 0x7f) << shift; shift += 7; } while (byte & 0x80);
	if ([9, 11, 12].includes(id) || (!neutral && [4, 6].includes(id)))
		throw new Error(`the wasm32 runtime ${runtimePath} has unsupported section ${id}`);
  offset += size;
}
}
JS
if [[ "$mode" == "--check" ]]; then
	cmp -s "$temp_dir/linear-runtime.wasm" "$output" || { echo "build-wasm-runtime.sh: $output is stale; rebuild it" >&2; exit 1; }
	cmp -s "$temp_dir/linear-runtime-neutral.wasm" "$neutral_output" || { echo "build-wasm-runtime.sh: $neutral_output is stale; rebuild it" >&2; exit 1; }
	cmp -s "$temp_dir/crypto-runtime.wasm" "$crypto_output" || { echo "build-wasm-runtime.sh: $crypto_output is stale; rebuild it" >&2; exit 1; }
	cmp -s "$temp_dir/crypto-runtime-neutral.wasm" "$neutral_crypto_output" || { echo "build-wasm-runtime.sh: $neutral_crypto_output is stale; rebuild it" >&2; exit 1; }
	echo "Wasm runtimes are up to date"
elif [[ "$mode" == "--check-neutral" ]]; then
	cmp -s "$temp_dir/linear-runtime-neutral.wasm" "$neutral_output" || { echo "build-wasm-runtime.sh: $neutral_output is stale; rebuild it" >&2; exit 1; }
	cmp -s "$temp_dir/crypto-runtime-neutral.wasm" "$neutral_crypto_output" || { echo "build-wasm-runtime.sh: $neutral_crypto_output is stale; rebuild it" >&2; exit 1; }
	echo "Runtime-neutral Wasm runtimes are up to date"
elif [[ "$mode" == "--neutral-only" ]]; then
	cp "$temp_dir/linear-runtime-neutral.wasm" "$neutral_output"
	cp "$temp_dir/crypto-runtime-neutral.wasm" "$neutral_crypto_output"
	echo "built runtime-neutral wasm32 runtimes: $neutral_output, $neutral_crypto_output"
else
	cp "$temp_dir/linear-runtime.wasm" "$output"
	cp "$temp_dir/linear-runtime-neutral.wasm" "$neutral_output"
	cp "$temp_dir/crypto-runtime.wasm" "$crypto_output"
	cp "$temp_dir/crypto-runtime-neutral.wasm" "$neutral_crypto_output"
	echo "built wasm32 runtimes: $output, $neutral_output, $crypto_output, $neutral_crypto_output"
fi
