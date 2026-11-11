#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-mixed-spans.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
compiler=${HAXEON_COMPILER_HL:-"$temporary/compiler.hl"}
if [[ -z ${HAXEON_COMPILER_HL:-} ]]; then
  "$root/.tools/haxe/haxe" -cp "$root/src" -hl "$compiler" -main compiler.tools.HaxeonCompiler
fi
cd "$root"
for target in wasm32 wasm-gc; do
  for inline in 0 1; do
    scripts/hl "$compiler" --target="$target" --define="haxeon-inline=$inline" \
      --ffi-interface=tests/ffi/mixed-spans.hxi --root=tests/ffi --entry=mixed-spans \
      --output="$temporary/$target-$inline.wasm" tests/ffi/mixed-spans.hx > "$temporary/build.log" 2>&1 || { cat "$temporary/build.log"; exit 1; }
    node - "$temporary/$target-$inline.wasm" <<'JS'
const fs = require('fs');
(async () => {
  let instance;
  const live = new Set();
  ({instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {
    haxeon_runtime: {
      native_alloc: size => {
        const memory = instance.exports.memory, pointer = memory.buffer.byteLength;
        memory.grow(Math.ceil(size / 65536)); live.add(pointer); return pointer;
      },
      native_free: pointer => { if (!live.delete(pointer)) throw Error('invalid free'); }
    },
    mixed_spans: {check: (data, dataSize, records, recordsSize) => {
      const bytes = new Uint8Array(instance.exports.memory.buffer);
      if (!live.has(records) || dataSize !== 3 || recordsSize !== 2 ||
          bytes[data] !== 11 || bytes[data + 1] !== 22 || bytes[data + 2] !== 33 ||
          bytes[records] !== 44 || bytes[records + 1] !== 55) return 1;
      return 42;
    }}
  }));
  const result = instance.exports.main();
  if (result !== 42 || live.size) throw Error(`result=${result}, live=${live.size}`);
})().catch(error => { console.error(error); process.exit(1); });
JS
    echo "PASS: mixed managed bytes and native span on $target inline=$inline"
  done
done
