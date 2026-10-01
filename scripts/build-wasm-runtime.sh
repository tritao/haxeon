#!/usr/bin/env bash
# Builds the C runtime Haxeon links into every wasm32 module (docs/WASM_LINEAR_RUNTIME.md) and checks that it
# needs nothing from a linker but memory. The result is committed, so compiling Haxe programs needs no clang.
#   scripts/build-wasm-runtime.sh          rebuild stdlib/haxeon/wasm/linear-runtime.wasm
#   scripts/build-wasm-runtime.sh --check  fail if the committed module differs from a fresh build
# HAXEON_WASM_CLANG names the clang to use; otherwise an Emscripten SDK's clang next to this checkout is used.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$root_dir/stdlib/haxeon/wasm/linear-runtime.wasm"
clang=${HAXEON_WASM_CLANG:-}
if [[ -z "$clang" ]]; then
	for candidate in "$root_dir/../nativekit/.tools/emsdk/upstream/bin/clang" "$root_dir/../../materia/nativekit/.tools/emsdk/upstream/bin/clang"; do
		if [[ -x "$candidate" ]]; then
			clang=$candidate
			break
		fi
	done
fi
[[ -n "$clang" && -x "$clang" ]] || { echo "build-wasm-runtime.sh: no clang with a wasm32 target; set HAXEON_WASM_CLANG" >&2; exit 1; }

temp_dir=$(mktemp -d)
trap 'rm -rf -- "${temp_dir:?}"' EXIT
"$clang" --target=wasm32 -O2 -nostdlib -mbulk-memory -fno-exceptions -ffreestanding \
	-Wall -Wextra -Werror \
	-Wl,--no-entry -Wl,--import-memory -Wl,--strip-all -Wl,--allow-undefined \
	-o "$temp_dir/linear-runtime.wasm" "$root_dir"/native/wasm/*.c

# The linker merges functions only: no data, globals, table or elements, and memory comes from the module.
node - "$temp_dir/linear-runtime.wasm" <<'JS'
const module = new WebAssembly.Module(require("fs").readFileSync(process.argv[2]));
for (const entry of WebAssembly.Module.imports(module)) {
  const allowed = (entry.module === "env" && entry.name === "memory" && entry.kind === "memory")
    || (entry.module === "haxeon_guest" && entry.kind === "function");
  if (!allowed) throw new Error(`the wasm32 runtime imports ${entry.module}.${entry.name} (${entry.kind})`);
}
for (const entry of WebAssembly.Module.exports(module))
  if (entry.kind !== "function") throw new Error(`the wasm32 runtime exports ${entry.kind} ${entry.name}`);
const bytes = require("fs").readFileSync(process.argv[2]);
for (let offset = 8; offset < bytes.length;) {
  const id = bytes[offset++];
  let size = 0, shift = 0, byte;
  do { byte = bytes[offset++]; size |= (byte & 0x7f) << shift; shift += 7; } while (byte & 0x80);
  if ([4, 6, 9, 11, 12].includes(id)) throw new Error(`the wasm32 runtime has section ${id}; it may only define functions`);
  offset += size;
}
JS
if [[ "${1:-}" == "--check" ]]; then
	cmp -s "$temp_dir/linear-runtime.wasm" "$output" || { echo "build-wasm-runtime.sh: $output is stale; rebuild it" >&2; exit 1; }
	echo "linear-runtime.wasm is up to date"
else
	cp "$temp_dir/linear-runtime.wasm" "$output"
	echo "built $output ($(wc -c < "$output") bytes)"
fi
