#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/haxeon-wasm-boundaries.XXXXXX")
trap 'rm -rf -- "${temporary_dir:?}"' EXIT
export LD_LIBRARY_PATH="$repo_dir/out:$repo_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
.tools/haxe/haxe -cp src -main compiler.tools.HaxeonCompiler -hl "$temporary_dir/compiler.hl"
cat > "$temporary_dir/BoundaryBuffers.hxi" <<'HXI'
interface BoundaryBuffers @target("portable-abi32") @library("boundary_buffers") {
  struct boundary_record @layout(4, 4) { value: i32 @offset(0); }
  extern fn read_record(record: ptr<const<boundary_record>>) -> i32;
  extern fn read_blob(data: nullable<ptr<u8>> @out_buffer("size"), size: ptr<u32> @inout) -> i32;
}
HXI
cat > "$temporary_dir/out-buffer.hx" <<'HX'
import BoundaryBuffers;
function main():Int {
  if (BoundaryBuffers.read_record(null) != 17) return 2;
  var record = new boundary_record();
  record.set_value(25);
  if (BoundaryBuffers.read_record(record) != 25) return 3;
  var value = BoundaryBuffers.read_blob();
  return value.status == 0 && value.data.length == 4 && value.data.getInt32(0) == 42 ? 42 : 1;
}
HX
for program in wasm-gc-closures wasm-arena out-buffer; do
  for target in wasm32 wasm-gc; do
    source="tests/programs/$program.hx"
    [[ "$program" != out-buffer ]] || source="$temporary_dir/out-buffer.hx"
    .tools/hashlink/hl "$temporary_dir/compiler.hl" --ffi-interface="$temporary_dir/BoundaryBuffers.hxi" --root="$temporary_dir" --target="$target" --output="$temporary_dir/$program.$target" --entry="$program" --root=tests/programs "$source" > "$temporary_dir/build.log" 2>&1 || { cat "$temporary_dir/build.log"; exit 1; }
  done
done
node - "$temporary_dir" <<'JS'
const fs = require('fs');
(async () => {
  for (const program of ['wasm-gc-closures', 'wasm-arena', 'out-buffer']) {
    for (const target of ['wasm32', 'wasm-gc']) {
      let instance;
      const allocations = new Set();
      ({instance} = await WebAssembly.instantiate(fs.readFileSync(`${process.argv[2]}/${program}.${target}`), {
        boundary_buffers: {read_record: pointer => pointer === 0 ? 17 : new DataView(instance.exports.memory.buffer).getInt32(pointer, true), read_blob: (pointer, sizePointer) => {
          const view = new DataView(instance.exports.memory.buffer);
          if (pointer === 0) {view.setUint32(sizePointer, 4, true); return 0;}
          if (view.getUint32(sizePointer, true) !== 4) throw Error('Invalid output buffer capacity');
          view.setInt32(pointer, 42, true); return 0;
        }},
        haxeon_runtime: {
          native_alloc: size => {
            const memory = instance.exports.memory;
            const pointer = memory.buffer.byteLength;
            memory.grow(Math.ceil(size / 65536));
            allocations.add(pointer); return pointer;
          },
          native_free: pointer => { if (!allocations.delete(pointer)) throw Error('Invalid arena free'); }
        }
      }));
      const result = instance.exports.main();
      if (result !== 42 || allocations.size) throw Error(`${target} ${program} failed: ${result}, leaked=${allocations.size}`);
    }
  }
})().catch(error => {console.error(error); process.exit(1);});
JS
echo 'Wasm runtime boundaries: wasm32 and wasm-gc passed bound methods, arena ownership, nullable output buffers and nullable record pointers'
