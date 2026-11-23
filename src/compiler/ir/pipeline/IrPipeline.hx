package compiler.ir.pipeline;

import compiler.ir.passes.objects.IrTypedInterfaceDispatch.IrTypedInterfaceCalls;
import compiler.ir.model.IrFunction.IrRetention;
import compiler.ir.passes.enums.IrEnumTagLowering.IrEnumTagLoweringPass;
import compiler.ir.passes.enums.IrEnumTagLowering.IrTagEscapesPass;
import compiler.ir.passes.objects.IrGenericOwnerErasure;
import compiler.ir.passes.objects.IrCheckedDynamicCasts;
import compiler.ir.passes.enums.IrClosedEnumTagAbi;
import compiler.ir.passes.cleanup.IrConstantBranches;
import compiler.ir.analysis.IrEntryPrune;
import compiler.ir.passes.enums.IrEnumDynamicDispatch;
import compiler.ir.passes.enums.IrEnumRuntimeSpecializations;
import compiler.ir.model.IrFunction;
import compiler.ir.passes.enums.IrInlineEnumLayout;
import compiler.ir.passes.enums.IrInlineEnumLowering;
import compiler.ir.passes.inlining.IrInliner;
import compiler.ir.gen.IrMethodReferences;
import compiler.ir.passes.nullability.IrNullableScalarFields;
import compiler.ir.passes.nullability.IrNullableScalarFields.IrNullableScalarFieldsPass;
import compiler.ir.passes.nullability.IrNullableScalarFlow;
import compiler.ir.model.IrObjectTable;
import compiler.ir.passes.nullability.IrOptionalFieldStorage;
import compiler.ir.passes.nullability.IrOptionalScalarFlow;
import compiler.ir.passes.objects.IrOverrideBridges;
import compiler.ir.model.IrProviders;
import compiler.ir.analysis.IrReachability.IrReachabilityReport;
import compiler.ir.passes.scalars.IrScalarArguments;
import compiler.ir.passes.scalars.IrScalarClosures;
import compiler.ir.passes.scalars.IrScalarReplacement;
import compiler.ir.passes.nullability.IrStaticNullChecks;
import compiler.ir.model.IrTypeIds;
import compiler.ir.passes.objects.IrTypedInterfaceDispatch;
import compiler.ir.passes.arrays.IrValueArrayProgramRewrite;
import compiler.ir.passes.values.IrValueConstructors;
import compiler.ir.passes.values.IrValueObjectRows;
import compiler.ir.model.IrOpcode;
import compiler.ir.passes.values.IrValueDynamicDispatch;
import compiler.ir.passes.values.IrValueInterfaceBoxes;
import compiler.ir.passes.values.IrValuePhiScalarization;
import compiler.ir.verify.IrVerifier;
import compiler.ir.passes.objects.IrObjectReflection;
import compiler.core.InternalError;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.pipeline.IrStage.IrAssemblyStage;
import compiler.ir.pipeline.IrStage.IrAssemblyStageList;
import compiler.ir.pipeline.IrStage.IrStageList;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget;

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
 * at its place in the list, with `when` for the targets that run it and `checksPrune` when the early prune's check mode must hold after it.
 */
class IrPipeline {
	/** From the generated functions to the finished program (`IrProgramAssembler.assemble`). */
	public static final assembly:IrAssemblyStageList = new IrAssemblyStageList("assembly", [
		IrFunctionStages.stage("constant-branches", constantBranches),
		// Erased dispatch can reach a specialized body that the original callers do not name.
		// Expose those targets before the walk filters typed enum/value conversions.
		new IrAssemblyStage("generic-owner-erasure", genericOwnerErasure).when(hasObjects),
		new IrAssemblyStage("dispatch-walk", dispatchWalk).when(walking),
		new IrAssemblyStage("enum-dynamic-dispatch-input", enumDynamicDispatchInput).when(hasObjects),
		IrFunctionStages.stage("enum-dynamic-dispatch", enumDynamicDispatch).when(hasObjects),
		new IrAssemblyStage("reachability-report", reachabilityReport).when(reportsReachability),
		IrFunctionStages.stage("value-dynamic-dispatch", valueDynamicDispatch).when(hasObjects),
		IrFunctionStages.stage("override-bridges", overrideBridges, bridgedObjects).when(hasObjects),
		new IrAssemblyStage("entry-prune", entryPrune).when(pruning).prunes(),
		IrFunctionStages.stage("value-interface-boxes", valueInterfaceBoxes,
			addBoxObjects).when(hasInterfaces).checksPrune(),
		IrFunctionStages.stage("typed-interface-calls", typedInterfaceCalls, generatedFromHere).when(hasInterfaces),
		new IrAssemblyStage("typed-interface-generate", typedInterfaceGenerate).when(hasInterfaces),
		new IrAssemblyStage("typed-interface-boxes", typedInterfaceBoxes).when(hasInterfaces),
		IrFunctionStages.stage("checked-dynamic-casts", checkedDynamicCasts).when(hasObjects).checksPrune(),
		new IrAssemblyStage("exported-functions", exportedFunctions).when(exportsFunctions),
		new IrAssemblyStage("enum-specializations", enumSpecializations).when(lowersEnums),
		IrFunctionStages.stage("enum-tag-lowering", enumTagLowering, loweredEnumInput).when(lowersEnums),
		new IrAssemblyStage("encode-bodies", encodeBodies).encodes(),
		new IrAssemblyStage("inline-enum-lowering", inlineEnums).when(lowersEnums).checksPrune(),
		IrFunctionStages.stage("optional-scalar-flow", optionalScalarFlow).when(hasObjects).checksPrune(),
		new IrAssemblyStage("static-null-checks", staticNullChecks).checksPrune(),
		new IrAssemblyStage("reflectable-objects", reflectableObjects).when(hasReflectable),
		new IrAssemblyStage("object-reflection", objectReflection),
		new IrAssemblyStage("reflection-casts", reflectionCasts).when(hasObjects),
		new IrAssemblyStage("optional-field-storage", optionalFieldStorage).when(hasObjects),
		IrFunctionStages.stage("nullable-scalar-fields", nullFields).when(hasObjects).checksPrune(REFLECTION),
		new IrAssemblyStage("runtime-surface", runtimeSurface),
		IrFunctionStages.stage("enum-tag-escapes", assemblyEnumTagEscapes, escapedProgram)
	]);

	/**
	 * From the assembled program to the program the backends lower (`FrontendCompilation.run`). A plain HashLink build runs every stage
	 * but the Wasm ones (`closed-enum-tag-abi` only in release mode); a live HashLink build also skips the closed tag ABI and the
	 * verifier, which `HlLower` runs instead. Wasm32 and Wasm GC run the Wasm stages in place of the HashLink ones and verify in their
	 * module builders.
	 */
	public static final target:IrStageList = new IrStageList("target", [
		IrFunctionStages.programStage("closed-enum-tag-abi", closedEnumTagAbi,
			closedEnumTagProgram).when(closesEnumTags),
		new IrStage("value-array-rewrite", valueArrayRewrite),
		IrFunctionStages.programStage("value-constructors", valueConstructors).when(wasmValueLanes),
		IrFunctionStages.programStage("scalar-argument-joins", valuePhiScalarizationBodies).when(wasmValueLanes),
		IrFunctionStages.programStage("scalar-arguments", scalarArgumentsOnly).when(wasmValueLanes),
		IrFunctionStages.programStage("value-phi-scalarization", valuePhiScalarizationBodies).when(wasmValueLanes),
		IrFunctionStages.programStage("value-constructors", valueConstructors).when(wasmWithoutLanes),
		IrFunctionStages.programStage("value-phi-scalarization", valuePhiScalarizationBodies).when(wasmWithoutLanes),
		IrFunctionStages.programStage("value-constructors", valueConstructors).when(hashLink),
		IrFunctionStages.programStage("scalar-argument-joins", valuePhiScalarizationBodies).when(hashLink),
		IrFunctionStages.programStage("scalar-arguments", scalarArguments).when(hashLink),
		IrFunctionStages.programStage("scalar-closures", scalarClosures).when(hashLink),
		IrFunctionStages.programStage("value-phi-scalarization", valuePhiScalarizationBodies).when(hashLink),
		new IrStage("scalar-replacement-objects", scalarReplacementObjects),
		IrFunctionStages.programStage("scalar-replacement", scalarReplacement),
		IrFunctionStages.programStage("nullable-scalar-flow", nullableScalarFlow),
		IrFunctionStages.programStage("late-enum-tag-escapes", lateEnumTagEscapes),
		new IrStage("inliner", inliner),
		new IrStage("verifier", verifier).when(verifiesHere),
		new IrStage("verifier-check", verifierCheck).when(checksVerification)
	]);

	/** The names the prune check of a stage reports when it covers more than the stage. */
	static inline final REFLECTION = "object-reflection and nullable-scalar-fields";

	// Predicates.

	static function walking(assembly:IrAssembly, context:IrPipelineContext):Bool
		return context.walkFromEntry && assembly.objects != null;

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

	static function wasmWithoutLanes(program:IrProgram, context:IrPipelineContext):Bool
		return context.isWasm() && !wasmValueLanes(program, context);

	static function wasmValueLanes(program:IrProgram, context:IrPipelineContext):Bool
		return context.isWasm()
			&& (context.laneTarget == IrValueLaneTarget.Wasm32 || context.laneTarget == IrValueLaneTarget.WasmGc);

	static function verifiesHere(program:IrProgram, context:IrPipelineContext):Bool
		return !context.livePatching && !context.isWasm() && context.options.verifyIr;

	static function checksVerification(program:IrProgram, context:IrPipelineContext):Bool
		return !context.livePatching && !context.isWasm() && context.options.checkReuse;

	// Assembly stages.

	/** Before anything walks the program, so a branch that cannot be taken links nothing it calls. */
	static function constantBranches(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrConstantBranches();

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
			functions:Array<IrFunction>):compiler.ir.analysis.IrTypeAwareWalk.IrClassDependencies {
		var objectTable:Map<String, IrObject> = [for (object in assembly.objects) object.name => object],
			present:Map<String, Bool> = [for (fn in functions) fn.name => true],
			facts = assembly.generator.facts;
		return {
			symbols: IrObjectReflection.helperSymbols(),
			of: (className, symbol) -> IrObjectReflection.dependencies(objectTable, facts.observableFieldBits,
				className,
				symbol,
				name -> present.exists(name))
		};
	}

	/**
	 * A build that is not live decides whether it reflects over object layouts from the natives reached code calls, so a module that
	 * is loaded but unused (`Reflect`, which every program with a stdlib has) changes nothing. A pruned build also decides the Dynamic
	 * dispatch of enums and structs from what is reached: an enum or struct that no reached code can have, and a helper that only
	 * unreached code asked for, change nothing (the dispatches rewrite every `__dynamic_equal` site once any type registers). A build
	 * that keeps what it does not reach (Wasm, whose builders emit only what they reach) rewrites every function.
	 */
	static function dispatchWalk(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var functions = assembly.functions;
		var walk = IrEntryPrune.walk(pruneInputOf(assembly, context, functions), context.pruneRoots,
			pruneDependencies(assembly, functions), context.lineage);
		assembly.dispatchWalk = walk;
		assembly.reachedNatives = walk.calledNatives;
		if (context.pruneFromEntry)
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
		reflectionInput.reachedNatives = assembly.reachedNatives;
		var walk = assembly.dispatchWalk;
		if (walk != null && context.pruneFromEntry) {
			reflectionInput.functions = [for (fn in assembly.functions) if (walk.reached.exists(fn.name)) fn];
			reflectionInput.natives =
				[for (native in reflectionInput.natives) if (walk.calledNatives.exists(native.name)) native];
			reflectionInput.cNatives =
				[for (native in reflectionInput.cNatives) if (walk.calledNatives.exists(native.name)) native];
		}
		assembly.reflectionInput = reflectionInput;
		return assembly;
	}

	static function enumDynamicDispatch(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrEnumDynamicDispatch(assembly.reflectionInput, assembly.reflectableObjects, assembly.unreached,
			context.lineage);

	static function reachabilityReport(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var reflectionInput = assembly.reflectionInput;
		if (reflectionInput == null)
			throw new InternalError("The reachability report needs the enum dispatch input");
		reflectionInput.functions = assembly.functions;
		IrReachabilityReport.report("after enum dispatch (the 3a prune point)", reflectionInput);
		return assembly;
	}

	static function valueDynamicDispatch(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass {
		var walk = assembly.dispatchWalk;
		return new IrValueDynamicDispatch(assembly.objects, assembly.unreached,
			walk == null || !context.pruneFromEntry ? null : walk.createdClasses);
	}

	static function genericOwnerErasure(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		// Method values first: a bound method of an erased generic owner calls an erased operation, which erasure then makes.
		IrMethodReferences.generate(assembly.functions, assembly.objects, context.lineage);
		IrGenericOwnerErasure.generate(assembly.generator.facts, assembly.functions, assembly.objects, context.lineage);
		return assembly;
	}

	/** Every method slot keeps its topmost declaration's signature; overrides that lower to another get a bridge in the slot. */
	static function overrideBridges(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrOverrideBridges(assembly.objects);

	static function bridgedObjects(assembly:IrAssembly, pass:IrFunctionPass):Void
		assembly.objects = cast(pass, IrOverrideBridges).objects;

	/**
	 * The prune point (docs/design/REACHABILITY_WALK.md): after the enum providers and generic owner erasure, which settle the class names and the
	 * helpers, and before every later pass. The entry function is created last, so the roots are what it calls: main, and the
	 * initializers `__init` runs. With `--check-reuse`, after each later stage that checks the prune nothing may call a function it
	 * removed (the failure of 2026-11-10).
	 */
	static function entryPrune(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var functions = assembly.functions;
		var pruneInput = pruneInputOf(assembly, context, functions);
		var pruned = IrEntryPrune.run(pruneInput, context.pruneRoots, pruneDependencies(assembly, functions),
			context.lineage);
		context.pruned = pruned.removed;
		context.prunedMethods = pruned.removedMethods;
		assembly.reachedNatives = pruned.calledNatives;
		assembly.functions = pruneInput.functions;
		assembly.objects = pruneInput.objects;
		return assembly;
	}

	static function valueInterfaceBoxes(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrValueInterfaceBoxes(assembly.objects, assembly.interfaces);

	/** The box objects the value interface boxes made join the program's objects. */
	static function addBoxObjects(assembly:IrAssembly, pass:IrFunctionPass):Void {
		var objects = assembly.objects;
		if (objects != null)
			for (box in cast(pass, IrValueInterfaceBoxes).made)
				objects.push(box);
	}

	static function typedInterfaceCalls(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrTypedInterfaceCalls(assembly.objects, assembly.interfaces);

	/** The functions a later stage generates start after the program as it stands. */
	static function generatedFromHere(assembly:IrAssembly, pass:IrFunctionPass):Void
		assembly.generatedStart = assembly.functions.length;

	static function typedInterfaceGenerate(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		IrTypedInterfaceDispatch.generate(assembly.functions, assembly.objects, assembly.interfaces, context.lineage);
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
	static function checkedDynamicCasts(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrCheckedDynamicCasts(assembly.objects, assembly.generator.profile.nativeReflectionDispatch, null,
			false,
			false);

	/** An exported function is exposed; one already exposed is kept as it is, so it keeps its identity from build to build. */
	static function exportedFunctions(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var names = context.exportedFunctions;
		var exported = [for (name in names) name => true];
		assembly.functions = [
			for (fn in assembly.functions)
				exported.exists(fn.name) && fn.retention != IrRetention.Expose ? new IrFunction(fn.name,
				fn.arguments, fn.result, fn.blocks, fn.kind,
				fn.debugBindings,
				fn.inlineHint, Expose) : fn
		];
		return assembly;
	}

	/** Choose source enum storage before optional-flow and reflection helpers choose their ABI. */
	static function enumSpecializations(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		if (context.canonicalObjects == null)
			throw new InternalError("Inline enum lowering requires canonical objects");
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
			enumInput.objects, enumInput.staticFields, enumInput.natives, enumInput.interfaces, enumInput.cNatives,
			context.lineage);
		assembly.enumInput = enumInput;
		return assembly;
	}

	static function enumTagLowering(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass {
		var enumInput = assembly.enumInput;
		if (enumInput == null)
			throw new InternalError("Enum tag lowering needs the enum specializations' input");
		return new IrEnumTagLoweringPass(enumInput, context.lineage);
	}

	/** The enum input is the program the tag lowering finished: its tables and, from here, its functions. */
	static function loweredEnumInput(assembly:IrAssembly, pass:IrFunctionPass):Void {
		var enumInput = assembly.enumInput;
		if (enumInput != null)
			enumInput.functions = assembly.functions;
	}

	static function inlineEnums(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var enumOutput = IrInlineEnumLowering.run(assembly.enumInput, context.laneTarget, context.canonicalObjects,
			assembly.reflectableObjects, bodyTypes(context), context.passScratch.bodyBuilder, context.lineage);
		assembly.functions = enumOutput.functions;
		assembly.objects = enumOutput.objects;
		assembly.interfaces = enumOutput.interfaces;
		assembly.staticFields = enumOutput.staticFields;
		assembly.natives = enumOutput.natives;
		assembly.enums = enumOutput.enums;
		return assembly;
	}

	static function optionalScalarFlow(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrOptionalScalarFlow(assembly.objects, bodyTypes(context), context.passScratch.bodyBuilder);

	static function staticNullChecks(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		// The checked copies are kept, frozen, only in a session.
		var cache = context.options.keepSession ? context.inlineCache : null;
		assembly.functions = IrStaticNullChecks.run(assembly.functions, assembly.objects,
			cache == null ? null : cache.staticChecks, bodyTypes(context), context.passScratch.bodyBuilder);
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
		assembly.natives = IrObjectReflection.generate(generator.facts, assembly.natives, assembly.objects,
			assembly.reflectableObjects, assembly.functions, generator.profile.nativeReflectionDispatch,
			assembly.reachedNatives, context.options.checkReuse);
		assembly.functions = encodeMade("object-reflection", assembly.functions, context);
		return assembly;
	}

	/**
	 * `functions` with those a stage past the conversion point made as objects (those without a body) encoded: in a session, one
	 * made the same as last build is last build's object, which has its body. A one-shot compile lets every function's objects go,
	 * the ones the stage decoded to read included.
	 */
	static function encodeMade(stage:String, functions:Array<IrFunction>, context:IrPipelineContext):Array<IrFunction> {
		var cache = context.inlineCache, retained = context.options.keepSession;
		var made = [for (fn in functions) if (fn.body == null) fn];
		if (retained && cache != null && made.length > 0) {
			// The stable functions are encoded as the cache takes them, so the ones to replace are told apart before.
			var isMade = [for (fn in functions) fn.body == null];
			var stable = cache.stableGenerated(stage, made, context.passScratch.bodyBuilder), index = 0;
			functions = [for (position in 0...functions.length) isMade[position]
				? stable[index++] : functions[position]];
		} else if (retained && cache != null)
			cache.stableGenerated(stage, made, context.passScratch.bodyBuilder);
		encodeAll(functions, context);
		return functions;
	}

	/** Encodes `functions`: in a session they are a cache's (the encode point's or a stage's), so their bodies are frozen. */
	static function encodeAll(functions:Array<IrFunction>, context:IrPipelineContext):Void {
		var types = bodyTypes(context),
			builder = context.passScratch.bodyBuilder,
			retained = context.options.keepSession;
		// A session keeps the frozen body alone: the stages after this point read bodies, the memos before it hand on a function
		// they reuse without reading it, and the whole-program scans read bodies (`IrSourceRehash`, `IrStaticReferences`, the
		// contributions); what a later build reads as objects is decoded again from its body.
		for (fn in functions) {
			fn.bodyIn(types, builder);
			if (retained)
				fn.freezeBody(builder);
			fn.releaseDecoded();
		}
	}

	/**
	 * Reflection helpers are generated after the ordinary cast pass. Check their dynamic stores too, so a bad reflected value throws
	 * instead of trapping or corrupting a field.
	 */
	static function reflectionCasts(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var functions = assembly.functions, start = assembly.generatedStart;
		if (functions.length > start) {
			var existing = functions.slice(0, start);
			assembly.functions = existing.concat(IrCheckedDynamicCasts.rewriteBodies(functions.slice(start),
				assembly.objects, assembly.generator.profile.nativeReflectionDispatch, existing, true, true,
				bodyTypes(context), context.passScratch.bodyBuilder));
		}
		return assembly;
	}

	static function optionalFieldStorage(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var optionalStorage = new IrOptionalFieldStorage(assembly.objects);
		if (optionalStorage.hasFields()) {
			assembly.functions = optionalStorage.rewrite(assembly.functions, bodyTypes(context),
				context.passScratch.bodyBuilder);
			assembly.objects = optionalStorage.physicalObjects(assembly.objects);
		}
		return assembly;
	}

	/**
	 * The conversion point (docs/design/IR_CORE_COLUMNS.md, migration): every function is encoded, and the stages from here on read
	 * bodies. In a session the stage memos before it hand on last build's object for a function nothing changed (`IrLineage`),
	 * which has its frozen body already, so only what this build made is encoded.
	 */
	static function encodeBodies(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		encodeAll(assembly.functions, context);
		var enumInput = assembly.enumInput;
		if (enumInput != null)
			enumInput.functions = assembly.functions;
		return assembly;
	}

	static function nullFields(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass
		return new IrNullableScalarFieldsPass(new IrNullableScalarFields(assembly.objects),
			bodyTypes(context), context.passScratch.bodyBuilder);

	static function runtimeSurface(assembly:IrAssembly, context:IrPipelineContext):IrAssembly {
		var program = IrProgramAssembler.finish(assembly, context);
		assembly.program = program;
		// From here the stages work on the finished program's functions, which the lineage settles.
		assembly.functions = program.functions;
		return assembly;
	}

	static function assemblyEnumTagEscapes(assembly:IrAssembly, context:IrPipelineContext):IrFunctionPass {
		var program = assembly.program;
		if (program == null)
			throw new InternalError("The enum tag escapes run on the finished program");
		return new IrTagEscapesPass(program, bodyTypes(context), context.passScratch.bodyBuilder);
	}

	/** The finished program's functions are the stage's. */
	static function escapedProgram(assembly:IrAssembly, pass:IrFunctionPass):Void {
		var program = assembly.program;
		if (program != null)
			program.functions = assembly.functions;
	}

	// Target stages.

	static function closedEnumTagAbi(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return new IrClosedEnumTagAbi(program, context.reflectable, bodyTypes(context), context.passScratch.bodyBuilder,
			context.lineage);

	/** The program with the closed tags projected in its tables too. */
	static function closedEnumTagProgram(program:IrProgram, pass:IrFunctionPass):IrProgram
		return cast(pass, IrClosedEnumTagAbi).result();

	static function valueArrayRewrite(program:IrProgram, context:IrPipelineContext):IrProgram {
		var laneTarget = context.laneTarget;
		IrValueArrayProgramRewrite.rewriteAll(program, laneTarget == IrValueLaneTarget.HashLink ? 64 : 32, laneTarget,
			bodyTypes(context), context.passScratch, context.options.keepSession ? context.inlineCache : null);
		return program;
	}

	/**
	 * Value joins are scalarized before `scalar-arguments` (`scalar-argument-joins`), before the scalar call ABI is chosen; its call rewrite can
	 * introduce further value joins, so `value-phi-scalarization` runs again after it.
	 */
	static function valueConstructors(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return new IrValueConstructors(program, bodyTypes(context), context.passScratch, context.lineage);

	/** The last value phi scalarization before scalar replacement. */
	static function valuePhiScalarizationBodies(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return IrValuePhiScalarization.pass(program, bodyTypes(context), context.passScratch);

	/** Wasm's scalar argument ABI, with value lanes. */
	static function scalarArgumentsOnly(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return new IrScalarArguments(program, true, bodyTypes(context), context.passScratch, context.lineage);

	/** HashLink's scalar argument and result ABI. */
	static function scalarArguments(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return new IrScalarArguments(program, false, bodyTypes(context), context.passScratch, context.lineage);

	static function scalarClosures(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return new IrScalarClosures(program, bodyTypes(context), context.passScratch, context.lineage);

	static function scalarReplacementObjects(program:IrProgram, context:IrPipelineContext):IrProgram {
		context.scalarObjects = IrObjectTable.of([for (object in program.objects) object.name => object]);
		return program;
	}

	/** A function that allocates a value object is rewritten (`IrValueObjectRows`). */
	static function scalarReplacement(program:IrProgram, context:IrPipelineContext):IrFunctionPass {
		var scalarObjects = context.scalarObjects,
			hashLink = !context.isWasm(),
			types = bodyTypes(context),
			scratch = context.passScratch;
		return new IrValueObjectRows(IrOpcode.ValueInit, scalarObjects, types, scratch.bodyBuilder,
			fn -> IrScalarReplacement.rewriteBody(fn, scalarObjects, types, scratch, hashLink));
	}

	static function nullableScalarFlow(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return new IrNullableScalarFlow(program, bodyTypes(context), context.passScratch, context.lineage,
			context.options.checkReuse);

	/** Also after the retained HashLink assembly's adapters, which can introduce fresh nominal-tag escapes. */
	static function lateEnumTagEscapes(program:IrProgram, context:IrPipelineContext):IrFunctionPass
		return new IrTagEscapesPass(program, bodyTypes(context), context.passScratch.bodyBuilder);

	/**
	 * The type ids of the bodies from here to the inliner: its cache's, so it takes the functions' bodies as they are. The
	 * functions are encoded at the first stage that reads bodies (docs/design/IR_CORE_COLUMNS.md, migration).
	 */
	static function bodyTypes(context:IrPipelineContext):IrTypeIds {
		var cache = context.inlineCache;
		if (cache == null)
			throw new InternalError("The stages over bodies need the session's inline cache");
		return cache.types;
	}

	/** Runs also when only load/store forwarding is enabled: it compares and publishes the final IR. */
	static function inliner(program:IrProgram, context:IrPipelineContext):IrProgram {
		var cache = context.inlineCache;
		if (cache == null)
			throw new InternalError("The inliner stage needs the session's inline cache");
		context.inlinerChanged = IrInliner.run(program, cache, context.profile, context.options,
			context.instrumentScope);
		// `--check-reuse`: what the session keeps for the next compile is frozen, so no stage of this one changed it in place.
		if (context.options.checkReuse && context.options.keepSession) {
			var unfrozen = cache.unfrozen();
			if (unfrozen != null)
				throw new InternalError('--check-reuse: the inline cache keeps $unfrozen with a body that is not frozen');
		}
		return program;
	}

	/** HashLink has its scalar closure ABI here. Wasm verifies after its target-specific closure escape adapters exist. */
	static function verifier(program:IrProgram, context:IrPipelineContext):IrProgram {
		var memo = context.verifyMemo;
		if (memo == null)
			throw new InternalError("The verifier stage needs the session's verify memo");
		IrVerifier.verifyReusing(program, memo, context.options.checkIrBody);
		return program;
	}

	/** `--check-reuse`: the memoized verification accepted only what a full one accepts, and every provider call is declared. */
	static function verifierCheck(program:IrProgram, context:IrPipelineContext):IrProgram {
		try
			IrVerifier.verify(program)
		catch (error:InternalError)
			throw new InternalError('--check-reuse: verification skipped a function that fails in full: ${error.message}');
		var providerProblem = IrProviders.check(program.functions);
		if (providerProblem != null)
			throw new InternalError('--check-reuse: $providerProblem');
		return program;
	}
}
