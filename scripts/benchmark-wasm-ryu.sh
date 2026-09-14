#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
wasm_file="$root_dir/out/wasm-ryu-benchmark.wasm"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
	--target=wasm32 --output="$wasm_file" --entry=wasm-ryu-benchmark \
	--export=wasm-ryu-benchmark.decimalChecksum \
	--export=wasm-ryu-benchmark.stringifyFloat \
	--root=tests/programs tests/programs/wasm-ryu-benchmark.hx

node - "$wasm_file" <<'JS'
const fs = require("node:fs");
const path = process.argv[2];
const iterations = Number(process.env.RYU_BENCH_ITERATIONS || 30000);
const samples = Number(process.env.RYU_BENCH_SAMPLES || 7);
const warmup = Number(process.env.RYU_BENCH_WARMUP || 5000);
const wasmBytes = fs.readFileSync(path);

function makeValues(count) {
	const values = new Float64Array(count);
	const raw = new ArrayBuffer(8);
	const view = new DataView(raw);
	let bits = 0x9e3779b97f4a7c15n;
	const mask = (1n << 64n) - 1n;
	for (let index = 0; index < count; index++) {
		while (true) {
			bits ^= bits << 13n;
			bits ^= bits >> 7n;
			bits ^= bits << 17n;
			bits &= mask;
			view.setBigUint64(0, bits, true);
			const value = view.getFloat64(0, true);
			if (Number.isFinite(value)) {
				values[index] = value;
				break;
			}
		}
	}
	return values;
}

const values = makeValues(2048);
const median = numbers => numbers.slice().sort((left, right) => left - right)[numbers.length >> 1];

async function run(kind) {
	const module = await WebAssembly.compile(wasmBytes);
	const measurements = [];
	let checksum = 0;
	for (let sample = 0; sample < samples; sample++) {
		const instance = await WebAssembly.instantiate(module);
		const call = kind === "core"
			? instance.exports["wasm-ryu-benchmark.decimalChecksum"]
			: instance.exports["wasm-ryu-benchmark.stringifyFloat"];
		let memoryBuffer = instance.exports.memory.buffer;
		let memory = new DataView(memoryBuffer);
		const stringLength = pointer => {
			if (memoryBuffer !== instance.exports.memory.buffer) {
				memoryBuffer = instance.exports.memory.buffer;
				memory = new DataView(memoryBuffer);
			}
			return memory.getUint32((pointer >>> 0) + 8, true);
		};
		for (let index = 0; index < warmup; index++) {
			const result = call(values[index & 2047]);
			checksum ^= kind === "core" ? result : stringLength(result);
		}
		const started = performance.now();
		for (let index = 0; index < iterations; index++) {
			const result = call(values[index & 2047]);
			checksum ^= kind === "core" ? result : stringLength(result);
		}
		measurements.push((performance.now() - started) * 1000 / iterations);
	}
	return {median_us: median(measurements), samples_us: measurements, checksum};
}

(async () => {
	console.log(JSON.stringify({
		engine: `Node ${process.version}`,
		iterations,
		samples,
		warmup,
		core_toDecimal: await run("core"),
		full_format: await run("format")
	}, null, 2));
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
JS
