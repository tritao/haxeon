#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
artifact="$root_dir/out/wasm-gc-invariants.wasm"
normal_artifact="$root_dir/out/wasm-gc-budget.wasm"
map_artifact="$root_dir/out/wasm-gc-map-object.wasm"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe_bin" --cwd "$root_dir" -cp "$root_dir/src" --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --wasm-memory-stats --wasm-gc-stress --export=wasm-gc-invariants.exercise --export=wasm-gc-invariants.rootSnapshotExercise \
	--export=wasm-gc-invariants.throwThroughRoots --export=wasm-gc-invariants.reallocateLargeArray --export=wasm-gc-invariants.allocationBurst \
	--export=wasm-gc-invariants.growBeyondInitialMemory --export=wasm-gc-invariants.referenceArrayRootExercise \
	--export=wasm-gc-invariants.referenceArrayGrowthExercise \
	--export=wasm-gc-invariants.cycleExercise --export=wasm-gc-invariants.enumRootExercise \
	--export=wasm-gc-invariants.closureRootExercise --export=wasm-gc-invariants.iteratorRootExercise --output="$artifact" \
	--entry=wasm-gc-invariants --root="$root_dir/tests/programs" "$root_dir/tests/programs/wasm-gc-invariants.hx"

"$haxe_bin" --cwd "$root_dir" -cp "$root_dir/src" --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --wasm-memory-stats --export=wasm-gc-invariants.allocationBurst \
	--export=wasm-gc-invariants.growBeyondInitialMemory --export=wasm-gc-invariants.deepGraphExercise \
	--export=wasm-gc-invariants.wideGraphExercise --output="$normal_artifact" \
	--entry=wasm-gc-invariants --root="$root_dir/tests/programs" "$root_dir/tests/programs/wasm-gc-invariants.hx"

"$haxe_bin" --cwd "$root_dir" -cp "$root_dir/src" --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --wasm-gc-stress --output="$map_artifact" \
	--entry=map-object --root="$root_dir/tests/programs" "$root_dir/tests/programs/map-object.hx"

node - "$artifact" "$normal_artifact" "$map_artifact" <<'JS'
const fs = require("fs");
const artifact = process.argv[2];
const normalArtifact = process.argv[3];
const mapArtifact = process.argv[4];

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
	if (exports["wasm-gc-invariants.referenceArrayRootExercise"]() !== 39)
		throw new Error("GC failed to trace active reference-array elements");
	if (exports["wasm-gc-invariants.referenceArrayGrowthExercise"]() !== 39)
		throw new Error("GC failed to trace reference-array elements after backing-store growth");
	assertHeapBlocks();
	if (exports["wasm-gc-invariants.cycleExercise"]() !== 39)
		throw new Error("GC failed to terminate and preserve a cyclic reference graph");
	if (exports["wasm-gc-invariants.enumRootExercise"]() !== 39)
		throw new Error("GC failed to trace the active reference-bearing enum case");
	if (exports["wasm-gc-invariants.closureRootExercise"]() !== 39)
		throw new Error("GC failed to trace a bound closure receiver");
	if (exports["wasm-gc-invariants.iteratorRootExercise"]() !== 39)
		throw new Error("GC failed to trace an iterator's source array");
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
	const normalBytes = fs.readFileSync(normalArtifact);
	const {instance: normalInstance} = await WebAssembly.instantiate(normalBytes, {});
	const normal = normalInstance.exports;
	if (normal.main() !== 42)
		throw new Error("Normal-policy GC fixture returned the wrong value");
	const collectionsBeforeBurst = normal["haxeon.memory.collection_count"]();
	if (normal["wasm-gc-invariants.allocationBurst"](128) !== 42)
		throw new Error("Normal-policy allocation burst returned the wrong value");
	if (normal["haxeon.memory.collection_count"]() !== collectionsBeforeBurst)
		throw new Error("Normal Wasm allocation policy collected during a small allocation burst");
	const pagesBeforeGrowth = normal.memory.buffer.byteLength;
	const collectionsBeforeGrowth = normal["haxeon.memory.collection_count"]();
	if (normal["wasm-gc-invariants.growBeyondInitialMemory"]() !== 20000)
		throw new Error("Normal-policy heap-growth fixture returned the wrong value");
	if (normal.memory.buffer.byteLength <= pagesBeforeGrowth)
		throw new Error("Heap-growth fixture did not grow linear memory");
	if (normal["haxeon.memory.collection_count"]() <= collectionsBeforeGrowth)
		throw new Error("Allocator grew linear memory without first collecting under pressure");
	console.log("PASS: Wasm GC allocation budget and collect-before-grow policy");
	if (normal["wasm-gc-invariants.deepGraphExercise"](20000) !== 42)
		throw new Error("Iterative GC failed to retain a deep reference graph");
	if (normal["wasm-gc-invariants.wideGraphExercise"](30000) !== 42)
		throw new Error("Iterative GC failed to retain a wide graph through its worklist");
	console.log("PASS: Wasm GC iterative tracing handles deep and wide graphs");
	const mapBytes = fs.readFileSync(mapArtifact);
	const {instance: mapInstance} = await WebAssembly.instantiate(mapBytes, {});
	if (mapInstance.exports.main() !== 42)
		throw new Error("Stress collection corrupted reference map keys/values");
	console.log("PASS: Wasm GC tracing preserves reference map entries");
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
JS
