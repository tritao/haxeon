# ADR 0003 section 13, step 1: provider inventory (design only, no behavior change)

Source: branch `warm-rebuild-reuse` at a2e2ae45, read against ADR 0003 section 13 (commit 4101f3f6). Method: every generated-function name prefix
(`static inline final ... = "$..."`) and every place that recognizes one, then who generates it and which pass or call consumes it.

## Result in one paragraph

There is no provider table today. The knowledge "this generated function serves (type, operation)" exists in three forms: (1) the generated
name itself (prefix plus a type key, usually a hash of `SemanticSignature.type(T)`), (2) a hand-kept prefix list in the code that needs to know
whether a function is a helper, repeated in at least five places (`FrontendCompilation.generatedHelpersStillCalled`, `WasmScalarAbi` line 75,
`IrScalarArguments` lines 39-50 and 535, `IrOptionalScalarFlow` 270, plus `EnumEqualityGenerator.isEqualityName` and
`HashGenerator.isHashName`), and (3) dispatcher passes that rediscover their helpers by scanning `program.functions` for the prefix
(`IrValueDynamicDispatch`, `IrEnumDynamicDispatch`, `IrTypedInterfaceDispatch`). A reachability walk cannot use (1) or (2) without becoming the
fourth copy of the list, which is exactly what the section 13 decision rules out.

## Generators, by what the helper serves

Columns: generator (file), name form, serves (type, operation), consumer (who calls or discovers it), when it is generated.

### Typing time (`compiler.types.typing`, generated while typing a body or the program)

| Generator | Name | Serves (type, operation) | Consumer | Edge into the IR today |
| --- | --- | --- | --- | --- |
| `EnumEqualityGenerator` | `$enum-equals:<sha(T)>`, `$enum-reflect-equals:<sha(T)>` | (enum T, equality; reflective equality) | direct call from `==` in BodyTyper/CallResolver/DeclaredConformance; `IrEnumDynamicDispatch` scans by prefix and builds the dynamic dispatcher over all of them | direct call when `==` is typed on T; none for the dynamic path (the dispatcher is added later) |
| `EnumDynamicBox` | `$enum-dynamic-box:<T>`, `$enum-dynamic-view:<T>:<b64>` | (enum T, box to Dynamic; view as T) | `ConversionResolver` emits the call; `IrEnumDynamicDispatch` rewrites the box call into a dispatcher entry | direct call at the conversion |
| `EnumConformanceMethods` | `$enum-custom:<method>:<sha(T)>` | (enum T, user-declared conformance method: equals/hash/compare as declared) | called from `EnumEqualityGenerator` bodies | direct call from the generated equality |
| `HashGenerator` | `$hash$value$equality:<sha(T)>` | (value struct T, hash) | direct call from Map/Set key code in BodyTyper/CallResolver; kept alive by name in `generatedHelpersStillCalled` | direct call |
| `ValueEqualityGenerator` | `$value$equality:<sha(T)>` | (value struct T, equality) | direct call from `==`; `IrValueDynamicDispatch` scans for `$value$equality:` to build `$value-dynamic-equal` | direct call; none for the dynamic boundary (dispatcher added later) |
| `WireCodecGenerator` | `$wire:encode/decode/value-encode/value-decode:<T>`, `$wire:map-{int,string,enum}-compare[:..]`, `$json:encode/decode/value-*:<T>` | (T, wire/JSON encode; decode; map-key compare for the key type) | direct call from the codec call sites; nested codecs call each other | direct calls (including between codecs) |
| `KeyPathTyping` | `$keypath.<..>`, `$keypath.literal:<..>` | (root type, key path accessor) | direct call from the key-path expression | direct call |
| `GenericOwnerErasure` (also IR) | `$generic-erased:`, `$generic-type-test:`, `$generic-method-reference:` | (generic owner T, erased call; type test; method reference) | direct calls produced during erasure; `$generic:` bodies call them | direct call |
| `ConversionResolver` | `$iteration-adapter:<ctx>:<id>:<field>` | (iterable type, iteration protocol adapter) | direct call at the conversion | direct call |
| `LambdaName` | `$lambda:`, `$lambda-env:` | (closure) | closure value | closure edge, already walked |
| `ReceiverMutationInference` | `$receiver-readonly:<..>` | analysis marker on a method, not a helper | purity analysis | none |

### IR generation and IR passes (`compiler.ir`), introduced after typing

| Generator | Name | Serves (type, operation) | Consumer | Edge into the IR today |
| --- | --- | --- | --- | --- |
| `IrEnumDynamicDispatch` | `$enum-dynamic-unbox:<b64 T>`, type test, dispatcher; also prunes `$enum-reflect-equals:` helpers nothing reaches (line 104) | (enum T, dynamic test/unbox/equality over all boxed enums) | rewritten call sites | dispatcher references every helper it was built from: this is where the missing edge is (helper to dispatcher) |
| `IrValueDynamicDispatch` | `$value-dynamic-equal` dispatcher | (all value structs, dynamic equality) | `__dynamic_equal` calls rewritten to it | dispatcher references the `$value$equality:` helpers |
| `IrTypedInterfaceDispatch` | `$typed-interface:`, `$typed-interface-entry:` | (interface I method m, dispatch over implementors; adapter entry) | call sites of typed interface methods | dispatcher references implementor methods |
| `IrInlineEnumCaseAccess` | `$inline-enum:helper:<..>` | (inline enum T, construct/test/case access) | `IrInlineEnumLowering` call sites | direct call |
| `IrValueInterfaceBoxes` | `$value-interface-box:`, `$value-interface-unbox:` | (value type T, box as interface I; unbox) | conversion sites | direct call |
| `IrOptionalValueFlow` | `$optional-value:copy/box/unbox:` | (optional value T, copy; box; unbox) | rewritten sites | direct call |
| `IrOptionalFieldStorage` | `$optional-field:copy:`, `$optional-field:method:` | (class field of optional value type, copy; method wrapper) | rewritten sites | direct call |
| `IrOptionalScalarFlow` | `$optional-scalar:<fn>` clones, `$optional-components:` wrapper objects | (function f with optional scalar arguments, scalar-argument clone) | rewritten call sites | direct call to the clone |
| `IrNullableScalarFlow` | `$nullable-scalar:require/equal/arguments:` | (nullable scalar T, require; equality; argument clone) | rewritten sites | direct call |
| `IrScalarArguments` | `$scalar-arguments:<fn>` | (function f, scalar-argument ABI clone) | rewritten call sites and closures | direct call |
| `IrScalarClosures` | scalar closure entry points | (closure type, scalar entry) | closure creation | closure edge |
| `IrCheckedDynamicCasts` | `$checked-dynamic-cast:<T>` | (T, checked cast from Dynamic) | cast sites | direct call |
| `IrValueArrayElements`, `IrValueArraySlotHelpers`, `IrValueArrayPlaceMethods` | `$value-array:element:`, `:slot:`, `:method:` | (value array of T, element get/set; slot; place method) | rewritten sites | direct call |
| `IrValueLaneRuntime` | `$lane-runtime:<..>` | (lane-carried value, runtime helpers) | lowered ops | direct call |
| `IrReceiverCheck`, `IrReferenceIdentity` | `$receiver:check`, `$reference:same` | (any class, receiver null check; reference identity) | rewritten sites | direct call |

### Not generated functions, but type-dispatched all the same

| What | Where | Serves | Edge today |
| --- | --- | --- | --- |
| `toString` of a class | `IrReachability.withGeneratedRuntimeRoots`: once the `__std_string` native is used, every class's `__string` method is a root | (class T, dynamic stringification) | a root rule keyed by a native symbol, in the walker |
| Native-declared dependencies | `native.generatedFunctionDependencies` | (native n, functions its lowering calls) | declared on the native, followed by the walker (this is the right shape) |
| Reflection field access | `IrProgramAssembler.reflectableObjectsFrom`, `reflectable` table; `keepLiveClasses` rule in the walker (a mentioned class keeps all its methods) | (class T, field/method by name) | class-granular rule in the walker |
| Hash and compare for string/int keys | runtime natives (`hl_hash_*`) | none (natives) | none |
| Wasm-only helpers | `WasmScalarAbi` `$wasm:scalar-result:`, `WasmScalarClosureEscapes` `$wasm:closure-restore-call:`, `WasmDynamicCalls`, `WasmGcDynamicArrays`, `WasmFlattenValueFields` | backend-internal | made after the shared prune, so not subject to it |

## What the table must hold

A row is `(type key, operation) -> function name`, registered by the generator at the moment it creates the function, where the type key is the
same `SemanticSignature.type(T)` string the name hashes today. Operations needed to cover the inventory:

`equals`, `reflect-equals`, `custom-method(name)` (enum conformance), `hash`, `box-dynamic`, `view-dynamic`, `dynamic-test`, `dynamic-unbox`,
`wire-encode`, `wire-decode`, `json-encode`, `json-decode`, `map-key-compare`, `keypath`, `typed-interface-entry(I, method)`, `inline-enum-helper`,
`interface-box`, `interface-unbox`, `optional-copy`, `optional-box`, `optional-unbox`, `optional-field-copy`, `scalar-clone(f)`, `checked-cast`,
`value-array-element`, `value-array-slot`, `generic-type-test`, `iteration-adapter`.

Two of these are not "helper for T" but "clone of function f" (`scalar-clone`, optional-scalar, nullable-scalar arguments): they are keyed by the
original function and reached by the walk as ordinary call edges once the pass that creates them runs. They do not need a provider row; they need
the invariant of decision 4 (a pass may only introduce calls to reachable functions or functions it creates).

## Dispatchers: the (type, op) to "used at a dynamic site" edge

Three passes build a dispatcher over every helper of a family: `IrEnumDynamicDispatch` (equals, reflect-equals, box, view, unbox, type test),
`IrValueDynamicDispatch` (value equality at `__dynamic_equal`), `IrTypedInterfaceDispatch` (interface entries). Section 13 makes the dispatcher
reference only the providers whose type is created and whose operation is used at a reachable dynamic site. The "operation is used" signals today are:
a call to `__dynamic_equal` (value equality), a call whose name starts with `$enum-dynamic-box:`/`-view:` (enum box/view), the `__std_string`
native (toString), and for interfaces the typed-interface call sites. Each should become a use recorded by the code that emits the dynamic site,
not a prefix scan.

## Prefix lists to delete once the table exists

1. `FrontendCompilation.generatedHelpersStillCalled` (typing-time liveness of generated helpers): 7 prefixes.
2. `WasmScalarAbi` line 75: about 12 prefixes deciding which `$` functions take part in the scalar ABI.
3. `IrScalarArguments` lines 39-50 and 535.
4. `IrOptionalScalarFlow` line 270.
5. `EnumEqualityGenerator.isEqualityName`, `HashGenerator.isHashName`.
6. The prefix scans in `IrEnumDynamicDispatch` (lines 22, 104) and `IrValueDynamicDispatch`.
Some of these answer "is this a helper the pass must skip", which a provider row (function name to (type, op)) answers directly; others answer "which
functions does the dispatcher cover", which the table iterates by operation.

## Proposed first commit (no behavior change)

`IrProgram.providers: Map<(typeKey, operation), functionName>` plus `IrProgram.helperFunctions` (name to row), filled by the generators listed
under "Typing time" and "IR generation and passes" at creation, with a check-mode assertion that every function whose name starts with `$` is either
in the table, a clone/lambda/adapter, or listed as exempt. Nothing reads the table in this commit except the assertion, so output is byte-identical;
the assertion finds any generator this inventory missed. Persisting it: the table is part of the pipeline snapshot, and `generatedHelpersStillCalled`
already reads per-module typed functions, so the typing-time rows are stored in `ModuleState.typedFunctions` beside the function.
