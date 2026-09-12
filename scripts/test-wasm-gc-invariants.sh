#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
artifact="$root_dir/out/wasm-gc-invariants.wasm"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe_bin" --cwd "$root_dir" -cp "$root_dir/src" --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --wasm-memory-stats --export=wasm-gc-invariants.exercise --export=wasm-gc-invariants.rootSnapshotExercise \
	--export=wasm-gc-invariants.throwThroughRoots --export=wasm-gc-invariants.reallocateLargeArray --output="$artifact" \
	--entry=wasm-gc-invariants --root="$root_dir/tests/programs" "$root_dir/tests/programs/wasm-gc-invariants.hx"

node - "$artifact" <<'JS'
const fs = require("fs");
const artifact = process.argv[2];

(async () => {
	const bytes = fs.readFileSync(artifact);
	const {instance} = await WebAssembly.instantiate(bytes, {});
	const {exports} = instance;
	const assertHeapBlocks = () => {
		const view = new DataView(exports.memory.buffer);
		const end = exports["haxeon.memory.heap_top"]();
		let cursor = exports["haxeon.memory.heap_base"]();
		while (cursor < end) {
			const size = view.getUint32(cursor, true);
			const flags = view.getUint32(cursor + 4, true);
			if (size < 16 || size % 8 !== 0 || cursor + size > end)
				throw new Error(`Invalid inline GC block size ${size} at ${cursor}`);
			if ((flags & 0xffff0000) !== 0x48470000)
				throw new Error(`Invalid inline GC block tag at ${cursor}`);
			if ((flags & 1) !== 0 && view.getUint32(cursor + 8, true) !== cursor + 16)
				throw new Error(`Invalid inline GC block owner at ${cursor}`);
			if ((flags & 1) === 0 && view.getUint32(cursor + 8, true) !== 0)
				throw new Error(`Free GC block retained an owner at ${cursor}`);
			cursor += size;
		}
		if (cursor !== end)
			throw new Error(`GC block walk ended at ${cursor}, expected heap_top ${end}`);
	};
	if (exports.main() !== 42)
		throw new Error("GC allocator invariant fixture returned the wrong value");
	const heapTop = exports["haxeon.memory.heap_top"]();
	assertHeapBlocks();
	if (exports["haxeon.memory.metadata_top"]() !== exports["haxeon.memory.metadata_base"]())
		throw new Error("inline GC block headers unexpectedly allocated out-of-line metadata");
	if (exports["wasm-gc-invariants.reallocateLargeArray"]() !== 1024)
		throw new Error("GC coalescing fixture returned the wrong value");
	if (exports["haxeon.memory.heap_top"]() !== heapTop)
		throw new Error("GC failed to coalesce adjacent dead blocks before a large reallocation");
	assertHeapBlocks();
	if (exports["wasm-gc-invariants.exercise"](24) !== 42)
		throw new Error("GC free-list exercise returned the wrong value");
	const afterReuse = exports["haxeon.memory.heap_top"]();
	if (afterReuse !== heapTop)
		throw new Error(`GC free-list reuse grew heap_top from ${heapTop} to ${afterReuse}`);
	assertHeapBlocks();
	if (exports["wasm-gc-invariants.rootSnapshotExercise"]() !== 42)
		throw new Error("GC root-snapshot exercise returned the wrong value");
	const afterRootWarmup = exports["haxeon.memory.heap_top"]();
	for (let index = 0; index < 4; index++) {
		if (exports["wasm-gc-invariants.rootSnapshotExercise"]() !== 42)
			throw new Error("GC root-snapshot exercise returned the wrong value");
	}
	const afterRootReuse = exports["haxeon.memory.heap_top"]();
	if (afterRootReuse !== afterRootWarmup)
		throw new Error(`GC stale shadow roots grew heap_top from ${afterRootWarmup} to ${afterRootReuse}`);
	assertHeapBlocks();
	for (let index = 0; index < 5000; index++) {
		let caught = false;
		try {
			exports["wasm-gc-invariants.throwThroughRoots"]();
		} catch (error) {
			if (!(error instanceof WebAssembly.Exception))
				throw error;
			caught = true;
		}
		if (!caught)
			throw new Error("Expected throwThroughRoots to raise a Wasm exception");
	}
	assertHeapBlocks();
	console.log("PASS: Wasm GC free-list split/unlink and exceptional root-frame cleanup");
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
JS
