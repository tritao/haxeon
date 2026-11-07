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
# One list drives compilation and execution for every target and inline setting.
inline_cases=(
	reactive-write-scope
	reactive-thread-isolation
	dead-pure-values
	receiver-check-elision
	non-null-facts
	field-forwarding-blocks
	jump-threading
	identity-class
	enum-generated-dependencies
	enum-concrete-payloads
	enum-unused-lane-payload
	enum-interface-conformance
	scoped-cleanup
	defer-cleanup
	defer-exception-stack
	reactive-effect-failure-recovery
	reactive-derived-cycle
	reactive-dependency-identity
	reactive-dependency-scale
	generic-interface-value-carriers
	generic-erased-raw-pointer
	generic-managed-reference-closure
	generic-erased-bytes-reference-shapes
	wasm-bytes-runtime-kinds
	generic-erased-runtime-kinds
	generic-erased-function-reference-shapes
	generic-erased-array-function-checks
	generic-erased-reference-checks
	generic-erased-numeric-checks
	struct-closure-dynamic-array
	scalar-closure-nested-callback
	scalar-closure-identity
	specialized-map-scalar-keys
	NativeU32RuntimeValues
	hash-float-dependency
	hash-float-extremes
	struct-array-iterator-escape
	enum-array-iterator-escape
	struct-array-reflection-escape
	struct-array-string-escape
	member-module-shadow
	checked-dynamic-object-cast
	generic-struct-functions
	generic-struct-class
	generic-struct-reflection
	struct-reflection
	generic-struct-signal-allocations
	generic-nullable-substitution
	generic-struct-array-ranges
	null-method-inlining
	wasm-null-method-dispatch
	generic-constrained-owner-hash
	generic-constrained-owner-lookup-allocations
	generic-struct-owner-allocations
	specialized-struct-map
	struct-constructor-flow
	struct-nested-constructors
	struct-linear-place-alias
	array-insert-negative-index
	struct-array-lane-policy
	struct-array-word-access
	struct-array-places
	struct-array-nullable-places
	struct-array-nested-nullable
	struct-array-equality
	struct-array-dynamic-equality
	struct-managed-narrow
	struct-managed-nullable-narrow
	nullable-scalar-ieee-equality
)
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
		if [[ "$target" == wasm32 ]]; then iterator_census_flags=(--wasm-memory-stats --wasm-gc-stress); else iterator_census_flags=(--wasm-gc-allocation-count); fi
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=KeyPathCensus.prepare --export=KeyPathCensus.known --export=KeyPathCensus.knownComposition --export=KeyPathCensus.escapedClass \
			--export=KeyPathCensus.escapedStruct --export=KeyPathCensus.escapedStructValue --export=KeyPathCensus.escapedStaticStruct --export=KeyPathCensus.escapedComposition \
			--output="$parity_output_dir/wasm-parity-$target-key-path-census-inline-$inline.wasm" \
			--entry=key-paths --root=tests/programs tests/programs/key-paths.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" \
			--export=SpecPointers.foreign --export=SpecNullReads.prepare --export=SpecNullReads.direct --export=SpecNullReads.known --export=SpecNullReads.escaped \
			--output="$parity_output_dir/wasm-parity-$target-key-path-semantics-inline-$inline.wasm" \
			--entry=key-path-semantics --root=tests/programs tests/programs/key-path-semantics.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=DeferCensus.perform --output="$parity_output_dir/wasm-parity-$target-defer-census-inline-$inline.wasm" \
			--entry=defer-cleanup --root=tests/programs tests/programs/defer-cleanup.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ScopedCensus.prepare --export=ScopedCensus.perform --export=ScopedCensus.performValue --export=ScopedCensus.performNullableValue \
			--export=ScopedCensus.performMutableValue --export=ScopedCensus.performNullableMutableValue --export=ScopedCensus.prepareComposite --export=ScopedCensus.performComposite \
			--output="$parity_output_dir/wasm-parity-$target-scoped-census-inline-$inline.wasm" \
			--entry=scoped-cleanup --root=tests/programs tests/programs/scoped-cleanup.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ArrayWordBench.prepare --export=ArrayWordBench.perform \
			--output="$parity_output_dir/wasm-parity-$target-word-access-census-inline-$inline.wasm" \
			--entry=struct-array-word-access --root=tests/programs tests/programs/struct-array-word-access.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=LanePolicyCensus.prepare --export=LanePolicyCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-lane-policy-census-inline-$inline.wasm" \
			--entry=struct-array-lane-policy --root=tests/programs tests/programs/struct-array-lane-policy.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=CarrierCensus.prepare --export=CarrierCensus.pointers --export=CarrierCensus.pointerGetter --export=CarrierCensus.ints \
			--export=CarrierCensus.floats --export=CarrierCensus.values --export=CarrierCensus.genericPointers \
			--export=CarrierCensus.genericInts --export=CarrierCensus.genericFloats --export=CarrierCensus.genericValues \
			--export=CarrierCensus.boundInts --export=CarrierCensus.boundValues --export=CarrierCensus.derivedInts \
			--export=CarrierCensus.checkMutation --export=CarrierCensus.checkNullable --export=CarrierCensus.checkInvalid \
			--output="$parity_output_dir/wasm-parity-$target-interface-carriers-inline-$inline.wasm" \
			--entry=generic-interface-value-carriers --root=tests/programs tests/programs/generic-interface-value-carriers.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=PointerBoundaryCensus.prepare --export=PointerBoundaryCensus.perform --export=PointerBoundaryCensus.clear \
			--output="$parity_output_dir/wasm-parity-$target-raw-pointer-census-inline-$inline.wasm" \
			--entry=generic-erased-raw-pointer --root=tests/programs tests/programs/generic-erased-raw-pointer.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ManagedClosureCensus.prepare --export=ManagedClosureCensus.perform --export=ManagedClosureCensus.literalOnly \
			--output="$parity_output_dir/wasm-parity-$target-managed-closure-census-inline-$inline.wasm" \
			--entry=generic-managed-reference-closure --root=tests/programs tests/programs/generic-managed-reference-closure.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=BoundaryClosureCensus.prepare --export=BoundaryClosureCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-erased-closure-census-inline-$inline.wasm" \
			--entry=generic-erased-array-function-checks --root=tests/programs tests/programs/generic-erased-array-function-checks.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ScalarClosureIdentityCensus.prepare --export=ScalarClosureIdentityCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-scalar-closure-identity-census-inline-$inline.wasm" \
			--entry=scalar-closure-identity --root=tests/programs tests/programs/scalar-closure-identity.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ClosureSignatureCensus.prepare --export=ClosureSignatureCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-closure-signature-census-inline-$inline.wasm" \
			--entry=wasm-closure-signature-census --root=tests/programs tests/programs/wasm-closure-signature-census.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ScalarMapCensus.prepare --export=ScalarMapCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-scalar-map-census-inline-$inline.wasm" \
			--entry=specialized-map-scalar-keys --root=tests/programs tests/programs/specialized-map-scalar-keys.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=FloatHashCensus.prepare --export=FloatHashCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-float-hash-census-inline-$inline.wasm" \
			--entry=hash-float-extremes --root=tests/programs tests/programs/hash-float-extremes.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=DynamicArrayEqualityCensus.prepare --export=DynamicArrayEqualityCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-value-equality-census-inline-$inline.wasm" \
			--entry=struct-array-dynamic-equality --root=tests/programs tests/programs/struct-array-dynamic-equality.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=IteratorCensus.prepare --export=IteratorCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-iterator-census-inline-$inline.wasm" \
			--entry=struct-array-iterator-escape --root=tests/programs tests/programs/struct-array-iterator-escape.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ObservablePlaceCensus.prepare --export=ObservablePlaceCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-observable-place-census-inline-$inline.wasm" \
			--entry=observable-struct-place --root=stdlib --root=tests/programs tests/programs/observable-struct-place.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=EffectAllocationCensus.prepare --export=EffectAllocationCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-effect-census-inline-$inline.wasm" \
			--entry=reactive-effect-allocations --root=stdlib --root=tests/programs tests/programs/reactive-effect-allocations.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ReactiveCaptureCensus.prepare --export=ReactiveCaptureCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-reactive-capture-census-inline-$inline.wasm" \
			--entry=reactive-capture-allocations --root=stdlib --root=tests/programs tests/programs/reactive-capture-allocations.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ReactiveScaleCensus.prepare --export=ReactiveScaleCensus.perform --export=ReactiveScaleCensus.performEffect \
			--output="$parity_output_dir/wasm-parity-$target-reactive-scale-census-inline-$inline.wasm" \
			--entry=reactive-dependency-scale --root=stdlib --root=tests/programs tests/programs/reactive-dependency-scale.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=IdentityClassCensus.prepare --export=IdentityClassCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-identity-class-census-inline-$inline.wasm" \
			--entry=identity-class --root=stdlib --root=tests/programs tests/programs/identity-class.hx
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${iterator_census_flags[@]}" \
			--export=ScopeCreationCensus.prepare --export=ScopeCreationCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-scope-creation-census-inline-$inline.wasm" \
			--entry=reactive-write-scope --root=stdlib --root=tests/programs tests/programs/reactive-write-scope.hx
		for value_case in "${inline_cases[@]}"; do
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
		unbox_flags=(--wasm-gc-allocation-count)
		if [[ "$target" == wasm32 ]]; then unbox_flags=(--wasm-memory-stats --wasm-gc-stress); fi
		HAXEON_INLINE="$inline" haxeon_compile_async --target="$target" "${unbox_flags[@]}" \
			--export=InterfaceUnboxCensus.prepare --export=InterfaceUnboxCensus.perform \
			--output="$parity_output_dir/wasm-parity-$target-interface-unbox-census-inline-$inline.wasm" \
			--entry=struct-interface-unbox-census --root=tests/programs tests/programs/struct-interface-unbox-census.hx
		if [[ "$target" == wasm32 ]]; then
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-gc-stress --wasm-memory-stats \
				--export=PointerGcLeafCensus.make --export=PointerGcLeafCensus.hold --export=PointerGcLeafCensus.collect \
				--export=CallbackGcLeafCensus.make --export=CallbackGcLeafCensus.hold --export=CallbackGcLeafCensus.collect \
				--output="$parity_output_dir/wasm-parity-wasm32-raw-pointer-gc-leaf-inline-$inline.wasm" \
				--entry=wasm-raw-pointer-gc-leaf --root=tests/programs tests/programs/wasm-raw-pointer-gc-leaf.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-runtime-neutral \
				--export=PointerBoundaryCensus.prepare \
				--output="$parity_output_dir/wasm-parity-wasm32-raw-pointer-neutral-inline-$inline.wasm" \
				--entry=generic-erased-raw-pointer --root=tests/programs tests/programs/generic-erased-raw-pointer.hx
			HAXEON_INLINE="$inline" haxeon_compile_async --target=wasm32 --wasm-memory-stats --wasm-gc-stress \
				--export=EnumEscapeCensus.prepare --export=EnumEscapeCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm32-enum-escape-census-inline-$inline.wasm" \
				--entry=enum-dynamic-allocations --root=stdlib --root=tests/programs tests/programs/enum-dynamic-allocations.hx
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
				--export=EnumEscapeCensus.prepare --export=EnumEscapeCensus.perform \
				--output="$parity_output_dir/wasm-parity-wasm-gc-enum-escape-census-inline-$inline.wasm" \
				--entry=enum-dynamic-allocations --root=stdlib --root=tests/programs tests/programs/enum-dynamic-allocations.hx
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
	HAXEON_INLINE="$inline" haxeon_compile --target=hl \
		--output="$parity_output_dir/key-path-semantics-inline-$inline.hl" --entry=key-path-semantics --root=tests/programs tests/programs/key-path-semantics.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/key-path-semantics-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Key path HashLink semantics (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	HAXEON_INLINE="$inline" haxeon_compile --target=hl \
		--output="$parity_output_dir/key-paths-inline-$inline.hl" --entry=key-paths --root=tests/programs tests/programs/key-paths.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/key-paths-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Key path HashLink census (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	HAXEON_INLINE="$inline" haxeon_compile --target=hl \
		--output="$parity_output_dir/defer-allocation-hl-inline-$inline.hl" \
		--entry=defer-allocation-hl --root=tests/fixtures/scoped-cleanup tests/fixtures/scoped-cleanup/defer-allocation-hl.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/defer-allocation-hl-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "defer HashLink allocation census (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	for value_case in "${inline_cases[@]}"; do
		HAXEON_INLINE="$inline" haxeon_compile \
			--target=hl --output="$parity_output_dir/$value_case-inline-$inline.hl" \
			--entry="$value_case" --root=tests/programs "tests/programs/$value_case.hx"
		status=0
		LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			"$haxeon_hl" "$parity_output_dir/$value_case-inline-$inline.hl" || status=$?
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
		LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			"$haxeon_hl" "$parity_output_dir/$value_case-abi32-inline-$inline.hl" || status=$?
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
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/generic-struct-reflected-closure-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Reflected struct closure fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	HAXEON_INLINE="$inline" haxeon_compile \
		--target=hl --output="$parity_output_dir/value-interface-reflection-inline-$inline.hl" \
		--entry=wasm-value-interface-reflection --root=stdlib --root=tests/programs \
		tests/programs/wasm-value-interface-reflection.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/value-interface-reflection-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Reflected value interface fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	HAXEON_INLINE="$inline" haxeon_compile \
		--target=hl --output="$parity_output_dir/flat-object-layout-inline-$inline.hl" \
		--entry=wasm-flat-object-layout --root=tests/programs tests/programs/wasm-flat-object-layout.hx
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/flat-object-layout-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Flat object layout fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/observable-generic-runtime-inline-$inline.hl" || status=$?
	if [[ $status -ne 42 ]]; then
		echo "Observable generic runtime fixture (inline=$inline) expected exit 42, got $status" >&2
		exit 1
	fi
	status=0
	LD_LIBRARY_PATH="$root_dir/out:$hashlink_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
		"$haxeon_hl" "$parity_output_dir/observable-tracking-inline-$inline.hl" || status=$?
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

node - "$root_dir" "$parity_output_dir" "${cases[@]}" --inline-cases "${inline_cases[@]}" <<'JS'
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const outputDir = process.argv[3];
const argumentsAfterOutput = process.argv.slice(4);
const inlineBoundary = argumentsAfterOutput.indexOf("--inline-cases");
if (inlineBoundary < 0) throw new Error("Missing inline parity fixture list");
const gcCases = argumentsAfterOutput.slice(0, inlineBoundary);
const inlineCases = argumentsAfterOutput.slice(inlineBoundary + 1);

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
    for (const name of inlineCases)
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
      const unboxBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-interface-unbox-census-inline-${inline}.wasm`));
      const unbox = (await WebAssembly.instantiate(unboxBytes, {haxeon_runtime: runtime, std})).instance.exports;
      unbox["InterfaceUnboxCensus.prepare"]();
      unbox["InterfaceUnboxCensus.perform"](1);
      const unboxCount = target === "wasm32" ? unbox["haxeon.memory.allocation_count"] : unbox.__allocation_count;
      for (const count of [8, 1024]) {
        const before = unboxCount();
        const result = unbox["InterfaceUnboxCensus.perform"](count);
        const allocations = unboxCount() - before;
        if (result !== 42 * count || allocations !== 0)
          failures.push(`interface unbox (inline=${inline}, ${target}, n=${count}): result=${result}, allocations=${allocations}`);
        else console.log(`PASS: interface unbox on ${target}, inline=${inline}, n=${count}, allocations=0`);
      }
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
	const leafBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-raw-pointer-gc-leaf-inline-${inline}.wasm`));
	const leaf = (await WebAssembly.instantiate(leafBytes, {haxeon_runtime: runtime, std})).instance.exports;
	const victim = leaf["PointerGcLeafCensus.make"]();
	leaf["PointerGcLeafCensus.hold"](victim);
	// Linear heap block headers are 16 bytes; flags occupy the second word and bit 0 means allocated.
	const beforeLeaf = new DataView(leaf.memory.buffer).getInt32(victim - 12, true);
	leaf["PointerGcLeafCensus.collect"]();
	const afterLeaf = new DataView(leaf.memory.buffer).getInt32(victim - 12, true);
	if ((beforeLeaf & 1) === 0 || (afterLeaf & 1) !== 0)
	  failures.push(`raw pointer box retained a managed object (wasm32, inline=${inline}, before=${beforeLeaf}, after=${afterLeaf})`);
	else console.log(`PASS: raw pointer box is a GC leaf on wasm32, inline=${inline}`);
	const callbackLeaf = (await WebAssembly.instantiate(leafBytes, {haxeon_runtime: runtime, std})).instance.exports;
	const callbackVictim = callbackLeaf["CallbackGcLeafCensus.make"]();
	callbackLeaf["CallbackGcLeafCensus.hold"](callbackVictim);
	const beforeCallback = new DataView(callbackLeaf.memory.buffer).getInt32(callbackVictim - 12, true);
	callbackLeaf["CallbackGcLeafCensus.collect"]();
	const afterCallback = new DataView(callbackLeaf.memory.buffer).getInt32(callbackVictim - 12, true);
	if ((beforeCallback & 1) === 0 || (afterCallback & 1) !== 0)
	  failures.push(`native callback box retained a managed object (wasm32, inline=${inline}, before=${beforeCallback}, after=${afterCallback})`);
	else console.log(`PASS: native callback box is a GC leaf on wasm32, inline=${inline}`);
	const neutralPointerBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-raw-pointer-neutral-inline-${inline}.wasm`));
	const neutralPointer = (await WebAssembly.instantiate(neutralPointerBytes, {haxeon_host: {fuel_charge: () => 1}})).instance;
	if (neutralPointer.exports["PointerBoundaryCensus.prepare"](1234) !== 42)
	  failures.push(`raw pointer boundary (wasm32 runtime-neutral, inline=${inline})`);
	const neutralNullBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-null-method-neutral-inline-${inline}.wasm`));
	const neutralNull = (await WebAssembly.instantiate(neutralNullBytes, {haxeon_host: {fuel_charge: () => 1}})).instance;
	if (neutralNull.exports.main() !== 42) failures.push(`null method exception (wasm32 runtime-neutral, inline=${inline})`);
	const neutralInlineBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-wasm32-null-inlining-neutral-inline-${inline}.wasm`));
	const neutralInline = (await WebAssembly.instantiate(neutralInlineBytes, {haxeon_host: {fuel_charge: () => 1}})).instance;
	if (neutralInline.exports.main() !== 42) failures.push(`inlined null method exception (wasm32 runtime-neutral, inline=${inline})`);
	for (const target of ["wasm32", "wasm-gc"]) {
	  const pointerBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-raw-pointer-census-inline-${inline}.wasm`));
	  const carrierBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-interface-carriers-inline-${inline}.wasm`));
	  const carrier = (await WebAssembly.instantiate(carrierBytes, {haxeon_runtime: runtime, std})).instance;
	  carrier.exports["CarrierCensus.prepare"](1234);
	  if (!carrier.exports["CarrierCensus.checkMutation"]()) failures.push(`typed interface receiver mutation (${target}, inline=${inline})`);
	  if (!carrier.exports["CarrierCensus.checkNullable"]()) failures.push(`typed interface nullable scalar (${target}, inline=${inline})`);
	  if (!carrier.exports["CarrierCensus.checkInvalid"]()) failures.push(`typed interface invalid cast (${target}, inline=${inline})`);
	  const carrierCount = target === "wasm32" ? carrier.exports["haxeon.memory.allocation_count"] : carrier.exports.__allocation_count;
	  for (const name of ["pointers", "pointerGetter", "ints", "floats", "values", "genericPointers", "genericInts", "genericFloats", "genericValues", "boundInts", "boundValues", "derivedInts"]) {
	    for (const n of [8, 1024]) {
	      const before = carrierCount(), result = carrier.exports[`CarrierCensus.${name}`](n), allocations = carrierCount() - before;
	      if (result !== n || allocations !== 0)
	        failures.push(`typed interface ${name} (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	      else console.log(`PASS: typed interface ${name} on ${target}, inline=${inline}, n=${n}`);
	    }
	  }
	  const pointer = (await WebAssembly.instantiate(pointerBytes, {haxeon_runtime: runtime, std})).instance;
	  if (pointer.exports["PointerBoundaryCensus.prepare"](0) !== 42)
	    failures.push(`raw pointer null round trip (${target}, inline=${inline})`);
	  if (pointer.exports["PointerBoundaryCensus.prepare"](12) !== 42)
	    failures.push(`raw pointer and Int kinds (${target}, inline=${inline})`);
	  if (pointer.exports["PointerBoundaryCensus.prepare"](1234) !== 42)
	    failures.push(`raw pointer boundary (${target}, inline=${inline})`);
	  const pointerCount = target === "wasm32" ? pointer.exports["haxeon.memory.allocation_count"] : pointer.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = pointerCount(), result = pointer.exports["PointerBoundaryCensus.perform"](n), allocations = pointerCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`raw pointer census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: raw pointer census on ${target}, inline=${inline}, n=${n}`);
	  }
	  if (pointer.exports["PointerBoundaryCensus.clear"]() !== 42)
	    failures.push(`raw pointer null boundary (${target}, inline=${inline})`);
	  const managedBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-managed-closure-census-inline-${inline}.wasm`));
	  const managed = (await WebAssembly.instantiate(managedBytes, {haxeon_runtime: runtime, std})).instance;
	  managed.exports["ManagedClosureCensus.prepare"]();
	  const managedCount = target === "wasm32" ? managed.exports["haxeon.memory.allocation_count"] : managed.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = managedCount(), result = managed.exports["ManagedClosureCensus.perform"](n), allocations = managedCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`managed closure census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: managed closure census on ${target}, inline=${inline}, n=${n}`);
	  }
	  for (const n of [8, 1024]) {
	    const before = managedCount(), result = managed.exports["ManagedClosureCensus.literalOnly"](n), allocations = managedCount() - before;
	    const maximum = target === "wasm-gc" && n === 8 ? 2 : 0;
	    if (result !== n || allocations > maximum)
	      failures.push(`literal reuse census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: literal reuse census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const erasedBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-erased-closure-census-inline-${inline}.wasm`));
	  const erased = (await WebAssembly.instantiate(erasedBytes, {haxeon_runtime: runtime, std})).instance;
	  erased.exports["BoundaryClosureCensus.prepare"]();
	  const erasedCount = target === "wasm32" ? erased.exports["haxeon.memory.allocation_count"] : erased.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = erasedCount(), result = erased.exports["BoundaryClosureCensus.perform"](n), allocations = erasedCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`erased closure census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: erased closure census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const identityBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-scalar-closure-identity-census-inline-${inline}.wasm`));
	  const signatureBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-closure-signature-census-inline-${inline}.wasm`));
	  const signature = (await WebAssembly.instantiate(signatureBytes, {haxeon_runtime: runtime, std})).instance;
	  signature.exports["ClosureSignatureCensus.prepare"]();
	  const signatureCount = target === "wasm32" ? signature.exports["haxeon.memory.allocation_count"] : signature.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = signatureCount(), result = signature.exports["ClosureSignatureCensus.perform"](n), allocations = signatureCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`closure signature census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: closure signature census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const identity = (await WebAssembly.instantiate(identityBytes, {haxeon_runtime: runtime, std})).instance;
	  identity.exports["ScalarClosureIdentityCensus.prepare"]();
	  const identityCount = target === "wasm32" ? identity.exports["haxeon.memory.allocation_count"] : identity.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = identityCount(), result = identity.exports["ScalarClosureIdentityCensus.perform"](n), allocations = identityCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`scalar closure identity census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: scalar closure identity census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const scalarMapBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-scalar-map-census-inline-${inline}.wasm`));
	  const scalarMap = (await WebAssembly.instantiate(scalarMapBytes, {haxeon_runtime: runtime, std})).instance;
	  scalarMap.exports["ScalarMapCensus.prepare"]();
	  const scalarMapCount = target === "wasm32" ? scalarMap.exports["haxeon.memory.allocation_count"] : scalarMap.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = scalarMapCount(), result = scalarMap.exports["ScalarMapCensus.perform"](n), allocations = scalarMapCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`scalar map census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: scalar map census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const floatHashBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-float-hash-census-inline-${inline}.wasm`));
	  const floatHash = (await WebAssembly.instantiate(floatHashBytes, {haxeon_runtime: runtime, std})).instance;
	  floatHash.exports["FloatHashCensus.prepare"]();
	  const floatHashCount = target === "wasm32" ? floatHash.exports["haxeon.memory.allocation_count"] : floatHash.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = floatHashCount(), result = floatHash.exports["FloatHashCensus.perform"](n), allocations = floatHashCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`Float hash census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: Float hash census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const enumEscapeBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-enum-escape-census-inline-${inline}.wasm`));
	  const enumEscape = (await WebAssembly.instantiate(enumEscapeBytes, {haxeon_runtime: runtime, std})).instance;
	  enumEscape.exports["EnumEscapeCensus.prepare"]();
	  enumEscape.exports["EnumEscapeCensus.perform"](1);
	  const enumEscapeCount = target === "wasm32" ? enumEscape.exports["haxeon.memory.allocation_count"] : enumEscape.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = enumEscapeCount(), result = enumEscape.exports["EnumEscapeCensus.perform"](n), allocations = enumEscapeCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`enum dynamic escape census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: enum dynamic escape census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const valueEqualityBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-value-equality-census-inline-${inline}.wasm`));
	  const valueEquality = (await WebAssembly.instantiate(valueEqualityBytes, {haxeon_runtime: runtime, std})).instance;
	  valueEquality.exports["DynamicArrayEqualityCensus.prepare"]();
	  valueEquality.exports["DynamicArrayEqualityCensus.perform"](1);
	  const valueEqualityCount = target === "wasm32" ? valueEquality.exports["haxeon.memory.allocation_count"] : valueEquality.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = valueEqualityCount(), result = valueEquality.exports["DynamicArrayEqualityCensus.perform"](n), allocations = valueEqualityCount() - before;
	    if (result !== 5 * n || allocations !== 0)
	      failures.push(`struct dynamic equality census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: struct dynamic equality census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const iteratorBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-iterator-census-inline-${inline}.wasm`));
	  const iterator = (await WebAssembly.instantiate(iteratorBytes, {haxeon_runtime: runtime, std})).instance;
	  const iteratorCount = target === "wasm32" ? iterator.exports["haxeon.memory.allocation_count"] : iterator.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    iterator.exports["IteratorCensus.prepare"](n);
	    const before = iteratorCount(), result = iterator.exports["IteratorCensus.perform"](), allocations = iteratorCount() - before;
	    if (result !== n * (n - 1) / 2 || allocations !== 0)
	      failures.push(`struct iterator census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: struct iterator census on ${target}, inline=${inline}, n=${n}`);
	  }
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
	  const pathBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-key-path-census-inline-${inline}.wasm`));
	  const paths = (await WebAssembly.instantiate(pathBytes, {haxeon_runtime: runtime, std})).instance.exports;
	  paths["KeyPathCensus.prepare"]();
	  const pathCount = target === "wasm32" ? paths["haxeon.memory.allocation_count"] : paths.__allocation_count;
	  for (const mode of ["known", "knownComposition", "escapedClass", "escapedStruct", "escapedStructValue", "escapedStaticStruct", "escapedComposition"]) for (const n of [8, 1024]) {
	    const before = pathCount(), result = paths[`KeyPathCensus.${mode}`](n), allocations = pathCount() - before;
	    const expected = mode === "known" ? n * (n - 1) : n * (n - 1) / 2;
	    if (result !== expected || allocations !== 0)
	      failures.push(`key path ${mode} census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: key path ${mode} census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const semanticsBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-key-path-semantics-inline-${inline}.wasm`));
	  const semantics = (await WebAssembly.instantiate(semanticsBytes, {haxeon_runtime: runtime, std})).instance.exports;
	  const semanticsResult = semantics.main();
	  if (semanticsResult !== 42) failures.push(`key path semantics (${target}, inline=${inline}): result=${semanticsResult}`);
	  else console.log(`PASS: key path semantics on ${target}, inline=${inline}`);
	  const pointerAddress = semantics.memory.buffer.byteLength;
	  semantics.memory.grow(1);
	  const pointerResult = semantics["SpecPointers.foreign"](pointerAddress);
	  if (pointerResult !== 42) failures.push(`key path native place (${target}, inline=${inline}): result=${pointerResult}`);
	  else console.log(`PASS: key path native place on ${target}, inline=${inline}`);
	  semantics["SpecNullReads.prepare"]();
	  const outcome = operation => {
	    try { return JSON.stringify({value: operation()}); }
	    catch (error) { return JSON.stringify({error: error.constructor.name, message: error.message}); }
	  };
	  const directNullRead = outcome(semantics["SpecNullReads.direct"]);
	  for (const mode of ["known", "escaped"]) {
	    const actual = outcome(semantics[`SpecNullReads.${mode}`]);
	    if (actual !== directNullRead) failures.push(`key path ${mode} null read (${target}, inline=${inline}): ${actual} != ${directNullRead}`);
	    else console.log(`PASS: key path ${mode} null read matches direct access on ${target}, inline=${inline}`);
	  }
	  const placeBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-observable-place-census-inline-${inline}.wasm`));
	  const place = (await WebAssembly.instantiate(placeBytes, {haxeon_runtime: runtime, std})).instance;
	  place.exports["ObservablePlaceCensus.prepare"]();
	  const placeCount = target === "wasm32" ? place.exports["haxeon.memory.allocation_count"] : place.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = placeCount(), result = place.exports["ObservablePlaceCensus.perform"](n), allocations = placeCount() - before;
	    if (result !== n * (n - 1) / 2 || allocations !== 0)
	      failures.push(`observable struct assignment census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: observable struct assignment census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const effectBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-effect-census-inline-${inline}.wasm`));
	  const effect = (await WebAssembly.instantiate(effectBytes, {haxeon_runtime: runtime, std})).instance;
	  effect.exports["EffectAllocationCensus.prepare"]();
	  const effectCount = target === "wasm32" ? effect.exports["haxeon.memory.allocation_count"] : effect.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = effectCount(), result = effect.exports["EffectAllocationCensus.perform"](n), allocations = effectCount() - before;
	    if (result !== n * (n + 1) / 2 + n || allocations !== 0)
	      failures.push(`observable effect census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: observable effect census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const deferBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-defer-census-inline-${inline}.wasm`));
	  const deferred = (await WebAssembly.instantiate(deferBytes, {haxeon_runtime: runtime, std})).instance;
	  deferred.exports.main();
	  const deferCount = target === "wasm32" ? deferred.exports["haxeon.memory.allocation_count"] : deferred.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = deferCount(), result = deferred.exports["DeferCensus.perform"](n), allocations = deferCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`defer census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: defer census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const scopedBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-scoped-census-inline-${inline}.wasm`));
	  const scoped = (await WebAssembly.instantiate(scopedBytes, {haxeon_runtime: runtime, std})).instance;
	  scoped.exports.main();
	  scoped.exports["ScopedCensus.prepare"]();
	  scoped.exports["ScopedCensus.prepareComposite"]();
	  const scopedCount = target === "wasm32" ? scoped.exports["haxeon.memory.allocation_count"] : scoped.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = scopedCount(), result = scoped.exports["ScopedCensus.perform"](n), allocations = scopedCount() - before;
	    if (result !== n / 2 || allocations !== 0)
	      failures.push(`scoped census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: scoped census on ${target}, inline=${inline}, n=${n}`);
	    const valueBefore = scopedCount(), valueResult = scoped.exports["ScopedCensus.performValue"](n), valueAllocations = scopedCount() - valueBefore;
	    if (valueResult !== n || valueAllocations !== 0)
	      failures.push(`scoped value census (${target}, inline=${inline}, n=${n}): result=${valueResult}, allocations=${valueAllocations}`);
	    else console.log(`PASS: scoped value census on ${target}, inline=${inline}, n=${n}`);
	    const nullableBefore = scopedCount(), nullableResult = scoped.exports["ScopedCensus.performNullableValue"](n), nullableAllocations = scopedCount() - nullableBefore;
	    if (nullableResult !== n / 2 || nullableAllocations !== 0)
	      failures.push(`scoped nullable value census (${target}, inline=${inline}, n=${n}): result=${nullableResult}, allocations=${nullableAllocations}`);
	    else console.log(`PASS: scoped nullable value census on ${target}, inline=${inline}, n=${n}`);
	    for (const [name, expected] of [["performMutableValue", n], ["performNullableMutableValue", n / 2], ["performComposite", n * 3]]) {
	      const before = scopedCount(), result = scoped.exports[`ScopedCensus.${name}`](n), allocations = scopedCount() - before;
	      if (result !== expected || allocations !== 0)
	        failures.push(`scoped ${name} census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	      else console.log(`PASS: scoped ${name} census on ${target}, inline=${inline}, n=${n}`);
	    }
	  }
	  const captureBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-reactive-capture-census-inline-${inline}.wasm`));
	  const capture = (await WebAssembly.instantiate(captureBytes, {haxeon_runtime: runtime, std})).instance;
	  capture.exports["ReactiveCaptureCensus.prepare"]();
	  const captureCount = target === "wasm32" ? capture.exports["haxeon.memory.allocation_count"] : capture.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = captureCount(), result = capture.exports["ReactiveCaptureCensus.perform"](n), allocations = captureCount() - before;
	    if (result !== n * 2 || allocations !== 0)
	      failures.push(`reactive capture census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: reactive capture census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const scaleBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-reactive-scale-census-inline-${inline}.wasm`));
	  const scale = (await WebAssembly.instantiate(scaleBytes, {haxeon_runtime: runtime, std})).instance;
	  scale.exports["ReactiveScaleCensus.prepare"]();
	  const scaleCount = target === "wasm32" ? scale.exports["haxeon.memory.allocation_count"] : scale.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = scaleCount(), result = scale.exports["ReactiveScaleCensus.perform"](n), allocations = scaleCount() - before;
	    if (result !== n * 2048 || allocations !== 0)
	      failures.push(`reactive scale census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: reactive scale census on ${target}, inline=${inline}, n=${n}`);
	    const effectBefore = scaleCount(), effectResult = scale.exports["ReactiveScaleCensus.performEffect"](n), effectAllocations = scaleCount() - effectBefore;
	    if (effectResult !== n || effectAllocations !== 0)
	      failures.push(`reactive scale effect census (${target}, inline=${inline}, n=${n}): result=${effectResult}, allocations=${effectAllocations}`);
	    else console.log(`PASS: reactive scale effect census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const identityClassBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-identity-class-census-inline-${inline}.wasm`));
	  const identityClass = (await WebAssembly.instantiate(identityClassBytes, {haxeon_runtime: runtime, std})).instance;
	  identityClass.exports["IdentityClassCensus.prepare"]();
	  const identityClassCount = target === "wasm32" ? identityClass.exports["haxeon.memory.allocation_count"] : identityClass.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    const before = identityClassCount(), result = identityClass.exports["IdentityClassCensus.perform"](n), allocations = identityClassCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`class identity census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: class identity census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const laneBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-lane-policy-census-inline-${inline}.wasm`));
	  const lane = (await WebAssembly.instantiate(laneBytes, {haxeon_runtime: runtime, std})).instance;
	  const laneCount = target === "wasm32" ? lane.exports["haxeon.memory.allocation_count"] : lane.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    lane.exports["LanePolicyCensus.prepare"](n);
	    const before = laneCount(), result = lane.exports["LanePolicyCensus.perform"](), allocations = laneCount() - before;
	    if (result !== n || allocations !== 0)
	      failures.push(`lane policy census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: lane policy census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const wordBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-word-access-census-inline-${inline}.wasm`));
	  const word = (await WebAssembly.instantiate(wordBytes, {haxeon_runtime: runtime, std})).instance;
	  const wordCount = target === "wasm32" ? word.exports["haxeon.memory.allocation_count"] : word.exports.__allocation_count;
	  for (const n of [8, 1024]) {
	    word.exports["ArrayWordBench.prepare"](n);
	    const before = wordCount(), result = word.exports["ArrayWordBench.perform"](), allocations = wordCount() - before;
	    if (result !== 42 || allocations !== 0)
	      failures.push(`word access census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: word access census on ${target}, inline=${inline}, n=${n}`);
	  }
	  const scopeBytes = fs.readFileSync(path.join(outputDir, `wasm-parity-${target}-scope-creation-census-inline-${inline}.wasm`));
	  const scope = (await WebAssembly.instantiate(scopeBytes, {haxeon_runtime: runtime, std})).instance;
	  scope.exports["ScopeCreationCensus.prepare"]();
	  const scopeCount = target === "wasm32" ? scope.exports["haxeon.memory.allocation_count"] : scope.exports.__allocation_count;
	  let scopeRuns = 1;
	  for (const n of [8, 1024]) {
	    const before = scopeCount(), result = scope.exports["ScopeCreationCensus.perform"](n), allocations = scopeCount() - before;
	    scopeRuns += n;
	    if (result !== scopeRuns || allocations !== n)
	      failures.push(`scope creation census (${target}, inline=${inline}, n=${n}): result=${result}, allocations=${allocations}`);
	    else console.log(`PASS: scope creation census on ${target}, inline=${inline}, n=${n}`);
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
  console.log(`PASS: ${cases.length - skipped} Haxe fixtures checked across Wasm32, Wasm GC and HL (${skipped} skipped)`);
})().catch(error => {
  console.error(error.message ?? error);
  process.exitCode = 1;
});
JS

# This UI graph reaches higher-order closure adapters that the Showcase does not.
# Run all three targets, with and without inlining, as part of every Wasm parity gate.
bash "$root_dir/packages/ui/tools/test-value-snapshot-parity.sh"
