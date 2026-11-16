package compiler.ir;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrStage.IrAssemblyStage;
import compiler.ir.IrStage.IrAssemblyStageList;
import compiler.ir.IrStage.IrStageList;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;

/**
 * The order of the whole-program IR passes, for every target, in one place.
 *
 * A build runs two lists. `assembly` runs inside `IrProgramAssembler.assemble`, from the generated functions and the declaration
 * tables to the finished program. The frontend then records its positional and live metadata on that program
 * (`FrontendCompilation.run`) and runs `target`, which ends with the inliner and the frontend verifier. The backend session then
 * builds the artifact from that program (`BackendSession`).
 *
 * Target differences are which stages a target enables (the predicates below, read from `IrPipelineContext`); each stage wraps an
 * existing pass as it is. The Wasm backend's own passes before its module builder are its stage lists (`WasmBackend.logical`,
 * `WasmBackend.erased`); the module builders still run the rest interleaved with the module they build
 * (`WasmScalarClosureEscapes`, `WasmLinearModuleBuilder`, `WasmGcModuleBuilder`).
 *
 * To add a pass: write it as a function of the program (and the context, for what it reads besides the program), wrap it in a stage
 * at its place in the list, with `when` for the targets that run it, `measured` for its line in the pass allocation report and
 * `checksPrune` when the early prune's check mode must hold after it.
 */
class IrPipeline {
	/** From the generated functions to the finished program (`IrProgramAssembler.assemble`). */
	public static final assembly:IrAssemblyStageList = new IrAssemblyStageList("assembly", [
		new IrAssemblyStage("constant-branches", constantBranches),
		new IrAssemblyStage("dispatch-walk", dispatchWalk).when(pruning),
		new IrAssemblyStage("enum-dynamic-dispatch-input", enumDynamicDispatchInput).when(hasObjects),
		new IrAssemblyStage("enum-dynamic-dispatch", enumDynamicDispatch).when(hasObjects).measured(),
		new IrAssemblyStage("reachability-report", reachabilityReport).when(reportsReachability),
		new IrAssemblyStage("value-dynamic-dispatch", valueDynamicDispatch).when(hasObjects).measured(),
		new IrAssemblyStage("generic-owner-erasure", genericOwnerErasure).when(hasObjects).measured(),
		new IrAssemblyStage("override-bridges", overrideBridges).when(hasObjects).measured(),
		new IrAssemblyStage("entry-prune", entryPrune).when(pruning).prunes(),
		new IrAssemblyStage("value-interface-boxes", valueInterfaceBoxes).when(hasInterfaces).measured().checksPrune(),
		new IrAssemblyStage("typed-interface-calls", typedInterfaceCalls).when(hasInterfaces).measured(),
		new IrAssemblyStage("typed-interface-generate", typedInterfaceGenerate).when(hasInterfaces).measured(),
		new IrAssemblyStage("typed-interface-boxes", typedInterfaceBoxes).when(hasInterfaces),
		new IrAssemblyStage("checked-dynamic-casts", checkedDynamicCasts).when(hasObjects).measured().checksPrune(),
		new IrAssemblyStage("exported-functions", exportedFunctions).when(exportsFunctions),
		new IrAssemblyStage("enum-specializations", enumSpecializations).when(lowersEnums),
		new IrAssemblyStage("enum-tag-lowering", enumTagLowering).when(lowersEnums),
		new IrAssemblyStage("inline-enum-lowering", inlineEnums).when(lowersEnums).measured().checksPrune(),
		new IrAssemblyStage("optional-scalar-flow", optionalScalarFlow).when(hasObjects).measured(),
		new IrAssemblyStage("optional-value-helpers", optionalHelpers).when(hasObjects).checksPrune(OPTIONAL),
		new IrAssemblyStage("static-null-checks", staticNullChecks).measured().checksPrune(),
		new IrAssemblyStage("reflectable-objects", reflectableObjects).when(hasReflectable),
		new IrAssemblyStage("object-reflection", objectReflection),
		new IrAssemblyStage("reflection-casts", reflectionCasts).when(hasObjects),
		new IrAssemblyStage("optional-field-storage", optionalFieldStorage).when(hasObjects),
		new IrAssemblyStage("nullable-scalar-fields", nullFields).when(hasObjects).measured().checksPrune(REFLECTION),
		new IrAssemblyStage("runtime-surface", runtimeSurface),
		new IrAssemblyStage("enum-tag-escapes", assemblyEnumTagEscapes)
	]);

	/**
	 * From the assembled program to the program the backends lower (`FrontendCompilation.run`). A plain HashLink build runs every stage
	 * but the Wasm ones (`closed-enum-tag-abi` only in release mode); a live HashLink build also skips the closed tag ABI and the
	 * verifier, which `HlLower` runs instead. Wasm32 and Wasm GC run the Wasm stages in place of the HashLink ones and verify in their
	 * module builders.
	 */
	public static final target:IrStageList = new IrStageList("target", [
		new IrStage("closed-enum-tag-abi", closedEnumTagAbi).when(closesEnumTags),
		new IrStage("value-array-rewrite", valueArrayRewrite).measured(),
		new IrStage("value-constructors", valueConstructors).when(wasm),
		new IrStage("value-phi-scalarization", valuePhiScalarization).when(wasm),
		new IrStage("scalar-arguments", scalarArgumentsOnly).when(wasmValueLanes),
		new IrStage("value-phi-scalarization", valuePhiScalarization).when(wasmValueLanes),
		new IrStage("value-constructors", valueConstructors).when(hashLink).measured(),
		new IrStage("value-phi-scalarization", valuePhiScalarization).when(hashLink).measured(),
		new IrStage("scalar-arguments", scalarArguments).when(hashLink).measured(),
		new IrStage("scalar-closures", scalarClosures).when(hashLink).measured(),
		new IrStage("value-phi-scalarization", valuePhiScalarization).when(hashLink).measured(),
		new IrStage("scalar-replacement-objects", scalarReplacementObjects),
		new IrStage("scalar-replacement", scalarReplacement).measured(),
		new IrStage("nullable-scalar-flow", nullableScalarFlow).measured(),
		new IrStage("enum-tag-escapes", enumTagEscapes),
		new IrStage("inliner", inliner).measured(),
		new IrStage("verifier", verifier).when(verifiesHere).measured(),
		new IrStage("verifier-check", verifierCheck).when(checksVerification)
	]);

	/** The names the prune check of a stage reports when it covers more than the stage. */
	static inline final OPTIONAL = "optional-scalar-flow";

	static inline final REFLECTION = "object-reflection and nullable-scalar-fields";

	// Predicates.

	static function pruning(assembly:IrAssembly, context:IrPipelineContext):Bool
		return context.pruneFromEntry && assembly.objects != null;

	static function hasObjects(assembly:IrAssembly, context:IrPipelineContext):Bool
		return assembly.objects != null;

	static function hasInterfaces(assembly:IrAssembly, context:IrPipelineContext):Bool
		return assembly.objects != null && assembly.interfaces != null;

	static function hasReflectable(assembly:IrAssembly, context:IrPipelineContext):Bool
		return assembly.objects != null && assembly.reflectableObjects != null;

	static function reportsReachability(assembly:IrAssembly, context:IrPipelineContext):Bool
		return assembly.objects != null && IrReachabilityReport.enabled();

	static function exportsFunctions(assembly:IrAssembly, context:IrPipelineContext):Bool {
		var exported = context.exportedFunctions;
		return exported != null && exported.length > 0;
	}

	static function lowersEnums(assembly:IrAssembly, context:IrPipelineContext):Bool
		return context.laneTarget != null;

	static function closesEnumTags(program:IrProgram, context:IrPipelineContext):Bool
		return !context.developmentMetadata && !context.livePatching;

	static function wasm(program:IrProgram, context:IrPipelineContext):Bool
		return context.isWasm();

	static function hashLink(program:IrProgram, context:IrPipelineContext):Bool
		return !context.isWasm();

	static function wasmValueLanes(program:IrProgram, context:IrPipelineContext):Bool
		return context.isWasm()
			&& (context.laneTarget == IrValueLaneTarget.Wasm32 || context.laneTarget == IrValueLaneTarget.WasmGc);

	static function verifiesHere(program:IrProgram, context:IrPipelineContext):Bool
		return !context.livePatching && !context.isWasm();

	static function checksVerification(program:IrProgram, context:IrPipelineContext):Bool
		return !context.livePatching && !context.isWasm() && context.options.checkReuse;

	// Assembly stages.

	/** Before anything walks the program, so a branch that cannot be taken links nothing it calls. */
	static function constantBranches(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		IrConstantBranches.run(assembly.functions);
		return assembly;
	}

	/** What the prune walks: the program as it stands, with `functions`. */
	static function pruneInputOf(assembly:IrAssembly, context:IrPipelineContext,
			functions:Array<IrFunction>):IrProgram {
		var entryPoint = context.entryPoint,
			interfaces = assembly.interfaces,
			enums = assembly.enums,
			staticFields = assembly.staticFields,
			natives = assembly.natives,
			cNatives = assembly.cNatives;
		var input = new IrProgram(entryPoint == null ? "main" : entryPoint);
		input.objects = assembly.objects;
		input.interfaces = interfaces == null ? [] : interfaces;
		input.enums = enums == null ? [] : enums;
		input.staticFields = staticFields == null ? [] : staticFields;
		input.functions = functions;
		input.natives = natives == null ? [] : natives;
		input.cNatives = cNatives == null ? [] : cNatives;
		return input;
	}

	/**
	 * What a plain build's prune keeps (docs/design/REACHABILITY_WALK.md): the roots are the entry function, the initializers `__init` runs and
	 * the exported functions; the reflection helpers are generated after the walk, so what they will call is reached through these
	 * dependencies.
	 */
	static function pruneDependencies(assembly:IrAssembly,
			functions:Array<IrFunction>):compiler.ir.IrTypeAwareWalk.IrClassDependencies {
		var objectTable:Map<String, IrObject> = [for (object in assembly.objects) object.name => object],
			present:Map<String, Bool> = [for (fn in functions) fn.name => true],
			facts = assembly.generator.facts;
		return {
			symbols: ObjectReflection.helperSymbols(),
			of: (className, symbol) -> ObjectReflection.dependencies(objectTable, facts.observableFieldBits, className,
				symbol,
				name -> present.exists(name))
		};
	}

	/**
	 * A plain build decides the Dynamic dispatch of enums and structs from what is reached: an enum or struct that no reached code can
	 * have, and a helper that only unreached code asked for, change nothing (the dispatches rewrite every `__dynamic_equal` site once
	 * any type registers).
	 */
	static function dispatchWalk(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var functions = assembly.functions;
		var walk = IrEntryPrune.walk(pruneInputOf(assembly, context, functions), context.pruneRoots,
			pruneDependencies(assembly, functions));
		assembly.dispatchWalk = walk;
		assembly.unreached = [for (fn in functions) if (!walk.reached.exists(fn.name)) fn.name => true];
		return assembly;
	}

	static function enumDynamicDispatchInput(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var entryPoint = context.entryPoint,
			interfaces = assembly.interfaces,
			enums = assembly.enums,
			staticFields = assembly.staticFields,
			natives = assembly.natives,
			cNatives = assembly.cNatives;
		var reflectionInput = new IrProgram(entryPoint == null ? "main" : entryPoint);
		reflectionInput.objects = assembly.objects;
		reflectionInput.interfaces = interfaces == null ? [] : interfaces;
		reflectionInput.enums = enums == null ? [] : enums;
		reflectionInput.staticFields = staticFields == null ? [] : staticFields;
		reflectionInput.functions = assembly.functions;
		reflectionInput.natives = natives == null ? [] : natives;
		reflectionInput.cNatives = cNatives == null ? [] : cNatives;
		// The reflection decisions of the enum dispatch read what reached code does, not what every loaded module declares.
		var walk = assembly.dispatchWalk;
		if (walk != null) {
			reflectionInput.functions = [for (fn in assembly.functions) if (walk.reached.exists(fn.name)) fn];
			reflectionInput.natives =
				[for (native in reflectionInput.natives) if (walk.calledNatives.exists(native.name)) native];
			reflectionInput.cNatives =
				[for (native in reflectionInput.cNatives) if (walk.calledNatives.exists(native.name)) native];
		}
		assembly.reflectionInput = reflectionInput;
		return assembly;
	}

	static function enumDynamicDispatch(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.functions = IrEnumDynamicDispatch.rewrite(assembly.functions, assembly.reflectionInput,
			assembly.reflectableObjects, assembly.unreached);
		return assembly;
	}

	static function reachabilityReport(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var reflectionInput = assembly.reflectionInput;
		if (reflectionInput == null)
			throw "The reachability report needs the enum dispatch input";
		reflectionInput.functions = assembly.functions;
		IrReachabilityReport.report("after enum dispatch (the 3a prune point)", reflectionInput);
		return assembly;
	}

	static function valueDynamicDispatch(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var walk = assembly.dispatchWalk;
		assembly.functions = IrValueDynamicDispatch.rewrite(assembly.functions, assembly.objects, assembly.unreached,
			walk == null ? null : walk.createdClasses);
		return assembly;
	}

	static function genericOwnerErasure(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		GenericOwnerErasure.generate(assembly.generator.facts, assembly.functions, assembly.objects);
		return assembly;
	}

	/** Every method slot keeps its topmost declaration's signature; overrides that lower to another get a bridge in the slot. */
	static function overrideBridges(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var bridged = IrOverrideBridges.apply(assembly.functions, assembly.objects);
		assembly.functions = bridged.functions;
		assembly.objects = bridged.objects;
		return assembly;
	}

	/**
	 * The prune point (docs/design/REACHABILITY_WALK.md): after the enum providers and generic owner erasure, which settle the class names and the
	 * helpers, and before every later pass. The entry function is created last, so the roots are what it calls: main, and the
	 * initializers `__init` runs. With `--check-reuse`, after each later stage that checks the prune nothing may call a function it
	 * removed (the failure of 2026-11-10).
	 */
	static function entryPrune(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var functions = assembly.functions;
		var pruneInput = pruneInputOf(assembly, context, functions);
		var pruned = IrEntryPrune.run(pruneInput, context.pruneRoots, pruneDependencies(assembly, functions));
		context.pruned = pruned.removed;
		assembly.reachedNatives = pruned.calledNatives;
		assembly.functions = pruneInput.functions;
		assembly.objects = pruneInput.objects;
		return assembly;
	}

	static function valueInterfaceBoxes(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.functions = IrValueInterfaceBoxes.rewrite(assembly.functions, assembly.objects, assembly.interfaces);
		return assembly;
	}

	static function typedInterfaceCalls(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.functions = IrTypedInterfaceDispatch.rewriteValueCalls(assembly.functions, assembly.objects,
			assembly.interfaces);
		assembly.generatedStart = assembly.functions.length;
		return assembly;
	}

	static function typedInterfaceGenerate(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		IrTypedInterfaceDispatch.generate(assembly.functions, assembly.objects, assembly.interfaces);
		return assembly;
	}

	static function typedInterfaceBoxes(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var functions = assembly.functions, start = assembly.generatedStart;
		if (functions.length > start) {
			var existing = functions.slice(0, start);
			assembly.functions = existing.concat(IrValueInterfaceBoxes.rewrite(functions.slice(start), assembly.objects,
				assembly.interfaces, existing));
		}
		return assembly;
	}

	/** HashLink checks object casts itself, but interface casts need checks on every target. */
	static function checkedDynamicCasts(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.functions = IrCheckedDynamicCasts.rewrite(assembly.functions, assembly.objects,
			assembly.generator.profile.nativeReflectionDispatch);
		return assembly;
	}

	static function exportedFunctions(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var names = context.exportedFunctions;
		var exported = [for (name in names) name => true];
		assembly.functions = [
			for (fn in assembly.functions)
				exported.exists(fn.name) ? new IrFunction(fn.name, fn.arguments, fn.result, fn.blocks, fn.kind,
				fn.debugBindings,
				fn.inlineHint, Expose) : fn
		];
		return assembly;
	}

	/** Choose source enum storage before optional-flow and reflection helpers choose their ABI. */
	static function enumSpecializations(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		if (context.canonicalObjects == null)
			throw "Inline enum lowering requires canonical objects";
		var entryPoint = context.entryPoint,
			objects = assembly.objects,
			interfaces = assembly.interfaces,
			enums = assembly.enums,
			staticFields = assembly.staticFields,
			natives = assembly.natives,
			cNatives = assembly.cNatives;
		var enumInput = new IrProgram(entryPoint == null ? "main" : entryPoint);
		enumInput.functions = assembly.functions;
		enumInput.reachedNatives = assembly.reachedNatives;
		enumInput.objects = objects == null ? [] : objects;
		enumInput.interfaces = interfaces == null ? [] : interfaces;
		enumInput.staticFields = staticFields == null ? [] : staticFields;
		enumInput.natives = natives == null ? [] : natives;
		enumInput.cNatives = cNatives == null ? [] : cNatives;
		enumInput.enums = IrEnumRuntimeSpecializations.materialize(enums == null ? [] : enums, assembly.functions,
			enumInput.objects, enumInput.staticFields, enumInput.natives, enumInput.interfaces, enumInput.cNatives);
		assembly.enumInput = enumInput;
		return assembly;
	}

	static function enumTagLowering(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		IrEnumTagLowering.run(assembly.enumInput);
		return assembly;
	}

	static function inlineEnums(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var enumOutput = IrInlineEnumLowering.run(assembly.enumInput, context.laneTarget, context.canonicalObjects,
			assembly.reflectableObjects);
		assembly.functions = enumOutput.functions;
		assembly.objects = enumOutput.objects;
		assembly.interfaces = enumOutput.interfaces;
		assembly.staticFields = enumOutput.staticFields;
		assembly.natives = enumOutput.natives;
		assembly.enums = enumOutput.enums;
		return assembly;
	}

	static function optionalScalarFlow(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var objects = assembly.objects;
		assembly.functions = new IrOptionalScalarFlow(objects).rewrite(objects, assembly.functions);
		return assembly;
	}

	static function optionalHelpers(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.functions = IrOptionalValueFlow.addHelpers(assembly.functions, assembly.objects);
		return assembly;
	}

	static function staticNullChecks(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.functions = IrStaticNullChecks.run(assembly.functions, assembly.objects, context.staticChecks);
		return assembly;
	}

	/** Value objects, interface boxes and anonymous records are reflectable too, besides the classes the typed program lists. */
	static function reflectableObjects(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var reflectable = assembly.reflectableObjects.copy();
		var known:Map<String, Bool> = [for (name in reflectable) name => true];
		for (object in assembly.objects)
			if ((object.isValue
				|| StringTools.startsWith(object.name, IrValueInterfaceBoxes.BOX_PREFIX)
				|| compiler.semantic.SemanticSignature.isAnonymousName(object.name))
				&& !StringTools.startsWith(object.name, IrInlineEnumLayout.VALUE_PREFIX)
				&& !known.exists(object.name)) {
				reflectable.push(object.name);
				known.set(object.name, true);
			}
		assembly.reflectableObjects = reflectable;
		return assembly;
	}

	static function objectReflection(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.generatedStart = assembly.functions.length;
		var generator = assembly.generator;
		assembly.natives = ObjectReflection.generate(generator.facts, assembly.natives, assembly.objects,
			assembly.reflectableObjects, assembly.functions, generator.profile.nativeReflectionDispatch,
			assembly.reachedNatives, context.options.checkReuse);
		return assembly;
	}

	/**
	 * Reflection helpers are generated after the ordinary cast pass. Check their dynamic stores too, so a bad reflected value throws
	 * instead of trapping or corrupting a field.
	 */
	static function reflectionCasts(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var functions = assembly.functions, start = assembly.generatedStart;
		if (functions.length > start) {
			var existing = functions.slice(0, start);
			assembly.functions = existing.concat(IrCheckedDynamicCasts.rewrite(functions.slice(start), assembly.objects,
				assembly.generator.profile.nativeReflectionDispatch, existing, true, true));
		}
		return assembly;
	}

	static function optionalFieldStorage(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var optionalStorage = new IrOptionalFieldStorage(assembly.objects);
		if (optionalStorage.hasFields()) {
			assembly.functions = optionalStorage.rewrite(assembly.functions);
			assembly.objects = optionalStorage.physicalObjects(assembly.objects);
		}
		return assembly;
	}

	static function nullFields(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.functions = new IrNullableScalarFields(assembly.objects).rewrite(assembly.functions);
		return assembly;
	}

	static function runtimeSurface(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		assembly.program = IrProgramAssembler.finish(assembly, context);
		return assembly;
	}

	static function assemblyEnumTagEscapes(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		IrEnumTagLowering.escapes(assembly.program);
		return assembly;
	}

	// Target stages.

	static function closedEnumTagAbi(program:IrProgram, context:IrPipelineContext):IrProgram
		return IrClosedEnumTagAbi.run(program, context.reflectable);

	static function valueArrayRewrite(program:IrProgram, context:IrPipelineContext):IrProgram {
		var laneTarget = context.laneTarget;
		IrValueArrayProgramRewrite.rewriteAll(program, laneTarget == IrValueLaneTarget.HashLink ? 64 : 32, laneTarget);
		return program;
	}

	/**
	 * Value joins are scalarized before the scalar call ABI is chosen. The HashLink call rewrite can introduce further value joins, so
	 * HashLink runs `value-phi-scalarization` again after it.
	 */
	static function valueConstructors(program:IrProgram, context:IrPipelineContext):IrProgram {
		IrValueConstructors.rewrite(program);
		return program;
	}

	static function valuePhiScalarization(program:IrProgram, context:IrPipelineContext):IrProgram {
		IrValuePhiScalarization.rewrite(program);
		return program;
	}

	static function scalarArgumentsOnly(program:IrProgram, context:IrPipelineContext):IrProgram {
		IrScalarArguments.rewrite(program, true);
		return program;
	}

	static function scalarArguments(program:IrProgram, context:IrPipelineContext):IrProgram {
		IrScalarArguments.rewrite(program);
		return program;
	}

	static function scalarClosures(program:IrProgram, context:IrPipelineContext):IrProgram {
		IrScalarClosures.rewrite(program);
		return program;
	}

	static function scalarReplacementObjects(program:IrProgram, context:IrPipelineContext):IrProgram {
		context.scalarObjects = IrObjectTable.of([for (object in program.objects) object.name => object]);
		return program;
	}

	static function scalarReplacement(program:IrProgram, context:IrPipelineContext):IrProgram {
		var scalarObjects = context.scalarObjects, hashLink = !context.isWasm();
		program.functions = [
			for (fn in program.functions)
				IrScalarReplacement.rewrite(fn, scalarObjects, false, hashLink)
		];
		return program;
	}

	static function nullableScalarFlow(program:IrProgram, context:IrPipelineContext):IrProgram {
		IrNullableScalarFlow.rewrite(program);
		return program;
	}

	/** Also after the retained HashLink assembly's adapters, which can introduce fresh nominal-tag escapes. */
	static function enumTagEscapes(program:IrProgram, context:IrPipelineContext):IrProgram {
		IrEnumTagLowering.escapes(program);
		return program;
	}

	/** Runs also when only load/store forwarding is enabled: it compares and publishes the final IR. */
	static function inliner(program:IrProgram, context:IrPipelineContext):IrProgram {
		var cache = context.inlineCache;
		if (cache == null)
			throw "The inliner stage needs the session's inline cache";
		context.inlinerChanged = IrInliner.run(program, cache, context.profile, context.options,
			context.instrumentScope);
		return program;
	}

	/** HashLink has its scalar closure ABI here. Wasm verifies after its target-specific closure escape adapters exist. */
	static function verifier(program:IrProgram, context:IrPipelineContext):IrProgram {
		var memo = context.verifyMemo;
		if (memo == null)
			throw "The verifier stage needs the session's verify memo";
		IrVerifier.verifyReusing(program, memo);
		return program;
	}

	/** `--check-reuse`: the memoized verification accepted only what a full one accepts, and every provider call is declared. */
	static function verifierCheck(program:IrProgram, context:IrPipelineContext):IrProgram {
		try
			IrVerifier.verify(program)
		catch (error:String)
			throw '--check-reuse: verification skipped a function that fails in full: $error';
		var providerProblem = IrProviders.check(program.functions);
		if (providerProblem != null)
			throw '--check-reuse: $providerProblem';
		return program;
	}
}
