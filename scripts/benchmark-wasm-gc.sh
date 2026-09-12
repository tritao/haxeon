#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
stress_artifact="$root_dir/out/wasm-gc-benchmark-stress.wasm"
budget_artifact="$root_dir/out/wasm-gc-benchmark-budget.wasm"
sample_count=${1:-5}

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe_bin" --cwd "$root_dir" -cp "$root_dir/src" --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --wasm-memory-stats --wasm-gc-stress \
	--export=wasm-gc-invariants.allocationBurst --output="$stress_artifact" \
	--entry=wasm-gc-invariants --root="$root_dir/tests/programs" "$root_dir/tests/programs/wasm-gc-invariants.hx"

"$haxe_bin" --cwd "$root_dir" -cp "$root_dir/src" --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --wasm-memory-stats \
	--export=wasm-gc-invariants.allocationBurst \
	--export=wasm-gc-invariants.deepGraphExercise --export=wasm-gc-invariants.wideGraphExercise \
	--output="$budget_artifact" --entry=wasm-gc-invariants --root="$root_dir/tests/programs" \
	"$root_dir/tests/programs/wasm-gc-invariants.hx"

node - "$stress_artifact" "$budget_artifact" "$sample_count" <<'JS'
const fs = require("fs");
const {performance} = require("perf_hooks");

const samples = Number(process.argv[4]);
if (!Number.isInteger(samples) || samples < 1 || samples > 50)
	throw new Error("sample count must be an integer from 1 to 50");

const modules = {
	stress: new WebAssembly.Module(fs.readFileSync(process.argv[2])),
	budgeted: new WebAssembly.Module(fs.readFileSync(process.argv[3]))
};
const workloads = [
	{policy: "stress", name: "allocation-burst", exportName: "allocationBurst", argument: 2048},
	{policy: "budgeted", name: "allocation-burst", exportName: "allocationBurst", argument: 2048},
	{policy: "budgeted", name: "deep-chain", exportName: "deepGraphExercise", argument: 20000},
	{policy: "budgeted", name: "wide-array", exportName: "wideGraphExercise", argument: 30000}
];

function median(values) {
	const sorted = values.slice().sort((a, b) => a - b);
	const middle = Math.floor(sorted.length / 2);
	return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

async function instantiate(policy) {
	return new WebAssembly.Instance(modules[policy], {}).exports;
}

function run(exports, workload) {
	const fn = exports[`wasm-gc-invariants.${workload.exportName}`];
	const before = {
		allocations: exports["haxeon.memory.allocation_count"](),
		allocatedBytes: exports["haxeon.memory.allocated_bytes"](),
		collections: exports["haxeon.memory.collection_count"]()
	};
	const start = performance.now();
	const result = fn(workload.argument);
	const elapsed = performance.now() - start;
	if (result !== 42)
		throw new Error(`${workload.name} returned ${result}, expected 42`);
	return {
		elapsed,
		allocations: exports["haxeon.memory.allocation_count"]() - before.allocations,
		allocatedBytes: exports["haxeon.memory.allocated_bytes"]() - before.allocatedBytes,
		collections: exports["haxeon.memory.collection_count"]() - before.collections,
		linearMemoryBytes: exports.memory.buffer.byteLength
	};
}

(async () => {
	const results = [];
	for (const workload of workloads) {
		// Warm the JS/Wasm call path separately; every measured sample gets a fresh heap.
		run(await instantiate(workload.policy), workload);
		const measurements = [];
		for (let index = 0; index < samples; index++)
			measurements.push(run(await instantiate(workload.policy), workload));
		results.push({
			policy: workload.policy,
			workload: workload.name,
			median_ms: median(measurements.map(sample => sample.elapsed)),
			median_allocations: median(measurements.map(sample => sample.allocations)),
			median_allocated_bytes: median(measurements.map(sample => sample.allocatedBytes)),
			median_collections: median(measurements.map(sample => sample.collections)),
			median_linear_memory_bytes: median(measurements.map(sample => sample.linearMemoryBytes))
		});
	}
	console.log(JSON.stringify({samples, results}, null, 2));
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
JS
