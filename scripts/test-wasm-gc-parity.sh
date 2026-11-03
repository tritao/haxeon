#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
haxe_bin="$root_dir/.tools/haxe/haxe"
parity_output_dir=${HAXEON_WASM_PARITY_OUTPUT_DIR:-"$root_dir/out"}
mkdir -p "$parity_output_dir"

if [[ ! -x "$haxe_bin" ]]; then
	echo "missing pinned Haxe; run ./scripts/bootstrap-tools.sh first" >&2
	exit 1
fi
source "$root_dir/scripts/haxeon-compiler.sh"

# The broader GC Bytes fixture includes GC-specific bounds behavior. The shared
# bytes-view fixture checks portable aliasing and copy semantics on both targets.
cases=(objects arrays enums closures dynamic exceptions strings)
for case_name in "${cases[@]}"; do
	source="tests/programs/wasm-gc-$case_name.hx"
	for target in wasm32 wasm-gc; do
		haxeon_compile_async \
			--target="$target" --output="$parity_output_dir/wasm-parity-$target-$case_name.wasm" \
			--entry="wasm-gc-$case_name" --root=tests/programs "$source"
	done
done

for target in wasm32 wasm-gc; do
	haxeon_compile_async \
		--target="$target" --output="$parity_output_dir/wasm-parity-$target-bytes-compare.wasm" \
		--entry=wasm-bytes-compare --root=tests/programs tests/programs/wasm-bytes-compare.hx
done

# Every program in the manifest runs on both targets and must exit as it does on HL, except
# those listed in wasm-parity-skips.tsv with the reason they cannot yet.
# Compile failures are reported with the other results; skipped programs still compile so the
# suite notices when one starts passing.
mkdir -p "$parity_output_dir/wasm-parity-logs"
while IFS=$'\t' read -r case_name _; do
	[[ -z $case_name || $case_name == \#* ]] && continue
	for target in wasm32 wasm-gc; do
		output="$parity_output_dir/wasm-parity-$target-$case_name.wasm"
		rm -f "$output"
		haxeon_compile_logged_async "$parity_output_dir/wasm-parity-logs/$target-$case_name.log" \
			--target="$target" --output="$output" --entry="$case_name" --root=tests/programs "tests/programs/$case_name.hx"
	done
done < "$root_dir/tests/programs/expected-exits.tsv"

# Run declared conformance and struct array places with inlining both enabled and disabled.
for inline in 0 1; do
	for target in wasm32 wasm-gc; do
		for value_case in member-module-shadow checked-dynamic-object-cast generic-struct-functions generic-struct-class generic-struct-reflection struct-reflection generic-struct-signal-allocations generic-nullable-substitution generic-struct-array-ranges null-method-inlining wasm-null-method-dispatch generic-constrained-owner-hash generic-constrained-owner-lookup-allocations generic-struct-owner-allocations specialized-struct-map struct-constructor-flow struct-nested-constructors struct-linear-place-alias struct-array-places struct-array-nullable-places struct-array-nested-nullable struct-array-equality struct-managed-narrow struct-managed-nullable-narrow nullable-scalar-ieee-equality; do
			HAXEON_INLINE="$inline" haxeon_compile_async \
				--target="$target" --output="$parity_output_dir/wasm-parity-$target-$value_case-inline-$inline.wasm" \
				--entry="$value_case" --root=tests/programs "tests/programs/$value_case.hx"
		done
		HAXEON_INLINE="$inline" haxeon_compile_async \
			--target="$target" --output="$parity_output_dir/wasm-parity-$target-declared-equality-inline-$inline.wasm" \
			--entry=declared-equality --root=tests/programs tests/programs/declared-equality.hx
		HAXEON_INLINE="$inline" haxeon_compile_async \
			--target="$target" --output="$parity_output_dir/wasm-parity-$target-observable-tracking-inline-$inline.wasm" \
			--entry=wasm-observable-tracking --root=stdlib --root=packages/ui/haxe --root=tests/programs \
			tests/programs/wasm-observable-tracking.hx
		HAXEON_INLINE="$inline" haxeon_compile_async \
			--target="$target" --output="$parity_output_dir/wasm-parity-$target-observable-generic-runtime-inline-$inline.wasm" \
			--entry=observable-generic-runtime --root=stdlib --root=tests/programs \
			tests/programs/observable-generic-runtime.hx
		HAXEON_INLINE="$inline" haxeon_compile_async \
			--target="$target" --output="$parity_output_dir/wasm-parity-$target-generic-struct-reflected-closure-inline-$inline.wasm" \
			--entry=wasm-generic-struct-reflected-closure --root=stdlib --root=tests/programs \
			tests/programs/wasm-generic-struct-reflected-closure.hx
		HAXEON_INLINE="$inline" haxeon_compile_async \
			--target="$target" --output="$parity_output_dir/wasm-parity-$target-value-interface-reflection-inline-$inline.wasm" \
			--entry=wasm-value-interface-reflection --root=stdlib --root=tests/programs \
			tests/programs/wasm-value-interface-reflection.hx
		if [[ "$target" == wasm32 ]]; then
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-memory-stats --wasm-gc-stress \
				--export=SignalCensus.prepare --export=SignalCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm32-signal-census-inline-$inline.wasm" \
				--entry=generic-struct-signal-allocations --root=stdlib --root=tests/programs tests/programs/generic-struct-signal-allocations.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-runtime-neutral \
				--output="$parity_output_dir/wasm-parity-wasm32-null-inlining-neutral-inline-$inline.wasm" \
				--entry=null-method-inlining --root=stdlib --root=tests/programs tests/programs/null-method-inlining.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-memory-stats --wasm-gc-stress \
				--export=GenericRangeCensus.prepare --export=GenericRangeCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm32-generic-ranges-census-inline-$inline.wasm" \
				--entry=generic-struct-array-ranges --root=stdlib --root=tests/programs tests/programs/generic-struct-array-ranges.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-runtime-neutral \
				--output="$parity_output_dir/wasm-parity-wasm32-null-method-neutral-inline-$inline.wasm" \
				--entry=wasm-null-method-dispatch --root=stdlib --root=tests/programs tests/programs/wasm-null-method-dispatch.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-memory-stats --wasm-gc-stress \
				--export=ClosureCensus.prepare --export=ClosureCensus.perform --export=ClosureCensus.stress \
				--export=ClosureCensus.apply --export=ClosureCensus.isMissing --export=ClosureCensus.exposeNumber --export=ClosureCensus.applyNumber \
				--output="$parity_output_dir/wasm-parity-wasm32-scalar-closure-census-inline-$inline.wasm" \
				--entry=wasm-scalar-closure-census --root=stdlib --root=tests/programs tests/programs/wasm-scalar-closure-census.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-memory-stats --wasm-gc-stress \
				--export=MapCensus.prepare --export=MapCensus.perform --export=MapCensus.grow --export=MapCensus.empty \
				--output="$parity_output_dir/wasm-parity-wasm32-specialized-map-census-inline-$inline.wasm" \
				--entry=specialized-struct-map --root=stdlib --root=tests/programs tests/programs/specialized-struct-map.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-memory-stats --wasm-gc-stress \
				--export=LookupCensus.prepare --export=LookupCensus.perform --export=LookupCensus.stress \
				--output="$parity_output_dir/wasm-parity-wasm32-constrained-lookup-census-inline-$inline.wasm" \
				--entry=generic-constrained-owner-lookup-allocations --root=stdlib --root=tests/programs \
				tests/programs/generic-constrained-owner-lookup-allocations.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-memory-stats \
				--export=Inspect.make --export=Inspect.makeMixed --export=Inspect.checkMixed --export=Census.prepare --export=Census.construct \
				--output="$parity_output_dir/wasm-parity-wasm32-flat-object-layout-inline-$inline.wasm" \
				--entry=wasm-flat-object-layout --root=tests/programs tests/programs/wasm-flat-object-layout.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-gc-stress \
				--output="$parity_output_dir/wasm-parity-wasm32-flat-object-stress-inline-$inline.wasm" \
				--entry=wasm-flat-object-layout --root=tests/programs tests/programs/wasm-flat-object-layout.hx
		else
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=Census.prepare --export=Census.construct \
				--output="$parity_output_dir/wasm-parity-wasm-gc-flat-object-layout-inline-$inline.wasm" \
				--entry=wasm-flat-object-layout --root=tests/programs tests/programs/wasm-flat-object-layout.hx
		fi
		if [[ "$target" == wasm-gc ]]; then
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=SignalCensus.prepare --export=SignalCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm-gc-signal-census-inline-$inline.wasm" \
				--entry=generic-struct-signal-allocations --root=stdlib --root=tests/programs tests/programs/generic-struct-signal-allocations.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=GenericRangeCensus.prepare --export=GenericRangeCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm-gc-generic-ranges-census-inline-$inline.wasm" \
				--entry=generic-struct-array-ranges --root=stdlib --root=tests/programs tests/programs/generic-struct-array-ranges.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=ClosureCensus.prepare --export=ClosureCensus.perform \
				--export=ClosureCensus.apply --export=ClosureCensus.isMissing --export=ClosureCensus.exposeNumber --export=ClosureCensus.applyNumber \
				--output="$parity_output_dir/wasm-parity-wasm-gc-scalar-closure-census-inline-$inline.wasm" \
				--entry=wasm-scalar-closure-census --root=stdlib --root=tests/programs tests/programs/wasm-scalar-closure-census.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=MapCensus.prepare --export=MapCensus.perform --export=MapCensus.grow --export=MapCensus.empty \
				--output="$parity_output_dir/wasm-parity-wasm-gc-specialized-map-census-inline-$inline.wasm" \
				--entry=specialized-struct-map --root=stdlib --root=tests/programs tests/programs/specialized-struct-map.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=Main.prepare --export=Main.perform \
				--output="$parity_output_dir/wasm-parity-wasm-gc-reflected-closure-census-inline-$inline.wasm" \
				--entry=wasm-generic-struct-reflected-closure --root=stdlib --root=tests/programs \
				tests/programs/wasm-generic-struct-reflected-closure.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=LookupCensus.prepare --export=LookupCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm-gc-constrained-lookup-census-inline-$inline.wasm" \
				--entry=generic-constrained-owner-lookup-allocations --root=stdlib --root=tests/programs \
				tests/programs/generic-constrained-owner-lookup-allocations.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm-gc --wasm-gc-allocation-count \
				--export=AllocationCensus.prepare --export=AllocationCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm-gc-constrained-owner-census-inline-$inline.wasm" \
				--entry=generic-struct-owner-allocations --root=tests/programs \
				tests/programs/generic-struct-owner-allocations.hx
		fi
	done
done

# Struct array places and Observable instrumentation also run on HashLink in both modes.
for inline in 0 1; do
	for value_case in member-module-shadow checked-dynamic-object-cast generic-struct-functions generic-struct-class generic-struct-reflection struct-reflection generic-struct-signal-allocations generic-nullable-substitution generic-struct-array-ranges null-method-inlining wasm-null-method-dispatch generic-constrained-owner-hash generic-constrained-owner-lookup-allocations generic-struct-owner-allocations specialized-struct-map struct-constructor-flow struct-nested-constructors struct-linear-place-alias struct-array-places struct-array-nullable-places struct-array-nested-nullable struct-array-equality struct-managed-narrow struct-managed-nullable-narrow nullable-scalar-ieee-equality; do
		HAXEON_INLINE="$inline" haxeon_compile \
			--target=hl --output="$parity_output_dir/$value_case-inline-$inline.hl" \
			--entry="$value_case" --root=tests/programs "tests/programs/$value_case.hx"
		status=0
		LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			"$root_dir/.tools/hashlink/hl" "$parity_output_dir/$value_case-inline-$inline.hl" || status=$?
		if [[ $status -ne 42 ]]; then
			echo "$value_case (inline=$inline) expected exit 42, got $status" >&2
			exit 1
		fi
	done
	for value_case in struct-managed-narrow struct-managed-nullable-narrow; do
		HAXEON_INLINE="$inline" haxeon_compile \
			--target=hl --define=native-abi-target=portable-abi32 --define=managed_long32 \
			--output="$parity_output_dir/$value_case-abi32-inline-$inline.hl" \
			--entry="$value_case" --root=tests/programs "tests/programs/$value_case.hx"
		status=0
		LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			"$root_dir/.tools/hashlink/hl" "$parity_output_dir/$value_case-abi32-inline-$inline.hl" || status=$?
		if [[ $status -ne 42 ]]; then
			echo "$value_case (32-bit ABI, inline=$inline) expected exit 42, got $status" >&2
			exit 1
		fi
	done
	HAXEON_INLINE="$inline" haxeon_compile \
		--target=hl --output="$parity_output_dir/observable-tracking-inline-$inline.hl" \
		--entry=wasm-observable-tracking --root=stdlib --root=packages/ui/haxe --root=tests/programs \
		tests/programs/wasm-observable-tracking.hx
	HAXEON_INLINE="$inline" haxeon_compile \
		--target=hl --output="$parity_output_dir/observable-generic-runtime-inline-$inline.hl" \
		--entry=observable-generic-runtime --root=stdlib --root=tests/programs \
		tests/programs/observable-generic-runtime.hx
	HAXEON_INLINE="$inline" haxeon_compile \
		--target=hl --output="$parity_output_dir/generic-struct-reflected-closure-inline-$inline.hl" \
		--entry=wasm-generic-struct-reflected-closure --root=stdlib --root=tests/programs \
		tests/programs/wasm-generic-struct-reflected-closure.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$root_dir/.tools/hashlink/hl" "$parity_output_dir/generic-struct-reflected-closure-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Reflected struct closure fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	HAXEON_INLINE="$inline" haxeon_compile \
		--target=hl --output="$parity_output_dir/value-interface-reflection-inline-$inline.hl" \
		--entry=wasm-value-interface-reflection --root=stdlib --root=tests/programs \
		tests/programs/wasm-value-interface-reflection.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$root_dir/.tools/hashlink/hl" "$parity_output_dir/value-interface-reflection-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Reflected value interface fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	HAXEON_INLINE="$inline" haxeon_compile \
		--target=hl --output="$parity_output_dir/flat-object-layout-inline-$inline.hl" \
		--entry=wasm-flat-object-layout --root=tests/programs tests/programs/wasm-flat-object-layout.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$root_dir/.tools/hashlink/hl" "$parity_output_dir/flat-object-layout-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Flat object layout fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$root_dir/.tools/hashlink/hl" "$parity_output_dir/observable-generic-runtime-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Observable generic runtime fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$root_dir/.tools/hashlink${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$root_dir/.tools/hashlink/hl" "$parity_output_dir/observable-tracking-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Observable HashLink fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
done

haxeon_compile_async \
	--target=wasm32 --wasm-gc-stress --output="$parity_output_dir/wasm-parity-wasm32-bytes-view-stress.wasm" \
	--entry=bytes-view --root=tests/programs tests/programs/bytes-view.hx

# Inline-record FieldGet allocates an owning view. Stress GC must retain the live
# destination copy while constructing that view, before any later call safepoint.
haxeon_compile_async \
	--target=wasm32 --wasm-gc-stress --output="$parity_output_dir/wasm-parity-wasm32-value-nested-roots-stress.wasm" \
	--entry=wasm-value-nested-roots --root=tests/programs tests/programs/wasm-value-nested-roots.hx

cases+=(bytes-compare)
haxeon_compile_wait

node - "$root_dir" "$parity_output_dir" "${cases[@]}" <<'JS'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const outputDir = process.argv[3];
const gcCases = process.argv.slice(4);

function table(file) {
  return fs.readFileSync(path.join(root, "tests", "programs", file), "utf8").split("\n")
    .filter(line => line.trim() !== "" && !line.startsWith("#")).map(line => line.split("\t"));
}

const modes = new Map(table("wasm-parity-skips.tsv").map(([name, mode]) => [name, mode]));
const cases = gcCases.map(name => ({name, expected: 42}))
	.concat(table("expected-exits.tsv").map(([name, expected]) => ({name, expected: Number(expected)})));
for (const [name, mode] of modes)
  if (!["skip", "gc-linear-memory"].includes(mode))
    throw new Error(`Unknown Wasm parity mode ${mode} for ${name}`);
for (const name of modes.keys())
  if (!cases.some(entry => entry.name === name))
    throw new Error(`wasm-parity-skips.tsv lists ${name}, which is not in expected-exits.tsv`);

// Host functions of the haxeon_runtime ABI, matching native/runtime/core.c.
const runtime = {
  __math_is_finite: Number.isFinite,
  __math_ceil: Math.ceil,
  __math_floor: Math.floor,
  __math_round: value => Math.floor(value + 0.5) | 0,
  __math_pow: Math.pow,
  __math_sqrt: Math.sqrt,
  __math_fmod: (value, modulus) => value % modulus,
  __math_sin: Math.sin,
  __math_cos: Math.cos,
  __math_tan: Math.tan,
  __math_atan2: Math.atan2,
  __math_exp: Math.exp,
  __math_log: Math.log,
  __std_int_f64: Math.trunc
};

// Sys.exit is the host's "std.sys_exit": it ends the program, so it unwinds the guest with the status.
class ExitSignal {
  constructor(code) { this.code = code; }
}
const std = {sys_exit: code => { throw new ExitSignal(code); }};
// The Observable fixture links optional output paths through reflection. A parity fixture must
// never write output; keep the imports explicit and fail if either path becomes active.
const haxeonHost = {
  write_output: () => { throw new Error("Unexpected Wasm parity output"); },
  flush_output: () => { throw new Error("Unexpected Wasm parity flush"); }
};

async function run(name, target) {
	const file = path.join(outputDir, `wasm-parity-${target}-${name}.wasm`);
  if (!fs.existsSync(file)) {
    const log = path.join(outputDir, "wasm-parity-logs", `${target}-${name}.log`);
    const text = fs.existsSync(log) ? fs.readFileSync(log, "utf8") : "";
    const reason = text.split("\n").find(line => /Uncaught exception|: E\d{4}:/.test(line)) ?? "";
    return {failure: `did not compile: ${reason.replace(/^.*(Uncaught exception |E\d{4}: )/, "").slice(0, 120)}`};
  }
  const module = new WebAssembly.Module(fs.readFileSync(file));
  const imports = WebAssembly.Module.imports(module);
  const missing = imports.filter(entry => entry.module === "std" ? !(entry.name in std)
    : entry.module === "haxeon_runtime" ? !(entry.name in runtime)
    : entry.module === "haxeon_host" ? !(entry.name in haxeonHost) : true);
  if (missing.length !== 0)
    return {failure: `imports ${missing.map(entry => `${entry.module}.${entry.name}`).join(", ")}`};
  if (target === "wasm-gc") {
    const hasMemory = WebAssembly.Module.exports(module).some(entry => entry.name === "memory" && entry.kind === "memory");
    // The Observable fixture exercises wire encoding, whose UTF-8 buffer uses GC scratch memory.
    const expectsMemory = modes.get(name) === "gc-linear-memory"
      || name.startsWith("observable-tracking-inline-");
    if (hasMemory !== expectsMemory)
      return {failure: expectsMemory ? "GC C-native module is missing scratch memory" : "GC module contains undeclared linear memory"};
    if (WebAssembly.Module.customSections(module, "haxeon.gc.roots").length !== 0)
      return {failure: "GC module contains custom root metadata"};
  }
  const instance = await WebAssembly.instantiate(module, {haxeon_runtime: runtime, haxeon_host: haxeonHost, std});
  try {
    return {exit: instance.exports.main()};
  } catch (error) {
    if (error instanceof ExitSignal)
      return {exit: error.code};
    // An uncaught Haxe exception ends the program with status 1, as on HL.
    if (error instanceof WebAssembly.Exception)
      return {exit: 1};
    return {failure: `trap: ${error.message}`};
  }
}

(async () => {
  const failures = [];
  let skipped = 0;
  for (const {name, expected} of cases) {
    const mode = modes.get(name);
    const results = {};
    for (const target of ["wasm32", "wasm-gc"]) {
      const result = await run(name, target);
      if (result.failure === undefined && result.exit !== expected)
        result.failure = `expected ${expected}, got ${result.exit}`;
      results[target] = result;
    }
    const passing = results.wasm32.failure === undefined && results["wasm-gc"].failure === undefined;
    if (mode === "skip") {
      skipped++;
      if (passing)
        failures.push(`${name}: passes on both targets; remove it from tests/programs/wasm-parity-skips.tsv`);
      continue;
    }
    for (const target of ["wasm32", "wasm-gc"])
      if (results[target].failure !== undefined)
        failures.push(`${name} (${target}): ${results[target].failure}`);
  }
  for (const inline of [0, 1]) {
    for (const name of ["member-module-shadow", "checked-dynamic-object-cast", "generic-struct-functions", "generic-struct-class", "generic-struct-reflection", "struct-reflection", "generic-struct-signal-allocations", "generic-nullable-substitution", "generic-struct-array-ranges", "null-method-inlining", "wasm-null-method-dispatch", "generic-constrained-owner-hash", "generic-constrained-owner-lookup-allocations", "generic-struct-owner-allocations", "specialized-struct-map", "struct-constructor-flow", "struct-nested-constructors", "struct-linear-place-alias", "struct-array-places", "struct-managed-narrow", "struct-managed-nullable-narrow"])
      for (const target of ["wasm32", "wasm-gc"]) {
        const result = await run(`${name}-inline-${inline}`, target);
        if (result.failure === undefined && result.exit !== 42)
          result.failure = `expected 42, got ${result.exit}`;
        if (result.failure !== undefined)
          failures.push(`${name} (inline=${inline}, ${target}): ${result.failure}`);
        else
          console.log(`PASS: ${name} on ${target}, inline=${inline}`);
      }
  }
  for (const inline of [0, 1]) {
    for (const target of ["wasm32", "wasm-gc"]) {
      const result = await run(`declared-equality-inline-${inline}`, target);
      if (result.failure === undefined && result.exit !== 42)
        result.failure = `expected 42, got ${result.exit}`;
      if (result.failure !== undefined)
        failures.push(`declared-equality (inline=${inline}, ${target}): ${result.failure}`);
      else
        console.log(`PASS: declared-equality on ${target}, inline=${inline}`);
    }
  }
  for (const inline of [0, 1]) {
    for (const target of ["wasm32", "wasm-gc"]) {
      const result = await run(`observable-tracking-inline-${inline}`, target);
      if (result.failure === undefined && result.exit !== 42)
        result.failure = `expected 42, got ${result.exit}`;
      if (result.failure !== undefined)
        failures.push(`observable-tracking (inline=${inline}, ${target}): ${result.failure}`);
      else
        console.log(`PASS: observable-tracking on ${target}, inline=${inline}`);
    }
  }
  for (const inline of [0, 1]) {
    for (const target of ["wasm32", "wasm-gc"]) {
      const result = await run(`observable-generic-runtime-inline-${inline}`, target);
      if (result.failure === undefined && result.exit !== 42)
        result.failure = `expected 42, got ${result.exit}`;
      if (result.failure !== undefined)
        failures.push(`observable-generic-runtime (inline=${inline}, ${target}): ${result.failure}`);
      else
        console.log(`PASS: observable-generic-runtime on ${target}, inline=${inline}`);
    }
  }
  for (const inline of [0, 1]) {
    for (const target of ["wasm32", "wasm-gc"]) {
      const result = await run(`generic-struct-reflected-closure-inline-${inline}`, target);
      if (result.failure === undefined && result.exit !== 42)
        result.failure = `expected 42, got ${result.exit}`;
      if (result.failure !== undefined)
        failures.push(`generic-struct-reflected-closure (inline=${inline}, ${target}): ${result.failure}`);
      else
        console.log(`PASS: generic-struct-reflected-closure on ${target}, inline=${inline}`);
	  const reflectedValue = await run(`value-interface-reflection-inline-${inline}`, target);
	  if (reflectedValue.failure === undefined && reflectedValue.exit !== 42)
	    reflectedValue.failure = `expected 42, got ${reflectedValue.exit}`;
	  if (reflectedValue.failure !== undefined)
	    failures.push(`value-interface-reflection (inline=${inline}, ${target}): ${reflectedValue.failure}`);
	  else
	    console.log(`PASS: value-interface-reflection on ${target}, inline=${inline}`);
	  const flatBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-flat-object-layout-inline-${inline}.wasm`));
	  const flat = (await WebAssembly.instantiate(flatBytes, {haxeon_runtime: runtime, std})).instance.exports;
	  if (flat.main() !== 42) failures.push(`flat object semantics (inline=${inline}, ${target})`);
	  if (target === "wasm32") {
	    const pointer = flat["Inspect.make"]();
	    const actual = Array.from(new Uint8Array(flat.memory.buffer, pointer + 8, 12));
	    const expected = [1, 0, 250, 0, 46, 251, 0, 0, 42, 0, 0, 0];
	    if (actual.join(",") !== expected.join(","))
	      failures.push(`flat object bytes (inline=${inline}): ${actual}`);
	    const mixedPointer = flat["Inspect.makeMixed"]();
	    const mixedBytes = Array.from(new Uint8Array(flat.memory.buffer, mixedPointer + 16, 12));
	    if (mixedBytes.join(",") !== expected.join(",") || flat["Inspect.checkMixed"]() !== 73)
	      failures.push(`nested flat object bytes or references (inline=${inline}): ${mixedBytes}`);
	    const stressBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-flat-object-stress-inline-${inline}.wasm`));
	    const stress = (await WebAssembly.instantiate(stressBytes, {haxeon_runtime: runtime, std})).instance.exports;
	    if (stress.main() !== 42) failures.push(`flat object GC stress (inline=${inline})`);
	  }
	  flat["Census.prepare"](1024);
	  const count = target === "wasm32" ? () => flat["haxeon.memory.allocation_count"]() : () => flat.__allocation_count();
	  const before = count(), sum = flat["Census.construct"](1024), allocated = count() - before;
	  if (sum !== 43008 || allocated !== 1024)
	    failures.push(`flat object census (inline=${inline}, ${target}): sum=${sum}, allocations=${allocated}`);
	  else
	    console.log(`PASS: flat object census on ${target}, inline=${inline}`);
    }
    const bytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm-gc-reflected-closure-census-inline-${inline}.wasm`));
    const instance = (await WebAssembly.instantiate(bytes, {haxeon_runtime: runtime, std})).instance;
    const prepared = instance.exports["Main.prepare"]();
    const before = instance.exports.__allocation_count();
    const result = instance.exports["Main.perform"](1024);
    const allocations = instance.exports.__allocation_count() - before;
    if (prepared !== 42 || result !== 17408 || allocations !== 0)
      failures.push(`reflected closure census (inline=${inline}): prepare=${prepared}, result=${result}, allocations=${allocations}`);
    else
      console.log(`PASS: reflected closure census on wasm-gc, inline=${inline}`);
	const constrainedBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm-gc-constrained-owner-census-inline-${inline}.wasm`));
	const constrained = (await WebAssembly.instantiate(constrainedBytes, {haxeon_runtime: runtime, std})).instance;
	constrained.exports["AllocationCensus.prepare"]();
	for (const n of [8, 1024]) {
	  const before = constrained.exports.__allocation_count();
	  const result = constrained.exports["AllocationCensus.perform"](n);
	  const allocations = constrained.exports.__allocation_count() - before;
	  if (result !== n * (n - 1) / 2 || allocations !== 0)
	    failures.push(`constrained owner census (inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	  else
	    console.log(`PASS: constrained owner census on wasm-gc, inline=${inline}, n=${n}`);
	}
	const lookupBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm-gc-constrained-lookup-census-inline-${inline}.wasm`));
	const lookup = (await WebAssembly.instantiate(lookupBytes, {haxeon_runtime: runtime, std})).instance;
	lookup.exports["LookupCensus.prepare"]();
	for (const n of [8, 1024]) {
	  const before = lookup.exports.__allocation_count();
	  const result = lookup.exports["LookupCensus.perform"](n);
	  const allocations = lookup.exports.__allocation_count() - before;
	  if (result !== n * 14 || allocations !== 0)
	    failures.push(`constrained lookup census (inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	  else
	    console.log(`PASS: constrained lookup census on wasm-gc, inline=${inline}, n=${n}`);
	}
	const linearLookupBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-constrained-lookup-census-inline-${inline}.wasm`));
	const linearLookup = (await WebAssembly.instantiate(linearLookupBytes, {haxeon_runtime: runtime, std})).instance;
	linearLookup.exports["LookupCensus.prepare"]();
	for (const n of [8, 1024]) {
	  const before = linearLookup.exports["haxeon.memory.allocation_count"]();
	  const result = linearLookup.exports["LookupCensus.perform"](n);
	  const allocations = linearLookup.exports["haxeon.memory.allocation_count"]() - before;
	  if (result !== n * 14 || allocations !== 0)
	    failures.push(`constrained lookup census (wasm32, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	  else
	    console.log(`PASS: constrained lookup census on wasm32, inline=${inline}, n=${n}`);
	}
	if (linearLookup.exports["LookupCensus.stress"](256) !== 2304)
	  failures.push(`constrained lookup lost live references (wasm32 stress GC, inline=${inline})`);
	const neutralNullBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-null-method-neutral-inline-${inline}.wasm`));
	const neutralNull = (await WebAssembly.instantiate(neutralNullBytes, {haxeon_host: {fuel_charge: () => 1}})).instance;
	if (neutralNull.exports.main() !== 42) failures.push(`null method exception (wasm32 runtime-neutral, inline=${inline})`);
	const neutralInlineBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-null-inlining-neutral-inline-${inline}.wasm`));
	const neutralInline = (await WebAssembly.instantiate(neutralInlineBytes, {haxeon_host: {fuel_charge: () => 1}})).instance;
	if (neutralInline.exports.main() !== 42) failures.push(`inlined null method exception (wasm32 runtime-neutral, inline=${inline})`);
	for (const target of ["wasm32", "wasm-gc"]) {
	  const signalBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-signal-census-inline-${inline}.wasm`));
	  const signal = (await WebAssembly.instantiate(signalBytes, {haxeon_runtime: runtime, std})).instance;
	  signal.exports["SignalCensus.prepare"]();
	  const signalCount = target === "wasm32" ? signal.exports["haxeon.memory.allocation_count"] : signal.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = signalCount(), result = signal.exports["SignalCensus.perform"](n), allocations = signalCount() - before;
	    if (result !== n * (n - 1) / 2 || allocations !== 0)
	      failures.push(`struct signal census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: struct signal census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const rangesBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-generic-ranges-census-inline-${inline}.wasm`));
	  const ranges = (await WebAssembly.instantiate(rangesBytes, {haxeon_runtime: runtime, std})).instance;
	  const rangeCount = target === "wasm32" ? ranges.exports["haxeon.memory.allocation_count"] : ranges.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    ranges.exports["GenericRangeCensus.prepare"](n);
	    const before = rangeCount(), result = ranges.exports["GenericRangeCensus.perform"](), allocations = rangeCount() - before;
	    if (result !== 42 || allocations !== 9)
	      failures.push(`generic range census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: generic range census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const closureBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-scalar-closure-census-inline-${inline}.wasm`));
	  const closure = (await WebAssembly.instantiate(closureBytes, {haxeon_runtime: runtime, std})).instance;
	  closure.exports["ClosureCensus.prepare"]();
	  const closureCount = target === "wasm32" ? closure.exports["haxeon.memory.allocation_count"] : closure.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = closureCount(), result = closure.exports["ClosureCensus.perform"](n), allocations = closureCount() - before;
	    if (result !== n * 11 || allocations !== 0)
	      failures.push(`scalar closure census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: scalar closure census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const exportedRead = closure.exports["ClosureCensus.expose"]();
	  const exportedNumber = closure.exports["ClosureCensus.exposeNumber"]();
	  const missingClosure = target === "wasm32" ? 0 : null;
	  if (closure.exports["ClosureCensus.apply"](exportedRead) !== 11
	      || closure.exports["ClosureCensus.applyNumber"](exportedNumber) !== 11
	      || closure.exports["ClosureCensus.isMissing"](missingClosure) !== 1
	      || closure.exports["ClosureCensus.isMissing"](exportedRead) !== 0)
	    failures.push(`exported scalar closure round trip (${target}, inline=${inline})`);
	  else console.log(`PASS: exported scalar closures on ${target}, inline=${inline}`);
	  if (target === "wasm32" && closure.exports["ClosureCensus.stress"](256) !== 35456)
	    failures.push(`scalar closure lost live references (wasm32 stress GC, inline=${inline})`);
	  const bytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-specialized-map-census-inline-${inline}.wasm`));
	  const map = (await WebAssembly.instantiate(bytes, {haxeon_runtime: runtime, std})).instance;
	  map.exports["MapCensus.prepare"]();
	  const count = target === "wasm32" ? map.exports["haxeon.memory.allocation_count"] : map.exports.__allocation_count;
	  for (const n of [8, 128]) {
	    const before = count(), result = map.exports["MapCensus.empty"](n), allocations = count() - before;
	    if (result !== 0 || allocations !== n)
	      failures.push(`empty map census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: empty map census on ${target}, inline=${inline}, n=${n}`);
	  }
	  for (const n of [8, 1024]) {
	    const before = count(), result = map.exports["MapCensus.perform"](n), allocations = count() - before;
	    if (result !== n * 28 || allocations !== 0)
	      failures.push(`specialized map census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: specialized map census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const growth = [];
	  for (const n of [512, 1024, 2048]) {
	    const before = count(), result = map.exports["MapCensus.grow"](n), allocations = count() - before;
	    if (result !== 42) failures.push(`specialized map growth (${target}, inline=${inline}, n=${n}): result=${result}`);
	    growth.push(allocations);
	  }
	  if (growth[1] - growth[0] > 80 || growth[2] - growth[1] > 80)
	    failures.push(`specialized map growth allocates per entry (${target}, inline=${inline}): ${growth}`);
	  else console.log(`PASS: specialized map growth on ${target}, inline=${inline}: ${growth}`);
	}
  }
  const stressBytes = fs.readFileSync(path.join(outputDir, "wasm-parity-wasm32-bytes-view-stress.wasm"));
  const stressInstance = await WebAssembly.instantiate(stressBytes, {});
  if (stressInstance.instance.exports.main() !== 42)
    failures.push("bytes-view (wasm32 stress GC): view failed to retain and alias its source");
  const nestedBytes = fs.readFileSync(path.join(outputDir, "wasm-parity-wasm32-value-nested-roots-stress.wasm"));
  const nestedInstance = await WebAssembly.instantiate(nestedBytes, {haxeon_runtime: runtime, std});
  if (nestedInstance.instance.exports.main() !== 42)
    failures.push("nested-value (wasm32 stress GC): inline view allocation lost live value copies");
  if (failures.length !== 0)
    throw new Error(`Wasm parity failures:\n  ${failures.join("\n  ")}`);
  console.log(`PASS: ${cases.length - skipped} Haxe fixtures agree across Wasm32, Wasm GC and HL (${skipped} skipped)`);
})().catch(error => {
  console.error(error.message ?? error);
  process.exitCode = 1;
});
JS
