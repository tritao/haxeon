#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi

mkdir -p "$root_dir/out"
for target in wasm32 wasm-gc; do
	"$haxe_bin" --cwd "$root_dir" -cp src --run compiler.tools.HaxeonCompiler \
		--target="$target" --output="$root_dir/out/$target-ryu-benchmark.wasm" \
		--entry=wasm-ryu-benchmark \
		--export=wasm-ryu-benchmark.decimalChecksum \
		--export=wasm-ryu-benchmark.formatLength \
		--export=wasm-ryu-benchmark.stdStringLength \
		--export=wasm-ryu-benchmark.stdStringDynamicLength \
		--root=tests/programs tests/programs/wasm-ryu-benchmark.hx
done

node - "$root_dir/out/wasm32-ryu-benchmark.wasm" "$root_dir/out/wasm-gc-ryu-benchmark.wasm" <<'JS'
const fs = require("node:fs");

const iterations = Number(process.env.RYU_BENCH_ITERATIONS || 100000);
const samples = Number(process.env.RYU_BENCH_SAMPLES || 9);
const warmup = Number(process.env.RYU_BENCH_WARMUP || 10000);
const targets = [
	["wasm32", process.argv[2]],
	["wasm-gc", process.argv[3]],
];
const cases = [
	["toDecimal", "decimalChecksum"],
	["Ryu.format", "formatLength"],
	["Std.string(Float)", "stdStringLength"],
	["Std.string(Dynamic<Float>)", "stdStringDynamicLength"],
];

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

async function measure(target, bytes) {
	const module = await WebAssembly.compile(bytes);
	const result = {};
	for (const [label, exportName] of cases) {
		const measurements = [];
		let checksum = 0;
		for (let sample = 0; sample < samples; sample++) {
			const instance = await WebAssembly.instantiate(module);
			const call = instance.exports[`wasm-ryu-benchmark.${exportName}`];
			for (let index = 0; index < warmup; index++) {
				checksum = (Math.imul(checksum, 31) + call(values[index & 2047])) | 0;
			}
			const started = performance.now();
			for (let index = 0; index < iterations; index++) {
				checksum = (Math.imul(checksum, 31) + call(values[index & 2047])) | 0;
			}
			measurements.push((performance.now() - started) * 1000 / iterations);
		}
		result[label] = {
			median_us: median(measurements),
			samples_us: measurements,
			checksum,
		};
	}
	for (const label of ["Std.string(Float)", "Std.string(Dynamic<Float>)"])
		if (result["Ryu.format"].checksum !== result[label].checksum)
			throw new Error(`${target}: ${label} returned different string lengths from Ryu.format`);
	return result;
}

(async () => {
	const results = {};
	for (const [target, path] of targets)
		results[target] = await measure(target, fs.readFileSync(path));
	console.log(JSON.stringify({
		engine: `Node ${process.version}`,
		iterations,
		samples,
		warmup,
		results,
	}, null, 2));
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
JS
