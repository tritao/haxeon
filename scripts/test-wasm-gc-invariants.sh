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
	--export=wasm-gc-invariants.throwThroughRoots --output="$artifact" \
	--entry=wasm-gc-invariants --root="$root_dir/tests/programs" "$root_dir/tests/programs/wasm-gc-invariants.hx"

node - "$artifact" <<'JS'
const fs = require("fs");
const artifact = process.argv[2];

(async () => {
	const bytes = fs.readFileSync(artifact);
	const {instance} = await WebAssembly.instantiate(bytes, {});
	const {exports} = instance;
	if (exports.main() !== 42)
		throw new Error("GC allocator invariant fixture returned the wrong value");
	const heapTop = exports["haxeon.memory.heap_top"]();
	if (exports["wasm-gc-invariants.exercise"](24) !== 42)
		throw new Error("GC free-list exercise returned the wrong value");
	const afterReuse = exports["haxeon.memory.heap_top"]();
	if (afterReuse !== heapTop)
		throw new Error(`GC free-list reuse grew heap_top from ${heapTop} to ${afterReuse}`);
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
	console.log("PASS: Wasm GC free-list split/unlink and exceptional root-frame cleanup");
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
JS
