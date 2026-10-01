#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
mkdir -p "$root_dir/out"
if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
source "$root_dir/scripts/haxeon-compiler.sh"

# The committed C runtime every wasm32 module links must match native/wasm (docs/WASM_LINEAR_RUNTIME.md).
bash "$root_dir/scripts/build-wasm-runtime.sh" --check
"$haxe_bin" --cwd "$root_dir" -cp src -cp tests/compiler --run WasmBackendMain
bash "$root_dir/scripts/test-wasm-gc-reuse.sh"
bash "$root_dir/scripts/test-wasm-gc-invariants.sh"
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-backend.wasm --entry=add \
	--root=tests/programs tests/programs/add.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-source-root.wasm --entry=Main \
	--root=tests/fixtures/source_root tests/fixtures/source_root/Main.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-runtime-source.wasm --entry=wasm-runtime-source-link \
	--root=tests/programs tests/programs/wasm-runtime-source-link.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-gc-cli-runtime-source.wasm --entry=wasm-runtime-source-link \
	--root=tests/programs tests/programs/wasm-runtime-source-link.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-typed-std-dependency.wasm --entry=wasm-typed-std-dependency \
	--root=tests/programs tests/programs/wasm-typed-std-dependency.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-int64-of-int.wasm --entry=wasm-int64-of-int \
	--root=tests/programs tests/programs/wasm-int64-of-int.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-gc-cli-int64-of-int.wasm --entry=wasm-int64-of-int \
	--root=tests/programs tests/programs/wasm-int64-of-int.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-ryu-source.wasm --entry=wasm-ryu-source \
	--export=wasm-ryu-source.stringifyFloat --root=tests/programs tests/programs/wasm-ryu-source.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-gc-cli-ryu-source.wasm --entry=wasm-ryu-source \
	--root=tests/programs tests/programs/wasm-ryu-source.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-std-string-fields.wasm --entry=wasm-std-string-fields \
	--root=tests/programs tests/programs/wasm-std-string-fields.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-gc-cli-std-string-fields.wasm --entry=wasm-std-string-fields \
	--root=tests/programs tests/programs/wasm-std-string-fields.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-memory-filesystem.wasm --entry=wasm-memory-filesystem \
	--root=tests/programs tests/programs/wasm-memory-filesystem.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-gc-cli-memory-filesystem.wasm --entry=wasm-memory-filesystem \
	--root=tests/programs tests/programs/wasm-memory-filesystem.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-ereg-engine.wasm --entry=wasm-ereg-engine \
	--root=tests/programs tests/programs/wasm-ereg-engine.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-gc-cli-ereg-engine.wasm --entry=wasm-ereg-engine \
	--root=tests/programs tests/programs/wasm-ereg-engine.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-dynamic.wasm --entry=dynamic-equality \
	--root=tests/programs tests/programs/dynamic-equality.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-function-wrapper.wasm --entry=function-wrapper \
	--root=tests/programs tests/programs/function-wrapper.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-type-test.wasm --entry=std-is-of-type \
	--root=tests/programs tests/programs/std-is-of-type.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-numeric-promotion.wasm --entry=numeric-promotion \
	--root=tests/programs tests/programs/numeric-promotion.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-array-slice.wasm --entry=array-slice-index \
	--root=tests/programs tests/programs/array-slice-index.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-array-mutation.wasm --entry=array-splice \
	--root=tests/programs tests/programs/array-splice.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-array-growth.wasm --entry=array-growth-wasm \
	--root=tests/programs tests/programs/array-growth-wasm.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-array-iterator.wasm --entry=array-iterator-wasm \
	--root=tests/programs tests/programs/array-iterator-wasm.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-map-basic.wasm --entry=map-basic \
	--root=tests/programs tests/programs/map-basic.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-map-int.wasm --entry=map-int \
	--root=tests/programs tests/programs/map-int.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-map-primitive-types.wasm --entry=map-primitive-types \
	--root=tests/programs tests/programs/map-primitive-types.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-map-for-in.wasm --entry=map-for-in \
	--root=tests/programs tests/programs/map-for-in.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-map-key-value-for-in.wasm --entry=map-key-value-for-in \
	--root=tests/programs tests/programs/map-key-value-for-in.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-map-object.wasm --entry=map-object \
	--root=tests/programs tests/programs/map-object.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-map-anonymous-enum.wasm --entry=map-anonymous-enum \
	--root=tests/programs tests/programs/map-anonymous-enum.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-messagepack-enum-map.wasm --entry=wasm-messagepack-enum-map \
	--root=tests/programs tests/programs/wasm-messagepack-enum-map.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-messagepack-wire.wasm --entry=wasm-messagepack-wire \
	--root=tests/programs tests/programs/wasm-messagepack-wire.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-gc-cli-messagepack-wire.wasm --entry=wasm-messagepack-wire \
	--root=tests/programs tests/programs/wasm-messagepack-wire.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-cnative-import.wasm --entry=wasm-cnative-import \
	--root=tests tests/wasm-cnative-import.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-wasm32-bytes-view.wasm --entry=wasm32-bytes-view \
	--root=tests/ffi --ffi-interface=tests/ffi/wasm32_bytes_view.hxi tests/ffi/wasm32-bytes-view.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-try-catch.wasm --entry=try-catch \
	--root=tests/programs tests/programs/try-catch.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-try-nested.wasm --entry=try-nested \
	--root=tests/programs tests/programs/try-nested.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-try-bounds.wasm --entry=try-array-bounds \
	--root=tests/programs tests/programs/try-array-bounds.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-hxi-retained.wasm --entry=wasm-hxi-retained \
	--root=tests --ffi-interface=tests/ffi/retained_struct.hxi tests/wasm-hxi-retained.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-hxi-retained-imported.wasm --entry=wasm-hxi-retained \
	--wasm-import-memory --root=tests --ffi-interface=tests/ffi/retained_struct.hxi tests/wasm-hxi-retained.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-hxi-value-records.wasm --entry=wasm32-value-records \
	--root=tests/ffi --ffi-interface=tests/ffi/wasm32_value_records.hxi tests/ffi/wasm32-value-records.hx
for target in wasm32 wasm-gc; do
	haxeon_compile_async \
		--target=$target --output=out/wasm-cli-host-services-$target.wasm --entry=wasm-host-services \
		--root=tests/programs tests/programs/wasm-host-services.hx
	haxeon_compile_async \
		--target=$target --output=out/wasm-cli-host-callbacks-$target.wasm --entry=wasm-callbacks \
		--root=tests/ffi --ffi-interface=tests/ffi/wasm_callbacks.hxi tests/ffi/wasm-callbacks.hx
done
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-hxi-value-records.wasm --entry=wasm32-value-records \
	--root=tests/ffi --ffi-interface=tests/ffi/wasm32_value_records.hxi tests/ffi/wasm32-value-records.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-objects.wasm --entry=wasm-gc-objects \
	--root=tests/programs tests/programs/wasm-gc-objects.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-arrays.wasm --entry=wasm-gc-arrays \
	--root=tests/programs tests/programs/wasm-gc-arrays.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-enums.wasm --entry=wasm-gc-enums \
	--root=tests/programs tests/programs/wasm-gc-enums.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-closures.wasm --entry=wasm-gc-closures \
	--root=tests/programs tests/programs/wasm-gc-closures.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-dynamic.wasm --entry=wasm-gc-dynamic \
	--root=tests/programs tests/programs/wasm-gc-dynamic.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-exceptions.wasm --entry=wasm-gc-exceptions \
	--root=tests/programs tests/programs/wasm-gc-exceptions.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-strings.wasm --entry=wasm-gc-strings \
	--root=tests/programs tests/programs/wasm-gc-strings.hx
haxeon_compile_async \
	--target=wasm32 --output=out/wasm-cli-string-split.wasm --entry=wasm-string-split \
	--root=tests/programs tests/programs/wasm-string-split.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-bytes.wasm --entry=wasm-gc-bytes \
	--root=tests/programs tests/programs/wasm-gc-bytes.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-ffi-bytes.wasm --entry=wasm-gc-ffi-bytes \
	--root=tests/ffi --ffi-interface=tests/ffi/gc_bytes.hxi tests/ffi/wasm-gc-ffi-bytes.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-ffi-short-struct.wasm --entry=wasm-gc-ffi-short-struct \
	--root=tests/ffi --ffi-interface=tests/ffi/gc_bytes.hxi tests/ffi/wasm-gc-ffi-short-struct.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-ffi-borrowed-array.wasm --entry=wasm-gc-ffi-borrowed-array \
	--root=tests/ffi --ffi-interface=tests/ffi/gc_bytes.hxi tests/ffi/wasm-gc-ffi-borrowed-array.hx
haxeon_compile_async \
	--target=wasm-gc --output=out/wasm-cli-gc-ffi-nested-array.wasm --entry=wasm-gc-ffi-nested-array \
	--root=tests/ffi --ffi-interface=tests/ffi/gc_nested.hxi tests/ffi/wasm-gc-ffi-nested-array.hx
haxeon_compile_wait

node - "$root_dir" <<'JS'
const fs = require("fs");
const root = process.argv[2];
const cases = [
  ["out/wasm-backend-test.wasm", 42],
  ["out/wasm-backend-branch.wasm", 42],
  ["out/wasm-backend-loop.wasm", 6],
  ["out/wasm-backend-object.wasm", 42],
  ["out/wasm-backend-array.wasm", 42],
  ["out/wasm-backend-float-array.wasm", 42],
  ["out/wasm-backend-array-ops.wasm", 42],
  ["out/wasm-backend-array-mutation.wasm", 42],
  ["out/wasm-backend-string.wasm", 6],
  ["out/wasm-backend-string-ops.wasm", 42],
  ["out/wasm-backend-std-string.wasm", 42],
  ["out/wasm-backend-std-string-i64.wasm", 42],
	["out/wasm-cli-std-string-fields.wasm", 42],
	["out/wasm-gc-cli-std-string-fields.wasm", 42],
	["out/wasm-cli-memory-filesystem.wasm", 42],
	["out/wasm-gc-cli-memory-filesystem.wasm", 42],
	["out/wasm-cli-ereg-engine.wasm", 42],
	["out/wasm-gc-cli-ereg-engine.wasm", 42],
  ["out/wasm-backend-method.wasm", 42],
  ["out/wasm-backend-global.wasm", 42],
  ["out/wasm-backend-float-global.wasm", 42],
  ["out/wasm-backend-enum.wasm", 42],
  ["out/wasm-backend-float-enum.wasm", 42],
  ["out/wasm-backend-inherited-field.wasm", 42],
  ["out/wasm-backend-large-array.wasm", 20000],
  ["out/wasm-cli-backend.wasm", 42],
  ["out/wasm-cli-source-root.wasm", 42],
  ["out/wasm-cli-runtime-source.wasm", 42],
  ["out/wasm-gc-cli-runtime-source.wasm", 42],
  ["out/wasm-cli-typed-std-dependency.wasm", 42],
  ["out/wasm-cli-int64-of-int.wasm", 42],
  ["out/wasm-gc-cli-int64-of-int.wasm", 42],
  ["out/wasm-cli-ryu-source.wasm", 42],
  ["out/wasm-gc-cli-ryu-source.wasm", 42],
  ["out/wasm-cli-dynamic.wasm", 42],
  ["out/wasm-cli-function-wrapper.wasm", 42],
  ["out/wasm-cli-type-test.wasm", 42],
  ["out/wasm-cli-numeric-promotion.wasm", 42],
  ["out/wasm-cli-array-slice.wasm", 42],
  ["out/wasm-cli-array-mutation.wasm", 42],
  ["out/wasm-cli-array-growth.wasm", 42],
  ["out/wasm-cli-array-iterator.wasm", 42],
  ["out/wasm-cli-map-basic.wasm", 42],
  ["out/wasm-cli-map-int.wasm", 42],
  ["out/wasm-cli-map-primitive-types.wasm", 42],
	["out/wasm-cli-map-for-in.wasm", 52],
	["out/wasm-cli-map-key-value-for-in.wasm", 42],
	["out/wasm-cli-map-object.wasm", 42],
	["out/wasm-cli-map-anonymous-enum.wasm", 42],
	["out/wasm-cli-messagepack-enum-map.wasm", 42],
	["out/wasm-cli-messagepack-wire.wasm", 42],
	["out/wasm-gc-cli-messagepack-wire.wasm", 42],
	["out/wasm-cli-cnative-import.wasm", 42],
	["out/wasm-cli-wasm32-bytes-view.wasm", 42],
	["out/wasm-cli-hxi-retained.wasm", 42],
	["out/wasm-cli-hxi-retained-imported.wasm", 42],
	["out/wasm-cli-hxi-value-records.wasm", 42],
	["out/wasm-cli-gc-hxi-value-records.wasm", 42],
	["out/wasm-cli-host-services-wasm32.wasm", 42],
	["out/wasm-cli-host-services-wasm-gc.wasm", 42],
	["out/wasm-cli-host-callbacks-wasm32.wasm", 42],
	["out/wasm-cli-host-callbacks-wasm-gc.wasm", 42],
	["out/wasm-cli-try-catch.wasm", 42],
	["out/wasm-cli-try-nested.wasm", 42],
	["out/wasm-cli-try-bounds.wasm", 42],
  ["out/wasm-backend-closure.wasm", 42],
  ["out/wasm-backend-instance-closure.wasm", 42],
  ["out/wasm-backend-virtual.wasm", 42],
	["out/wasm-gc-model.wasm", 42],
	["out/wasm-gc-type-plan.wasm", 42],
	["out/wasm-gc-objects.wasm", 42],
	["out/wasm-cli-gc-objects.wasm", 42],
	["out/wasm-gc-arrays.wasm", 42],
	["out/wasm-cli-gc-arrays.wasm", 42],
	["out/wasm-gc-enums.wasm", 42],
	["out/wasm-cli-gc-enums.wasm", 42],
	["out/wasm-gc-closures.wasm", 42],
	["out/wasm-cli-gc-closures.wasm", 42],
	["out/wasm-gc-dynamic.wasm", 42],
	["out/wasm-cli-gc-dynamic.wasm", 42],
	["out/wasm-gc-exceptions.wasm", 42],
	["out/wasm-cli-gc-exceptions.wasm", 42],
	["out/wasm-gc-strings.wasm", 42],
	["out/wasm-cli-gc-strings.wasm", 42],
	["out/wasm-cli-string-split.wasm", 42],
	["out/wasm-cli-gc-bytes.wasm", 42],
	["out/wasm-cli-gc-ffi-bytes.wasm", 42],
	["out/wasm-cli-gc-ffi-short-struct.wasm", 42],
	["out/wasm-cli-gc-ffi-borrowed-array.wasm", 42],
	["out/wasm-cli-gc-ffi-nested-array.wasm", 42]
];
(async () => {
  for (const [relative, expected] of cases) {
    const bytes = fs.readFileSync(`${root}/${relative}`);
    const importedMemory = relative.endsWith("hxi-retained-imported.wasm");
    const memory = importedMemory ? new WebAssembly.Memory({initial: 3}) : null;
    let moduleInstance = null;
	let ownedBytesReleased = false;
	let ownedPointerReleases = [];
	let byteViewCalls = 0;
    let shortStructImportCalled = false;
    let hostServicesCheck = null;
    const imports = {};
    if (relative.endsWith("cnative-import.wasm"))
      imports.fixture = {fixture_add: (left, right) => left + right};
    if (relative.endsWith("wasm32-bytes-view.wasm")) {
      imports.wasm32_bytes_view = {inspect_bytes: (pointer, length) => {
        byteViewCalls++;
        const expected = [115, 108, 105, 99, 101];
        const actual = new Uint8Array(moduleInstance.exports.memory.buffer, pointer, length);
        return length === expected.length && expected.every((value, index) => actual[index] === value) ? 42 : 0;
      }};
    }
    // HaxeonHost receives C strings and returns scalars on both backends; nothing else is imported.
    if (relative.includes("wasm-cli-host-services-")) {
      const unexpected = WebAssembly.Module.imports(new WebAssembly.Module(bytes)).filter(entry => entry.module !== "haxeon_host");
      if (unexpected.length !== 0)
        throw new Error(`${relative}: unexpected imports ${unexpected.map(entry => entry.module + "." + entry.name).join(", ")}`);
      let printed = "";
      imports.haxeon_host = {
        print: pointer => {
          const bytes = new Uint8Array(moduleInstance.exports.memory.buffer);
          let end = pointer;
          while (bytes[end] !== 0) end++;
          printed += new TextDecoder().decode(bytes.subarray(pointer, end));
        },
        date_now: () => Date.now()
      };
      hostServicesCheck = () => {
        if (printed !== "wasm-host-services.hx:4: host trace\nhost println\n")
          throw new Error(`${relative}: host printed ${JSON.stringify(printed)}`);
      };
    }
    // The host calls callbacks through the exported entry named at creation, with the closure id first.
    if (relative.includes("wasm-cli-host-callbacks-")) {
      const callbacks = new Map();
      let nextCallback = 1;
      const cString = pointer => {
        const bytes = new Uint8Array(moduleInstance.exports.memory.buffer);
        let end = pointer;
        while (bytes[end] !== 0) end++;
        return new TextDecoder().decode(bytes.subarray(pointer, end));
      };
      const callEntry = (index, ...args) => {
        const entry = callbacks.get(index);
        if (!entry) throw new Error(`${relative}: call to closed callback ${index}`);
        return moduleInstance.exports[entry.entry](entry.id, ...args);
      };
      imports.haxeon_host = {
        callback_create: (entry, signature, id) => {
          const index = nextCallback++;
          callbacks.set(index, {entry: cString(entry), signature: cString(signature), id});
          return index;
        },
        callback_close: index => callbacks.delete(index)
      };
      imports.wasm_callbacks = {
        apply_combine: (callback, value) => {
          if (callbacks.get(callback).signature !== "iidi")
            throw new Error(`${relative}: combine callback signature ${callbacks.get(callback).signature}`);
          return callEntry(callback, value, 5.0, 0);
        },
        // The record result comes back through the leading pointer, which the callback writes too.
        apply_measure: (result, callback, limits) => {
          if (callbacks.get(callback).signature !== "viiii")
            throw new Error(`${relative}: measure callback signature ${callbacks.get(callback).signature}`);
          return callEntry(callback, result, 5, limits, 0);
        }
      };
      hostServicesCheck = () => {
        if (callbacks.size !== 0)
          throw new Error(`${relative}: ${callbacks.size} callbacks were not closed`);
      };
    }
    // Both backends call these records through the same Wasm32 C ABI.
    if (relative.endsWith("wasm-cli-hxi-value-records.wasm") || relative.endsWith("wasm-cli-gc-hxi-value-records.wasm"))
      imports.wasm32_value_records = {
        read_point: pointer => {
          if (pointer % 4 !== 0)
            throw new Error("const fixed-layout pointer is not four-byte aligned");
          const view = new DataView(moduleInstance.exports.memory.buffer);
          return view.getInt32(pointer, true) + view.getInt32(pointer + 4, true);
        },
        write_point: pointer => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          if (view.getInt32(pointer, true) !== 0 || view.getInt32(pointer + 4, true) !== 0)
            throw new Error("linear @out aggregate was not zero-initialized");
          view.setInt32(pointer, 17, true);
          view.setInt32(pointer + 4, 25, true);
        },
        update_point: pointer => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          view.setInt32(pointer, view.getInt32(pointer, true) + 1, true);
          view.setInt32(pointer + 4, view.getInt32(pointer + 4, true) + 2, true);
        },
        sum_point: pointer => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          return view.getInt32(pointer, true) + view.getInt32(pointer + 4, true);
        },
        // Record results other than a single scalar are written through a leading result pointer.
        make_point: (pointer, seed) => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          view.setInt32(pointer, seed, true);
          view.setInt32(pointer + 4, seed + 2, true);
        },
        sum_gapped: pointer => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          const bytes = new Uint8Array(moduleInstance.exports.memory.buffer, pointer, 12);
          for (let index = 1; index < 8; index++)
            if (bytes[index] !== 0)
              return 0;
          return view.getInt8(pointer) + view.getInt32(pointer + 8, true);
        },
        make_gapped: (pointer, seed) => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          new Uint8Array(moduleInstance.exports.memory.buffer, pointer, 12).fill(0);
          view.setInt8(pointer, 3);
          view.setInt32(pointer + 8, seed, true);
        },
        next_id: value => {
          if (typeof value !== "bigint")
            throw new Error("a single-u64 record must travel as an i64");
          return value + 1n;
        },
        half: value => {
          if (typeof value !== "number")
            throw new Error("a single-f64 record must travel as an f64");
          return value / 2;
        },
        scale_f32: (value, factor) => {
          if (value === 0.1 || value !== Math.fround(0.1) || factor !== 4)
            throw new Error("C float arguments must travel as f32");
          return value * factor;
        }
      };

    if (relative.endsWith("numeric-promotion.wasm"))
      imports.haxeon_runtime = {__math_ceil: Math.ceil, __math_floor: Math.floor};
    if (relative.endsWith("wasm-cli-gc-ffi-bytes.wasm"))
      imports.gc_bytes = {
        inspect_bytes: (pointer, length) => {
          const expected = [103, 99, 32, 98, 121, 116, 101, 115];
          const actual = new Uint8Array(moduleInstance.exports.memory.buffer, pointer, length);
          if (length === expected.length && expected.every((value, index) => actual[index] === value))
            return 42;
          return length === 70000 && actual[0] === 0 && actual[1] === 1 && actual[255] === 255 && actual[256] === 0 && actual[69999] === 111 ? 42 : 0;
        },
        mutate_bytes: (pointer, length) => {
          const actual = new Uint8Array(moduleInstance.exports.memory.buffer, pointer, length);
          if (length !== 8)
            return 0;
          actual[0] = 84;
          actual[7] = 33;
          return 17;
        },
        store_values: (valuePointer, countPointer) => {
          if (valuePointer % 8 !== 0 || countPointer % 8 !== 0)
            throw new Error("scalar output scratch slots are not eight-byte aligned");
          const view = new DataView(moduleInstance.exports.memory.buffer);
          if (view.getUint32(valuePointer, true) !== 0 || view.getUint32(countPointer, true) !== 0)
            throw new Error("scalar @out scratch slots were not zero-initialized");
          view.setUint32(valuePointer, 11, true);
          view.setUint32(countPointer, 0x12345678, true);
        },
        modify_i32: pointer => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          view.setInt32(pointer, view.getInt32(pointer, true) + 5, true);
          return 9;
        },
        store_point: pointer => {
          if (pointer % 16 !== 0)
            throw new Error("over-aligned aggregate scratch slot is not sixteen-byte aligned");
          const view = new DataView(moduleInstance.exports.memory.buffer);
          if (view.getInt32(pointer, true) !== 0 || view.getInt32(pointer + 4, true) !== 0
              || view.getUint32(pointer + 8, true) !== 0 || view.getUint32(pointer + 12, true) !== 0)
            throw new Error("aggregate @out scratch slot was not zero-initialized");
          view.setInt32(pointer, 17, true);
          view.setInt32(pointer + 4, 25, true);
        },
        shift_point: pointer => {
          const view = new DataView(moduleInstance.exports.memory.buffer);
          view.setInt32(pointer, view.getInt32(pointer, true) + 1, true);
          view.setInt32(pointer + 4, view.getInt32(pointer + 4, true) + 2, true);
        },
        read_point: pointer => {
          if (pointer % 4 !== 0)
            throw new Error("fixed pointer input scratch slot is not four-byte aligned");
          const view = new DataView(moduleInstance.exports.memory.buffer);
          return view.getInt32(pointer, true) + view.getInt32(pointer + 4, true);
        },
        sum_point: pointer => {
          if (pointer % 4 !== 0)
            throw new Error("by-value aggregate scratch slot is not four-byte aligned");
          const view = new DataView(moduleInstance.exports.memory.buffer);
          return view.getInt32(pointer, true) + view.getInt32(pointer + 4, true);
        },
        // A record result is written through the leading result pointer, as clang's Wasm32 C ABI returns it.
        make_point: (pointer, seed) => {
          if (pointer % 4 !== 0)
            throw new Error("record result pointer is not four-byte aligned");
          const view = new DataView(moduleInstance.exports.memory.buffer);
          view.setInt32(pointer, seed, true);
          view.setInt32(pointer + 4, seed + 2, true);
        },
        borrowed_context: () => 0x1234,
        owned_context: () => 0x5678,
        nullable_owned_context: value => value === 0 ? 0 : 0x2345,
        inspect_context: pointer => [0x1234, 0x5678, 0x2345, 0x3456].includes(pointer) ? 42 : 0,
        store_context: pointer => {
          if (pointer % 4 !== 0)
            throw new Error("opaque pointer output slot is not four-byte aligned");
          new DataView(moduleInstance.exports.memory.buffer).setUint32(pointer, 0x1234, true);
        },
        store_null_context: pointer => {
          new DataView(moduleInstance.exports.memory.buffer).setUint32(pointer, 0, true);
        },
        store_owned_context: pointer => {
          new DataView(moduleInstance.exports.memory.buffer).setUint32(pointer, 0x3456, true);
        },
        store_null_owned_context: pointer => {
          new DataView(moduleInstance.exports.memory.buffer).setUint32(pointer, 0, true);
        },
        release_context: pointer => {
          if (![0x5678, 0x2345, 0x3456].includes(pointer))
            throw new Error("owned opaque pointer released the wrong native handle");
          ownedPointerReleases.push(pointer);
        },
        read_bytes: (seed, pointer, sizePointer) => {
          const memory = moduleInstance.exports.memory;
          const view = new DataView(memory.buffer);
          if (pointer === 0) {
            view.setUint32(sizePointer, 8, true);
            return 0;
          }
          if (seed !== 7 || view.getUint32(sizePointer, true) < 5)
            return 0;
          new Uint8Array(memory.buffer, pointer, 5).set([104, 101, 108, 108, 111]);
          view.setUint32(sizePointer, 5, true);
          return 9;
        },
        fetch_bytes: () => {
          const pointer = 128;
          new Uint8Array(moduleInstance.exports.memory.buffer, pointer, 8).set([70, 70, 73, 32, 98, 121, 116, 33]);
          return pointer;
        },
        fetch_size: () => 8,
        optional_bytes: () => 0,
        optional_size: () => { throw new Error("nullable native pointer must skip its length import"); },
        fetch_owned_bytes: () => {
          const pointer = 192;
          new Uint8Array(moduleInstance.exports.memory.buffer, pointer, 4).set([79, 87, 78, 33]);
          return pointer;
        },
        owned_size: () => 4,
        release_bytes: pointer => {
          if (pointer !== 192)
            throw new Error("owned byte result released the wrong pointer");
          ownedBytesReleased = true;
          new Uint8Array(moduleInstance.exports.memory.buffer, pointer, 4).fill(0);
        }
      };
    if (relative.endsWith("wasm-cli-gc-ffi-short-struct.wasm"))
      imports.gc_bytes = {shift_point: () => { shortStructImportCalled = true; }};
    if (relative.endsWith("wasm-cli-gc-ffi-borrowed-array.wasm")) {
      const view = () => new DataView(moduleInstance.exports.memory.buffer);
      imports.gc_bytes = {
        // Writes through a non-const record pointer, which the caller must see.
        fill_point: pointer => {
          view().setInt32(pointer, 7, true);
          view().setInt32(pointer + 4, 9, true);
        },
        // Follows the record's borrowed array to the second point's y.
        second_y: pointer => view().getUint32(pointer + 4, true) === 2 ? view().getInt32(view().getUint32(pointer, true) + 12, true) : -1
      };
    }
    if (relative.endsWith("wasm-cli-gc-ffi-nested-array.wasm")) {
      const view = () => new DataView(moduleInstance.exports.memory.buffer);
      imports.gc_nested = {
        // Sums every byte reachable from an array of lists of blobs; -1 when a pointer is not a real address.
        sum_blobs: (lists, count) => {
          const memory = view();
          let sum = 0;
          for (let list = 0; list < count; list++) {
            const blobs = memory.getUint32(lists + list * 8, true), blobCount = memory.getUint32(lists + list * 8 + 4, true);
            if (blobs + blobCount * 8 > memory.byteLength)
              return -1;
            for (let blob = 0; blob < blobCount; blob++) {
              const data = memory.getUint32(blobs + blob * 8, true), size = memory.getUint32(blobs + blob * 8 + 4, true);
              if (data + size > memory.byteLength)
                return -1;
              for (let offset = 0; offset < size; offset++)
                sum += memory.getUint8(data + offset);
            }
          }
          return sum;
        }
      };
    }
    if (relative.includes("hxi-retained")) {
      const retainedMemory = () => memory == null ? moduleInstance.exports.memory : memory;
      const validOptions = pointer => {
        const buffer = retainedMemory().buffer;
        const view = new DataView(buffer);
        const bytes = new Uint8Array(buffer);
        const text = address => {
          if (address === 0)
            return null;
          let end = address;
          while (bytes[end] !== 0)
            end++;
          return new TextDecoder().decode(bytes.subarray(address, end));
        };
        const points = view.getUint32(pointer, true);
        const pointCount = view.getUint32(pointer + 4, true);
        const paths = view.getUint32(pointer + 8, true);
        const pathCount = view.getUint32(pointer + 12, true);
        const data = view.getUint32(pointer + 16, true);
        const size = view.getUint32(pointer + 20, true);
        return pointCount === 2
          && points !== 0
          && view.getInt32(points, true) === 10
          && view.getInt32(points + 4, true) === 11
          && view.getInt32(points + 8, true) === 20
          && view.getInt32(points + 12, true) === 21
          && pathCount === 2
          && paths !== 0
          && text(view.getUint32(paths, true)) === "alpha"
          && text(view.getUint32(paths + 4, true)) === "βeta"
          && size === 7
          && data !== 0
          && new TextDecoder().decode(bytes.subarray(data, data + size)) === "payload";
      };
      imports.retained = {
        retained_check: pointer => {
          const view = new DataView(retainedMemory().buffer);
          return view.getInt32(pointer, true) + view.getInt32(pointer + 4, true);
        },
        retained_check_label: pointer => {
          const buffer = retainedMemory().buffer;
          const view = new DataView(buffer);
          const bytes = new Uint8Array(buffer);
          const address = view.getUint32(pointer, true);
          let end = address;
          while (bytes[end] !== 0)
            end++;
          return new TextDecoder().decode(bytes.subarray(address, end)) === "retained-42" ? 42 : 0;
        },
        retained_check_options: pointer => validOptions(pointer) ? 42 : 0,
        retained_check_paths: (paths, count) => {
          const buffer = retainedMemory().buffer;
          const view = new DataView(buffer);
          const bytes = new Uint8Array(buffer);
          const text = address => {
            if (address === 0)
              return null;
            let end = address;
            while (bytes[end] !== 0)
              end++;
            return new TextDecoder().decode(bytes.subarray(address, end));
          };
          return count === 2
            && text(view.getUint32(paths, true)) === "alpha"
            && text(view.getUint32(paths + 4, true)) === "βeta" ? 42 : 0;
        },
        retained_check_container: (pointer, extracted) => {
          const view = new DataView(retainedMemory().buffer);
          const options = view.getUint32(pointer + 24, true);
          const count = view.getUint32(pointer + 28, true);
          return count === 1 && options !== 0 && validOptions(pointer) && validOptions(options) && validOptions(extracted) ? 42 : 0;
        }
      };
    }
    if (importedMemory)
      imports.env = {memory};
    if (relative.includes("gc-")) {
      const compiled = new WebAssembly.Module(bytes);
      const ffiBytes = relative.endsWith("wasm-cli-gc-ffi-bytes.wasm");
      const shortStruct = relative.endsWith("wasm-cli-gc-ffi-short-struct.wasm");
      const borrowedArray = relative.endsWith("wasm-cli-gc-ffi-borrowed-array.wasm");
      const nestedArray = relative.endsWith("wasm-cli-gc-ffi-nested-array.wasm");
      // The value-record fixture's natives need the scratch bridge, so it has memory and imports of its own.
      const valueRecords = relative.endsWith("wasm-cli-gc-hxi-value-records.wasm");
      const hasMemory = WebAssembly.Module.exports(compiled).some(entry => entry.name === "memory");
      if ((!ffiBytes && !shortStruct && !valueRecords && !borrowedArray && !nestedArray && WebAssembly.Module.imports(compiled).length !== 0)
          || (!ffiBytes && !shortStruct && !valueRecords && !borrowedArray && !nestedArray && hasMemory)
          || (borrowedArray && (WebAssembly.Module.imports(compiled).length !== 2 || !hasMemory))
          || (nestedArray && (WebAssembly.Module.imports(compiled).length !== 1 || !hasMemory))
          || (valueRecords && !hasMemory)
          || (ffiBytes && (WebAssembly.Module.imports(compiled).length !== 26 || !hasMemory))
          || (shortStruct && (WebAssembly.Module.imports(compiled).length !== 1 || !hasMemory))
          || WebAssembly.Module.customSections(compiled, "haxeon.gc.roots").length !== 0)
        throw new Error("Wasm GC object module unexpectedly includes linear memory or custom root metadata");
      moduleInstance = new WebAssembly.Instance(compiled, imports);
    } else {
      moduleInstance = (await WebAssembly.instantiate(bytes, imports)).instance;
    }
    const instance = moduleInstance;
    if (relative.includes("closure") && !(instance.exports.table instanceof WebAssembly.Table))
      throw new Error(`${relative}: stable Wasm function table was not exported`);
    if (relative.endsWith("wasm-cli-gc-ffi-short-struct.wasm")) {
      let trapped = false;
      try {
        instance.exports.main();
      } catch (error) {
        trapped = error instanceof WebAssembly.RuntimeError;
      }
      if (!trapped || shortStructImportCalled)
        throw new Error("wrong-sized fixed-layout structure reached the native import instead of trapping");
      continue;
    }
    const value = instance.exports.main();
    if (value !== expected)
      throw new Error(`${relative}: expected ${expected}, got ${value}`);
    if (hostServicesCheck)
      hostServicesCheck();
    if (relative.endsWith("wasm32-bytes-view.wasm") && byteViewCalls !== 2)
      throw new Error(`expected both direct and generated byte-slice calls, got ${byteViewCalls}`);
    if (relative.endsWith("wasm-cli-gc-ffi-bytes.wasm") && !ownedBytesReleased)
      throw new Error("owned byte result was not released after copying");
    if (relative.endsWith("wasm-cli-gc-ffi-bytes.wasm")
        && (ownedPointerReleases.length !== 3
          || ![0x2345, 0x3456, 0x5678].every(pointer => ownedPointerReleases.includes(pointer))))
      throw new Error("owned opaque pointer direct results and output slots were not released exactly once");
  }
  const int64Module = (await WebAssembly.instantiate(
    fs.readFileSync(`${root}/out/wasm-backend-std-string-i64.wasm`))).instance;
  const int64Cases = [
    [0, 0, "0"],
    [0, 42, "42"],
    [-1, -42, "-42"],
    [0x00200000, 1, "9007199254740993"],
    [0x7fffffff, -1, "9223372036854775807"],
    [-2147483648, 0, "-9223372036854775808"]
  ];
  const view = new DataView(int64Module.exports.memory.buffer);
  for (const [high, low, expected] of int64Cases) {
    const pointer = int64Module.exports.stringifyInt64(high, low) >>> 0;
    const length = view.getUint32(pointer + 8, true);
    const actual = new TextDecoder().decode(new Uint8Array(view.buffer, pointer + 16, length));
    if (actual !== expected)
      throw new Error(`Std.string(Int64(${high}, ${low})): expected ${expected}, got ${actual}`);
  }
  const floatModule = (await WebAssembly.instantiate(
    fs.readFileSync(`${root}/out/wasm-cli-ryu-source.wasm`))).instance;
  const floatCases = [
    [0, "0"], [40.5, "40.5"], [-42.25, "-42.25"], [0.1, "0.1"], [-0, "0"],
    [1e-6, "0.000001"], [1e-7, "1e-7"], [1e20, "100000000000000000000"], [1e21, "1e+21"],
    [Number.MIN_VALUE, "5e-324"], [Number.MAX_VALUE, "1.7976931348623157e+308"],
    [Infinity, "Infinity"], [-Infinity, "-Infinity"], [NaN, "NaN"]
  ];
  for (const [value, expected] of floatCases) {
    const pointer = floatModule.exports["wasm-ryu-source.stringifyFloat"](value) >>> 0;
    const view = new DataView(floatModule.exports.memory.buffer);
    const length = view.getUint32(pointer + 8, true);
    const actual = new TextDecoder().decode(new Uint8Array(view.buffer, pointer + 16, length));
    if (actual !== expected)
      throw new Error(`Std.string(Float(${value})): expected ${expected}, got ${actual}`);
  }
  let floatBits = 0x9e3779b97f4a7c15n;
  const floatMask = (1n << 64n) - 1n;
  const floatRaw = new ArrayBuffer(8);
  const floatBitView = new DataView(floatRaw);
  const significantDigits = value => value.split(/[eE]/, 1)[0].replace(/[^0-9]/g, "").replace(/^0+/, "").length;
  for (let index = 0; index < 10000; index++) {
    floatBits ^= floatBits << 13n;
    floatBits ^= floatBits >> 7n;
    floatBits ^= floatBits << 17n;
    floatBits &= floatMask;
    floatBitView.setBigUint64(0, floatBits, true);
    const value = floatBitView.getFloat64(0, true);
    const pointer = floatModule.exports["wasm-ryu-source.stringifyFloat"](value) >>> 0;
    const view = new DataView(floatModule.exports.memory.buffer);
    const length = view.getUint32(pointer + 8, true);
    const actual = new TextDecoder().decode(new Uint8Array(view.buffer, pointer + 16, length));
    const expected = String(value);
    const roundTrips = Number.isNaN(value) ? Number.isNaN(Number(actual)) : Number(actual) === value;
    if (!roundTrips || significantDigits(actual) !== significantDigits(expected))
      throw new Error(`Std.string(Float bits 0x${floatBits.toString(16)}): expected shortest round-trip ${expected}, got ${actual}`);
  }
  console.log("PASS: Wasm modules validate and execute");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
JS

# haxeon-host.js throws haxeon.wasm.HostError into a guest that calls an import it cannot provide.
for target in wasm32 wasm-gc; do
	haxeon_compile_async \
		--target="$target" --output="out/wasm-host-error-$target.wasm" --entry=wasm-host-error --wasm-import-memory \
		--root=tests/ffi --ffi-interface=tests/ffi/host_error.hxi tests/ffi/wasm-host-error.hx
done
haxeon_compile_wait
node - "$root_dir" <<'JS'
const fs = require("fs"), path = require("path"), vm = require("vm");
const root = process.argv[2];
vm.runInThisContext(fs.readFileSync(path.join(root, "stdlib/haxeon/wasm/haxeon-host.js"), "utf8"));
(async () => {
  for (const target of ["wasm32", "wasm-gc"]) {
    const module = new WebAssembly.Module(fs.readFileSync(path.join(root, `out/wasm-host-error-${target}.wasm`)));
    const minimum = WebAssembly.Module.imports(module).some(entry => entry.kind === "memory") ? 64 : 0;
    const memory = new WebAssembly.Memory({initial: minimum});
    // Messages go to the top page, above anything the guest uses.
    const scratch = () => memory.buffer.byteLength - 4096;
    const {exports, unavailable} = await HaxeonWasmHost.instantiate(module, {
      emscripten: {}, memory, allocate: scratch, release: () => {}});
    if (!unavailable.includes("missing_lib"))
      throw new Error(`${target}: missing_lib was not reported unavailable`);
    const result = exports.main();
    if (result !== 42)
      throw new Error(`${target}: the guest did not catch the HostError (exit ${result})`);
  }
  console.log("PASS: haxeon-host.js throws HostError into wasm32 and wasm-gc guests");
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
JS
