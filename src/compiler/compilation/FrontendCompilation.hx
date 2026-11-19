package compiler.compilation;

import compiler.core.AllocationMeter;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.runtime.PlatformAbi;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrStaticField;
import compiler.ir.Ir.IrType;
import compiler.ir.IrInstrumentation.IrInstrumentationScope;
import compiler.abi.PositionalName;
import compiler.ir.IrFunction;
import compiler.ir.IrGenerator;
import compiler.ir.IrProgramAssembler;
import compiler.modules.ModuleReachability;
import compiler.modules.ModuleState;
import compiler.semantic.LambdaName;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.SemanticAssembly;
import compiler.semantic.SemanticAssembly.SemanticAssemblyResult;
import compiler.semantic.SemanticSignature;
import compiler.core.CancellationToken;
import compiler.semantic.SemanticProgram;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.typing.EnumRuntimeType;
import compiler.types.typing.RetainedFromPrevious;
import compiler.types.typing.RuntimeDependencyTracker;
import compiler.types.typing.TypingFailure;
import compiler.types.Type.CompilerType;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.SemanticDependencyCollector;
import compiler.syntax.Ast.AstProgram;
import compiler.core.AllocationMeter.AllocationSnapshot;
import compiler.core.AllocationMeter.PhaseAllocation;
import compiler.compilation.PipelineSnapshot.PipelineInputs;

typedef FrontendResult = {
	final ir:Null<IrProgram>;
	final moduleNames:Array<String>;
	/** Null once a compile that keeps no session (`CompileOptions.keepSession`) has released it before the backend. */
	var typedProgram:Null<TypedProgram>;
	final retyped:Array<String>;
	final invalidations:Array<compiler.semantic.Invalidation.InvalidatedArtifact>;
	final regenerated:Array<String>;

	/** Functions whose code is unchanged but whose positions moved in their file: lowered again, not patched. */
	final relocated:Array<String>;

	final typerMetrics:TyperPhaseMetrics;
	final frontendGraphDoneAt:Float;
	final semanticAliasMs:Float;
	final semanticCanonicalizationMs:Float;
	final semanticContributionReuseMs:Float;
	final semanticContributionRebuildMs:Float;
	final semanticInvalidationMs:Float;
	final semanticAllocatedBytes:Float;
	final graphParseMs:Float;
	final graphDependencyMs:Float;
	final graphInitializationMs:Float;
	final frontendRestarts:Array<String>;
	final frontendPassFunctions:Array<Int>;
	final frontendPassReports:Array<String>;
	final irPassAllocations:Array<compiler.core.IrPassMeter.IrPassAllocation>;
	final frontendDoneAt:Float;

	/** Semantic analysis of the final frontend pass, which `typingLoweringDoneAt - frontendDoneAt` includes. */
	final analysisMs:Float;

	/** Typed AST to IR generation of the final frontend pass, which `typingLoweringDoneAt - frontendDoneAt` includes. */
	final irGenerationMs:Float;

	final typingLoweringDoneAt:Float;
	final irAssemblyDoneAt:Float;
	final allocationPhases:Array<PhaseAllocation>;

	/** The earlier build whose final IR this one equals, when every input of the IR pipeline matched (see `PipelineSnapshot`). */
	final reused:Null<PipelineSnapshot>;

	/** Why no earlier build could be reused, when there was one to compare with; null otherwise. */
	final reuseMiss:Null<String>;
}

/**
 * One frontend pass: its inputs, what its phases hand to each other, and the time and allocation readings taken at the phase
 * boundaries. `FrontendCompilation.run` makes one per pass; a restart is another pass with its own.
 */
private class FrontendBuild {
	public final context:CompilationContext;
	public final entryModule:String;
	public final token:Null<CancellationToken>;
	public final rollbackModules:Map<String, ModuleState>;
	public final lowerToIr:Bool;
	public final indexSemantics:Bool;

	/** What earlier passes of this build regenerated and retyped, when this pass is a restart. */
	public final carried:Null<{
		regenerated:Array<String>,
		retyped:Array<String>
	}>;

	// The start of the pass.
	public var allocationAtStart:AllocationSnapshot;
	public var passStartedAt:Float;
	public var parseMsAtStart:Float;
	public var parseBytesAtStart:Float;
	public var parseCountAtStart:Float;

	// The module graph.
	public var bodyChanged:Map<String, Bool>;
	public var signatureChanged:Map<String, Bool>;
	public var structuralChanged:Map<String, Bool>;
	public var names:Array<String>;
	public var initializationClasses:Array<String>;
	public var graphParseMs = 0.0;
	public var graphDependencyMs = 0.0;
	public var graphInitializationMs = 0.0;
	public var frontendGraphDoneAt:Float;
	public var allocationAfterGraph:AllocationSnapshot;

	// Semantic assembly.
	public var semanticAssembly:SemanticAssemblyResult;
	public var frontendDoneAt:Float;
	public var allocationAfterSemantic:AllocationSnapshot;

	// Signature inference and typing.
	public var allocationAfterAnalysis:AllocationSnapshot;
	public var analysisDoneAt:Float;
	public var typingDoneAt:Float;
	public var allocationAfterProgramTyping:AllocationSnapshot;
	public var typedNew:TypedProgram;
	public var typerMetrics:TyperPhaseMetrics;
	public var generator:IrGenerator;
	public var runtimeDependencies:Array<{
		var functionName:String;
		var target:String;
	}>;
	public var purityQueries:Map<String, Map<String, Bool>>;
	public var noReturnQueries:Map<String, Map<String, Bool>>;
	public var keyPathUses:Map<String, Map<String, Bool>>;
	public var inlineConstantDependencies:Map<String, Map<String, Bool>>;
	public var declarationTypeReads:Map<String, Map<String, Bool>>;
	public var typedUnits:Map<String, Bool>;

	/** The signatures of the unannotated functions this build typed, by key, which `publishInferredSignatures` keeps. */
	public var inferredSignatures:Map<String, compiler.types.DeclarationTypes.InferredSignature> = [];
	public var defaultArgumentSources:Map<String, Map<String, compiler.core.Source.SourceFile>>;

	// Publication of the typed program, pruning and IR generation.
	public var reindexedModules:Map<String, Bool>;
	public var allocationAfterIndexRebuild:AllocationSnapshot;
	public var retyped:Array<String>;
	public var regenerated:Array<String>;
	public var currentSpecializedOwners:Map<String, Bool>;
	public var currentObjects:Array<IrObject>;
	public var allocationAfterObjects:AllocationSnapshot;
	public var typedByName:Map<String, compiler.types.TypedAst.TypedFunction>;
	public var touchedModules:Map<String, Bool>;
	public var allocationAfterFunctions:AllocationSnapshot;
	public var allocationAfterIndexPublication:AllocationSnapshot;
	public var allocationBeforeModulePrune:AllocationSnapshot;
	public var allocationAfterModulePrune:AllocationSnapshot;
	public var allocationAfterPrune:AllocationSnapshot;
	public var irGenerationDoneAt:Float;
	public var typingLoweringDoneAt:Float;
	public var allocationAfterTyping:AllocationSnapshot;
	public var allocationPhases:Array<PhaseAllocation>;

	// The input of the IR pipeline.
	public var cachedNames:Array<String>;
	public var currentHashes:Map<String, Int>;
	public var cached:Array<IrFunction>;
	public var irNatives:Array<IrNative>;
	public var irCNatives:Array<IrCNative>;
	public var instrumentScope:Null<IrInstrumentationScope>;
	public var objects:Array<IrObject>;
	public var interfaces:Array<IrInterface>;
	public var enums:Array<IrEnum>;
	public var staticFields:Array<IrStaticField>;
	public var initializers:Array<IrFunction>;
	public var reflectable:Array<String>;

	// The IR pipeline and what it changed.
	public var ir:IrProgram;
	public var inlinerChanged:Array<String>;
	public var reusedPipeline:Null<PipelineSnapshot>;
	public var reuseMiss:Null<String>;
	public var matchesPrevious:Bool;
	public var checkingReuse:Bool;
	public var relocated:Array<String>;

	public function new(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>, lowerToIr:Bool, indexSemantics:Bool, carried:Null<{
				regenerated:Array<String>,
				retyped:Array<String>
			}>) {
		this.context = context;
		this.entryModule = entryModule;
		this.token = token;
		this.rollbackModules = rollbackModules;
		this.lowerToIr = lowerToIr;
		this.indexSemantics = indexSemantics;
		this.carried = carried;
	}
}

/** Builds and validates the reachable source graph through complete IR assembly. */
class FrontendCompilation {
	/**
	 * One frontend pass, as a sequence of phases over one `FrontendBuild`. A pass that finds a runtime helper while typing publishes
	 * what it typed and restarts; the pass that finishes reports the build.
	 */
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>,
			snapshotDoneAt:Float, ?lowerToIr = true, ?indexSemantics = true, ?pendingBody:Map<String, Bool>,
			?pendingSignatures:Map<String, Bool>,
			?pendingStructural:Map<String, Bool>, ?carried:{
				regenerated:Array<String>,
				retyped:Array<String>
			}):FrontendResult {
		seedRepresentationModules(context);
		var build = new FrontendBuild(context, entryModule, token, rollbackModules, lowerToIr, indexSemantics, carried);
		startPass(build);
		checkCancelled(token);
		resolveGraph(build, pendingBody, pendingSignatures, pendingStructural);
		assembleSemantics(build);
		typeProgram(build);
		TypingWarnings.publish(context, entryModule, build.names, build.typedNew, rollbackModules);
		rebuildSemanticIndex(build, typedFieldTypes(build));
		publishObjects(build);
		publishFunctions(build);
		publishIndex(build);
		pruneCachedFunctions(build);
		generatePendingIr(build);
		reportPass(build);
		// A runtime helper found while typing joins the program after this pass. What was typed so far is published, so the next
		// pass is an incremental one over it: it has the newly reachable modules to type, and the work of this pass carries over.
		if (includeTypedRuntimeDependencies(context, build.runtimeDependencies, build.typedNew.functions,
			build.semanticAssembly.owners, build.names, rollbackModules)) {
			context.state.lastTypedProgram = build.typedNew;
			return run(context, entryModule, token, rollbackModules, snapshotDoneAt, lowerToIr, indexSemantics, [], [],
				[], {
					regenerated: build.regenerated,
					retyped: build.retyped
				});
		}
		if (context.options.checkReuse)
			checkHelperCalls(build.context.state.modules, build.names);
		finishTyping(build);
		if (!lowerToIr)
			return result(build, null, [], build.typingLoweringDoneAt, null, null);
		collectCachedIr(build);
		checkCancelled(token);
		// A compile that keeps no session assembles the IR from the typed program alone; the syntax is no longer needed.
		if (!context.options.keepSession) {
			context.state.releaseSyntax();
			context.moduleAnalyzer.releaseLookupParses();
		}
		assembleTables(build);
		runIrPipeline(build);
		selectChangedFunctions(build);
		var irAssemblyDoneAt = now();
		build.allocationPhases.push(AllocationMeter.delta("ir-assembly", build.allocationAfterTyping,
			AllocationMeter.sample()));
		return result(build, build.ir, build.relocated, irAssemblyDoneAt, build.reusedPipeline, build.reuseMiss);
	}

	/** The clock of every timestamp and duration in `FrontendResult`: milliseconds. */
	static inline function now():Float
		return Sys.time() * 1000.0;

	static inline function checkCancelled(token:Null<CancellationToken>):Void
		if (token != null)
			token.check();

	/** The allocation, time and parsing counters the pass report measures from. */
	static function startPass(build:FrontendBuild):Void {
		var context = build.context;
		build.allocationAtStart = AllocationMeter.sample();
		build.passStartedAt = now();
		build.parseMsAtStart = context.parseMs;
		build.parseBytesAtStart = context.parseBytes;
		build.parseCountAtStart = context.parseCount;
	}

	/** The reachable modules and the classes in initialization order: the cached reachability when nothing it read changed. */
	static function sortedModuleNames(modules:Map<String, ModuleState>):Array<String> {
		var names = [for (name in modules.keys()) name];
		names.sort(Reflect.compare);
		return names;
	}

	static function resolveGraph(build:FrontendBuild, pendingBody:Null<Map<String, Bool>>,
			pendingSignatures:Null<Map<String, Bool>>, pendingStructural:Null<Map<String, Bool>>):Void {
		var context = build.context,
			entryModule = build.entryModule,
			token = build.token,
			modules = context.state.modules,
			graph = context.graph;
		var bodyChanged:Map<String, Bool> = pendingBody == null ? [] : pendingBody,
			signatureChanged:Map<String, Bool> = pendingSignatures == null ? [] : pendingSignatures,
			structuralChanged:Map<String, Bool> = pendingStructural == null ? [] : pendingStructural;
		build.bodyChanged = bodyChanged;
		build.signatureChanged = signatureChanged;
		build.structuralChanged = structuralChanged;
		// The graph walk parses what it reaches one module at a time; with `--parse-threads`, every module that needs it is parsed first,
		// on that many threads.
		if (context.options.parseThreads > 1)
			context.moduleAnalyzer.prefetchParses([for (name in sortedModuleNames(modules)) modules.get(name)],
				context.options.parseThreads);
		var names:Array<String> = [],
			initializationClasses:Array<String> = [],
			cachedReachability = context.state.cachedReachability(entryModule),
			reuseGraph = cachedReachability != null;
		if (cachedReachability != null)
			for (name in cachedReachability.names) {
				var state = modules.get(name);
				if (state == null) {
					reuseGraph = false;
					break;
				}
				if (state.ast == null)
					state = parseReached(build, name);
				if (cachedReachability.dependencyKeys.get(name) != CompilationContext.dependencyKey(state.dependencies))
					reuseGraph = false;
			}
		if (!CompilationContext.mapIsEmpty(structuralChanged))
			reuseGraph = false;
		if (reuseGraph && cachedReachability != null) {
			names = cachedReachability.names.copy();
			initializationClasses = cachedReachability.initializationClasses.copy();
		} else {
			var reachability = new ModuleReachability(modules, entryModule, context.rootModules);
			while (reachability.hasNext(token)) {
				var reachableState = reachability.next();
				if (reachableState.ast == null)
					reachableState = parseReached(build, reachableState.name);
				reachability.includeDependencies(reachableState);
			}
			names = reachability.finish(token);
			var initializationStartedAt = now();
			graph.rebuild(modules);
			// Haxe's type order: modules by path, each module's classes as it declares them (`StaticInitializationOrder`).
			var initializationNames = names.copy();
			initializationNames.sort(compiler.ir.StaticInitializationOrder.compareModules);
			for (name in initializationNames) {
				var state = modules.get(name), ast = state.parsedAst();
				for (classDecl in ast.classes)
					initializationClasses.push(ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name));
			}
			context.state.cacheReachability(entryModule, names, initializationClasses);
			build.graphInitializationMs = now() - initializationStartedAt;
		}
		build.names = names;
		build.initializationClasses = initializationClasses;
		compiler.modules.CodeIdentityTable.refresh(context, names, build.rollbackModules, entryModule, bodyChanged,
			signatureChanged, structuralChanged);
		build.frontendGraphDoneAt = now();
		build.allocationAfterGraph = AllocationMeter.sample();
	}

	/** Parses a module the graph reached without a syntax tree and records its type dependencies, timing each. */
	static function parseReached(build:FrontendBuild, name:String):ModuleState {
		var context = build.context;
		var phaseStarted = now();
		var state = context.state.writableState(name, build.rollbackModules);
		context.parse(state, build.entryModule, build.bodyChanged, build.signatureChanged, build.structuralChanged);
		build.graphParseMs += now() - phaseStarted;
		phaseStarted = now();
		context.moduleAnalyzer.addTypeDependencies(state);
		build.graphDependencyMs += now() - phaseStarted;
		return state;
	}

	static function assembleSemantics(build:FrontendBuild):Void {
		build.semanticAssembly = SemanticAssembly.run(build.context, build.entryModule, build.token,
			build.rollbackModules,
			build.names, build.bodyChanged, build.signatureChanged, build.structuralChanged, build.indexSemantics,
			build.carried != null);
		build.frontendDoneAt = now();
		build.allocationAfterSemantic = AllocationMeter.sample();
	}

	/**
	 * Semantic analysis (or the previous build's, with the new bodies, when no declaration changed) and typing of the selected
	 * functions. A compile error is recorded on the module it names before it propagates.
	 */
	static function typeProgram(build:FrontendBuild):Void {
		var context = build.context,
			names = build.names,
			semanticAssembly = build.semanticAssembly,
			canonicalProgram = semanticAssembly.canonicalProgram,
			selected = semanticAssembly.selected;
		build.allocationAfterAnalysis = build.allocationAfterSemantic;
		build.analysisDoneAt = build.frontendDoneAt;
		build.typingDoneAt = build.frontendDoneAt;
		build.allocationAfterProgramTyping = build.allocationAfterSemantic;
		build.runtimeDependencies = [];
		try {
			checkCancelled(build.token);
			var previousSemantic = context.state.semanticProgram;
			var canReuseSemantic = previousSemantic != null
				&& CompilationContext.mapIsEmpty(build.signatureChanged)
				&& CompilationContext.mapIsEmpty(build.structuralChanged)
				&& sameDeclarations(previousSemantic.program, canonicalProgram);
			var semantic:SemanticProgram;
			if (canReuseSemantic && previousSemantic != null)
				semantic = previousSemantic.replaceBodies(canonicalProgram, selected);
			else
				semantic = SemanticProgram.analyze(canonicalProgram);
			semantic.staticExtensions = semanticAssembly.staticExtensions;
			build.allocationAfterAnalysis = AllocationMeter.sample();
			build.analysisDoneAt = now();
			var typedResult = Typer.typeAnalyzedMeasured(semantic, selected, context.natives.signatures(),
				semanticAssembly.entryPoint, context.state.genericSpecializations,
				context.nativeLayoutTarget(), canReuseSemantic ? context.state.lastTypedProgram : null,
				semanticAssembly.facts, build.lowerToIr,
				retainedFromPrevious(context, names, selected, build.lowerToIr,
				[for (classDecl in canonicalProgram.classes) classDecl.name => true],
				previousSemantic), context.options.reverseTypingOrder, {
					signatures: previousSignatures(context, names),
					check: context.options.checkReuse
				}, context.options.elaborateGenerics);
			build.allocationAfterProgramTyping = AllocationMeter.sample();
			build.typingDoneAt = now();
			var typedNew = typedResult.program;
			build.typedNew = typedNew;
			context.frontendPassFunctions.push(typedNew.functions.length);
			build.generator = new IrGenerator(compiler.ir.ProgramFacts.of(typedNew), context.targetProfile());
			build.generator.verifiesCfg = context.options.verifyIr;
			build.typerMetrics = typedResult.metrics;
			var runtimeDependencies = typedResult.runtimeDependencies;
			build.runtimeDependencies = runtimeDependencies;
			build.purityQueries = typedResult.purityQueries;
			build.noReturnQueries = typedResult.noReturnQueries;
			build.keyPathUses = typedResult.keyPathUses;
			build.inlineConstantDependencies = typedResult.inlineConstantDependencies;
			build.declarationTypeReads = typedResult.declarationTypeReads;
			build.typedUnits = typedResult.typedUnits;
			build.inferredSignatures = typedResult.inferredSignatures;
			build.defaultArgumentSources = typedResult.defaultArgumentSources;
			// A module that changes a representation is in the program before anything is typed (see `seedRepresentationModules`),
			// so typing cannot have used a representation without it. If one is reported missing, a module was left out of the
			// seeds: fail here, naming it, and do not compile what was typed against the wrong representation.
			for (dependency in runtimeDependencies)
				if (RuntimeDependencyTracker.changesRepresentation(dependency.target)) {
					var representationModule = context.moduleAnalyzer.loadSourceModuleDependency(dependency.target);
					if (representationModule == null || names.indexOf(representationModule) < 0)
						throw new InternalError('Representation module "${dependency.target}" must be seeded but is not in the program (needed by "${dependency.functionName}")');
				}
			context.state.semanticProgram = semantic;
		} catch (error:CompileError) {
			// Typing recovers from a failed body and goes on, so the error can carry one diagnostic per failed body: each goes to
			// the module of its file.
			for (diagnostic in error.diagnostics)
				for (name in names) {
					var state:compiler.modules.ModuleState = context.state.modules.get(name);
					if (state.source.path == diagnostic.span.file.path)
						context.state.writableState(name, build.rollbackModules).diagnostics.push(diagnostic);
				}
			if (build.indexSemantics && Std.isOfType(error, TypingFailure)) {
				var failure:TypingFailure = cast error;
				indexRecoveredTyping(build, failure);
				for (module in build.reindexedModules.keys())
					failure.indexedModules.set(module, true);
			}
			throw error;
		}
	}

	/**
	 * After a typing that recovered from failed bodies, the selected modules get new semantic models with the bodies that typed
	 * indexed, as a successful build would index them, and the bodies that failed indexed from their syntax: an editor then has the
	 * types the typer found everywhere but in a failed body. The build still fails; the models are only what the editor reads.
	 */
	static function indexRecoveredTyping(build:FrontendBuild, failure:TypingFailure):Void {
		rebuildSemanticIndex(build, failure.inferredFieldTypes);
		var typed = failure.typed,
			context = build.context,
			owners = build.semanticAssembly.owners,
			typedByName = [for (fn in typed) fn.name => fn],
			indexedSpans:Map<String, Map<Int, Bool>> = [];
		for (fn in typed) {
			var module = recoveredFunctionModule(fn, owners, typedByName, 0);
			if (module == null || !build.reindexedModules.exists(module))
				continue;
			var state = context.state.modules.get(module),
				model = state == null ? null : state.semanticModel;
			if (model == null)
				continue;
			model.index.indexTypedFunction(fn, context.state.semanticWorkspace.resolveSymbolId,
				context.state.semanticWorkspace.resolveEnumCaseId, build.token);
			var spans = indexedSpans.get(module);
			if (spans == null) {
				spans = [];
				indexedSpans.set(module, spans);
			}
			spans.set(fn.span.start, true);
		}
		for (module in build.reindexedModules.keys()) {
			var state = context.state.modules.get(module),
				model = state == null ? null : state.semanticModel;
			if (model != null && state != null) {
				var spans = indexedSpans.get(module);
				model.index.indexRecoveredSyntax(state.parsedAst(), spans == null ? [] : spans);
			}
		}
		// The unannotated declarations that typed keep the types the table gave them, beside the error.
		for (key => signature in failure.inferredSignatures) {
			var module = owners.get(key);
			if (module != null && build.reindexedModules.exists(module))
				recordInferredSignature(context, module, key, signature);
		}
		for (key => type in failure.inferredFieldTypes)
			for (module in build.reindexedModules.keys()) {
				var state = context.state.modules.get(module),
					model = state == null ? null : state.semanticModel;
				if (model != null && modelOwnsType(model.program, compiler.core.QualifiedName.parentOrEmpty(key)))
					model.index.recordInferredField(key, type);
			}
	}

	static function recordInferredSignature(context:CompilationContext, module:String, key:String,
			signature:compiler.types.DeclarationTypes.InferredSignature):Void {
		var state = context.state.modules.get(module),
			model = state == null ? null : state.semanticModel;
		if (model != null)
			model.index.recordInferredSignature(key, signature);
	}

	/** The module of a function a failed typing made, as `resolveFunctionModule` finds it, or null when its origin is not known. */
	static function recoveredFunctionModule(fn:compiler.types.TypedAst.TypedFunction, owners:Map<String, String>,
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction>, depth:Int):Null<String> {
		if (owners.exists(fn.name))
			return owners.get(fn.name);
		var origin = fn.origin;
		if (origin == null || depth > 64)
			return null;
		if (owners.exists(origin))
			return owners.get(origin);
		var initializer = initializerModule(origin, owners);
		if (initializer != null)
			return initializer;
		var parent = typedByName.get(origin);
		return parent == null ? null : recoveredFunctionModule(parent, owners, typedByName, depth + 1);
	}

	/** The types typing gave the unannotated fields of the typed program, by key. */
	static function typedFieldTypes(build:FrontendBuild):Map<String, CompilerType> {
		var inferred = build.semanticAssembly.inferredDeclarations, result:Map<String, CompilerType> = [];
		for (classDecl in build.typedNew.classes)
			for (field in classDecl.fields)
				if (inferred.exists(classDecl.name + "." + field.name))
					result.set(classDecl.name + "." + field.name, field.type);
		return result;
	}

	/**
	 * New semantic models for the modules whose functions were selected, and for those whose model shows an unannotated field with
	 * another type than `fieldTypes` (the types typing gave, by key), with their type references indexed.
	 */
	static function rebuildSemanticIndex(build:FrontendBuild, fieldTypes:Map<String, CompilerType>):Void {
		var context = build.context,
			owners = build.semanticAssembly.owners;
		var reindexedModules:Map<String, Bool> = [];
		for (functionName in build.semanticAssembly.selected.keys()) {
			var module = owners.get(functionName);
			if (module != null)
				reindexedModules.set(module, true);
		}
		if (build.indexSemantics) {
			var classModules:Map<String, String> = [];
			for (name in build.names) {
				var state = context.state.modules.get(name), ast = state == null ? null : state.ast;
				if (ast != null)
					for (classDecl in ast.classes)
						classModules.set(ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name), name);
			}
			for (key => type in fieldTypes) {
				var module = classModules.get(compiler.core.QualifiedName.parentOrEmpty(key));
				if (module == null || reindexedModules.exists(module))
					continue;
				var state = context.state.modules.get(module),
					model = state == null ? null : state.semanticModel,
					shown = model == null ? null : model.index.inferredFieldTypes.get(key);
				if (shown == null || SemanticSignature.type(shown) != SemanticSignature.type(type))
					reindexedModules.set(module, true);
			}
		}
		build.reindexedModules = reindexedModules;
		if (build.indexSemantics) {
			for (module in reindexedModules.keys()) {
				var state = context.state.writableState(module, build.rollbackModules);
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source,
					state.revision, state.tokens);
			}
			context.state.semanticWorkspace.invalidateResolutionCache();
			for (module in reindexedModules.keys()) {
				var state = context.state.modules.get(module);
				if (state != null) {
					var model = state.semanticModel;
					if (model != null)
						model.index.indexTypeReferences(context.state.semanticWorkspace.resolveTypeSymbolId,
							build.token);
				}
			}
		}
		build.allocationAfterIndexRebuild = AllocationMeter.sample();
	}

	/** The object layouts of the typed classes, in the object caches, and the generator that lowers against them. */
	static function publishObjects(build:FrontendBuild):Void {
		var context = build.context,
			typedNew = build.typedNew,
			generator = build.generator,
			carried = build.carried,
			objectCache = context.state.objectCache,
			canonicalObjectCache = context.state.canonicalObjectCache;
		build.retyped = carried == null ? [] : carried.retyped.copy();
		build.regenerated = carried == null ? [] : carried.regenerated.copy();
		var previousTyped = context.state.lastTypedProgram;
		build.currentSpecializedOwners = [
			for (classDecl in typedNew.classes)
				if (classDecl.specializationOrigin != null) classDecl.name => true
		];
		if (previousTyped != null) {
			var currentClasses = [for (classDecl in typedNew.classes) classDecl.name => true];
			for (classDecl in previousTyped.classes)
				if (!currentClasses.exists(classDecl.name)) {
					objectCache.remove(classDecl.name);
					canonicalObjectCache.remove(classDecl.name);
				}
		}
		// The objects a function makes for its closures and captured variables are named by source offsets. When the function
		// is typed again they are made again under their new names, and the old ones must not stay behind.
		var retypedNames:Map<String, Bool> = [for (fn in typedNew.functions) fn.name => true];
		for (name in [for (name in objectCache.keys()) name])
			if (isGeneratedObjectOfRetypedFunction(name, retypedNames)) {
				objectCache.remove(name);
				canonicalObjectCache.remove(name);
			}
		for (classDecl in typedNew.classes)
			canonicalObjectCache.remove(classDecl.name);
		var typedObjects = IrProgramAssembler.objectsFrom(generator, typedNew, null, false, printsStructures(context));
		// The printers the anonymous structures among these objects name, made from the same typed program as the objects and kept
		// beside them (`objectCache`): a later pass or build may take an object from the cache without typing its structure again.
		if (printsStructures(context))
			for (fn in IrProgramAssembler.anonymousStringsFrom(generator, typedNew))
				context.state.anonymousStrings.set(fn.name, fn);
		var canonicalAbi = compiler.ir.IrInlineEnumLayout.CANONICAL_ABI;
		if (typedNew.nativeAbiTarget == canonicalAbi) {
			for (object in typedObjects)
				if (object.isValue && object.nativeLayout != null)
					canonicalObjectCache.set(object.name, object);
		} else {
			var sameLayout:Map<String, Bool> = [
				for (classDecl in typedNew.classes)
					if (classDecl.isValue
					&& IrProgramAssembler.matchesCanonicalLayout(classDecl, typedNew.nativeAbiTarget))
					classDecl.name => true
			];
			for (object in typedObjects)
				if (object.isValue && object.nativeLayout != null && sameLayout.exists(object.name))
					canonicalObjectCache.set(object.name, {
						name: object.name,
						isValue: object.isValue,
						base: object.base,
						interfaces: object.interfaces,
						fields: object.fields,
						methods: object.methods,
						nativeLayout: {
							target: canonicalAbi,
							size: object.nativeLayout.size,
							alignment: object.nativeLayout.alignment
						}
					});
			for (object in IrProgramAssembler.objectsFrom(generator, typedNew, canonicalAbi, true))
				canonicalObjectCache.set(object.name, object);
		}
		for (object in typedObjects)
			objectCache.set(object.name, object);
		var currentObjects:Array<IrObject> = [for (name in objectCache.keys()) objectCache.get(name)];
		build.currentObjects = currentObjects;
		build.generator = generator.withObjects(currentObjects);
		build.allocationAfterObjects = AllocationMeter.sample();
	}

	/**
	 * Each typed function into its module's state, with the dependencies and queries typing recorded for it, and lowered to IR
	 * when the build lowers.
	 */
	static function publishFunctions(build:FrontendBuild):Void {
		var context = build.context,
			token = build.token,
			rollbackModules = build.rollbackModules,
			typedNew = build.typedNew,
			generator = build.generator,
			owners = build.semanticAssembly.owners,
			generatedByModule = build.semanticAssembly.generatedByModule,
			invalidated = build.semanticAssembly.invalidated,
			inlineConstantDependencies = build.inlineConstantDependencies,
			defaultArgumentSources = build.defaultArgumentSources,
			purityQueries = build.purityQueries,
			noReturnQueries = build.noReturnQueries,
			keyPathUses = build.keyPathUses,
			retyped = build.retyped,
			regenerated = build.regenerated,
			indexSemantics = build.indexSemantics,
			lowerToIr = build.lowerToIr;
		var touchedModules:Map<String, Bool> = [],
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction> = [],
			generatedFunctions:Map<String, Bool> = [];
		build.touchedModules = touchedModules;
		build.typedByName = typedByName;
		for (fn in typedNew.functions) {
			typedByName.set(fn.name, fn);
			if (!owners.exists(fn.name))
				generatedFunctions.set(fn.name, true);
		}
		for (fn in typedNew.functions) {
			checkCancelled(token);
			checkLambdaOrigin(fn);
			var generated = generatedFunctions.exists(fn.name),
				module = resolveFunctionModule(fn, owners, typedByName, []);
			if (generated) {
				var generatedNames:Map<String, Bool>;
				if (generatedByModule.exists(module))
					generatedNames = generatedByModule.get(module);
				else {
					generatedNames = [];
					generatedByModule.set(module, generatedNames);
				}
				generatedNames.set(fn.name, true);
			}
			var state = context.state.writableState(module, rollbackModules);
			state.typedFunctions.set(fn.name, fn);
			state.typedSourceRevisions.set(fn.name, state.revision);
			var dependencies = state.semanticDependencies.get(fn.name);
			if (dependencies != null)
				state.semanticDependencies.set(fn.name, [
					for (dependency in dependencies)
						if (dependency.kind != SemanticDependencyKind.InlineConstant
						&& dependency.kind != SemanticDependencyKind.DeclarationType) dependency
				]);
			var constants = inlineConstantDependencies.get(fn.name);
			if (constants != null)
				for (target in constants.keys())
					SemanticDependencyCollector.addDependency(state.semanticDependencies, fn.name,
						SemanticDependencyKind.InlineConstant, target,
						context.state.semanticWorkspace.resolveSymbolId(target));
			addDeclarationTypeEdges(context, state, fn.name, build.declarationTypeReads.get(fn.name));
			var sourceRecord = defaultArgumentSources.get(fn.name);
			if (sourceRecord != null)
				state.defaultArgumentSources.set(fn.name, sourceRecord);
			else
				state.defaultArgumentSources.remove(fn.name);
			var purityRecord = purityQueries.get(fn.name);
			if (purityRecord != null)
				state.purityQueries.set(fn.name, purityRecord);
			else
				state.purityQueries.remove(fn.name);
			var noReturnRecord = noReturnQueries.get(fn.name);
			if (noReturnRecord != null)
				state.noReturnQueries.set(fn.name, noReturnRecord);
			else
				state.noReturnQueries.remove(fn.name);
			var keyPathRecord = keyPathUses.get(fn.name);
			if (keyPathRecord != null)
				state.keyPathUses.set(fn.name, keyPathRecord);
			else
				state.keyPathUses.remove(fn.name);
			if (indexSemantics && state.semanticModel != null)
				state.semanticModel.index.indexTypedFunction(fn, context.state.semanticWorkspace.resolveSymbolId,
					context.state.semanticWorkspace.resolveEnumCaseId, token);
			// A lambda names the function it is written in as its origin, so it is retyped with that function.
			var semanticOrigin = fn.origin;
			var semanticallyInvalidated = invalidated.exists(fn.name) || semanticOrigin != null
				&& invalidated.exists(semanticOrigin);
			if (semanticallyInvalidated)
				retyped.push(fn.name);
			touchedModules.set(module, true);
			if (lowerToIr) {
				state.irFunctions.set(fn.name, generator.generateFunction(fn));
				state.irSourceRevisions.set(fn.name, state.revision);
				state.pendingIrFunctions.remove(fn.name);
				regenerated.push(fn.name);
				var version = state.irVersions.exists(fn.name) ? state.irVersions.get(fn.name) + 1 : 1;
				state.irVersions.set(fn.name, version);
			} else
				state.pendingIrFunctions.set(fn.name, true);
		}
		publishInitializerReads(build);
		publishDeclarationTypeDigests(build);
		publishInferredSignatures(build);
		var objectCache = context.state.objectCache;
		for (object in build.currentObjects)
			objectCache.set(object.name, object);
		build.allocationAfterFunctions = AllocationMeter.sample();
	}

	/** Replaces the `DeclarationType` edges of `owner`, which was just typed, with the declaration types it read. */
	static function addDeclarationTypeEdges(context:CompilationContext, state:ModuleState, owner:String,
			reads:Null<Map<String, Bool>>):Void {
		var dependencies = state.semanticDependencies.get(owner);
		if (dependencies != null)
			for (dependency in dependencies)
				if (dependency.kind == SemanticDependencyKind.DeclarationType) {
					state.semanticDependencies.set(owner, [
						for (dependency in dependencies)
							if (dependency.kind != SemanticDependencyKind.DeclarationType) dependency
					]);
					break;
				}
		if (reads != null)
			for (target in reads.keys())
				SemanticDependencyCollector.addDependency(state.semanticDependencies, owner,
					SemanticDependencyKind.DeclarationType, target,
					context.state.semanticWorkspace.resolveSymbolId(target));
	}

	/**
	 * A field initializer is a unit of its own (`Class.__init.x`, `InitializerUnit`) and no typed function: what each typed one read
	 * is published under that name, in the module of its class.
	 */
	static function publishInitializerReads(build:FrontendBuild):Void {
		var owners = build.semanticAssembly.owners;
		for (unit in build.typedUnits.keys()) {
			var module = initializerModule(unit, owners);
			if (module == null)
				continue;
			var state = build.context.state.modules.get(module);
			if (state == null)
				continue;
			var reads = build.declarationTypeReads.get(unit);
			if (reads == null && !state.semanticDependencies.exists(unit))
				continue;
			addDeclarationTypeEdges(build.context, build.context.state.writableState(module, build.rollbackModules),
				unit,
				reads);
		}
	}

	/**
	 * Each unannotated declaration typed in this build publishes the type it was typed with (`ModuleState.declarationTypeDigests`).
	 * With `--check-reuse`, a declaration whose type differs from the one published before must have had every reader recorded
	 * against it typed again: a reader that kept its body was typed against the old type, which a fresh build would not do.
	 */
	static function publishDeclarationTypeDigests(build:FrontendBuild):Void {
		var context = build.context,
			owners = build.semanticAssembly.owners,
			inferred = build.semanticAssembly.inferredDeclarations,
			changed:Array<{declaration:String, before:String, after:String}> = [];
		function publish(module:Null<String>, declaration:String, type:CompilerType):Void {
			if (module == null)
				return;
			var state = context.state.modules.get(module);
			if (state == null)
				return;
			var digest = SemanticSignature.type(type),
				before = state.declarationTypeDigests.get(declaration);
			if (before == digest)
				return;
			if (before != null)
				changed.push({declaration: declaration, before: before, after: digest});
			context.state.writableState(module, build.rollbackModules).declarationTypeDigests.set(declaration, digest);
		}
		for (fn in build.typedNew.functions)
			if (inferred.exists(fn.name))
				publish(owners.get(fn.name), fn.name,
					TFunction([for (argument in fn.arguments) argument.type], fn.result, []));
		for (classDecl in build.typedNew.classes)
			for (field in classDecl.fields)
				if (inferred.exists(classDecl.name + "." + field.name))
					publish(owners.get(classDecl.name + ".new"), classDecl.name + "." + field.name, field.type);
		if (!context.options.checkReuse || changed.length == 0)
			return;
		for (change in changed)
			for (module in build.names) {
				var state = context.state.modules.get(module);
				if (state == null)
					continue;
				for (owner => dependencies in state.semanticDependencies)
					for (dependency in dependencies)
						if (dependency.kind == SemanticDependencyKind.DeclarationType
							&& dependency.target == change.declaration
							&& !build.typedByName.exists(owner)
							&& !build.typedUnits.exists(owner))
							throw new InternalError('--check-reuse: "${change.declaration}" changed type from ${change.before} to ${change.after}, '
								+ 'but "$owner", which read it, kept the body typed against the old one');
			}
	}

	/**
	 * The signatures of the unannotated functions of the build's modules that earlier builds typed (`ModuleState.inferredSignatures`):
	 * the typer gives them to the functions it does not type again.
	 */
	static function previousSignatures(context:CompilationContext,
			names:Array<String>):Map<String, compiler.types.DeclarationTypes.InferredSignature> {
		var result:Map<String, compiler.types.DeclarationTypes.InferredSignature> = [];
		for (name in names) {
			var state = context.state.modules.get(name);
			if (state != null)
				for (key => signature in state.inferredSignatures)
					result.set(key, signature);
		}
		return result;
	}

	/**
	 * Keeps the signature of each unannotated function this build typed in its module, for the next build to seed. A function this
	 * build selected but did not type (a generic one nothing read) loses its entry, which its edit may have made wrong.
	 */
	static function publishInferredSignatures(build:FrontendBuild):Void {
		var context = build.context,
			owners = build.semanticAssembly.owners,
			selected = build.semanticAssembly.selected;
		for (name in build.names) {
			var state = context.state.modules.get(name);
			if (state == null)
				continue;
			var stale = [
				for (key in state.inferredSignatures.keys())
					if (selected.exists(key) && !build.inferredSignatures.exists(key)) key
			];
			if (stale.length > 0) {
				var writable = context.state.writableState(name, build.rollbackModules);
				for (key in stale)
					writable.inferredSignatures.remove(key);
			}
		}
		for (key => signature in build.inferredSignatures) {
			var module = owners.get(key);
			if (module != null && context.state.modules.exists(module))
				context.state.writableState(module, build.rollbackModules).inferredSignatures.set(key, signature);
		}
	}

	static function publishIndex(build:FrontendBuild):Void {
		if (build.indexSemantics) {
			indexTypedInitializers(build.context, build.typedNew, build.reindexedModules);
			// An unannotated function's signature, as the table gave it, also where this build did not index its body.
			for (module in build.reindexedModules.keys()) {
				var state = build.context.state.modules.get(module);
				if (state != null)
					for (key => signature in state.inferredSignatures)
						recordInferredSignature(build.context, module, key, signature);
			}
			publishResolvedDependencies(build.context, build.typedNew, build.reindexedModules, build.rollbackModules);
		}
		build.allocationAfterIndexPublication = AllocationMeter.sample();
	}

	/** Bumps the type version of the modules typing touched, and drops each module's cached functions that no longer belong to it. */
	static function pruneCachedFunctions(build:FrontendBuild):Void {
		var context = build.context,
			modules = context.state.modules,
			names = build.names,
			owners = build.semanticAssembly.owners;
		var functionNamesByModule:Map<String, Array<String>> = [];
		for (fn in build.semanticAssembly.functions) {
			var owner = owners.get(fn.name);
			if (owner == null)
				continue;
			var owned = functionNamesByModule.get(owner);
			if (owned == null) {
				owned = [];
				functionNamesByModule.set(owner, owned);
			}
			owned.push(fn.name);
		}
		for (module in build.touchedModules.keys())
			if (modules.exists(module))
				modules.get(module).typeVersion++;
		build.allocationBeforeModulePrune = AllocationMeter.sample();
		// Shared generated helpers have one origin, but every retained caller needs their dependencies.
		var calledGeneratedHelpers = generatedHelpersStillCalled(modules, names, build.typedByName, owners,
			build.semanticAssembly.invalidated);
		for (name in names) {
			checkCancelled(build.token);
			if (!modules.exists(name))
				continue;
			pruneModule(build, name, modules.get(name), functionNamesByModule, calledGeneratedHelpers);
		}
		pruneUnusedKeyPathHelpers(context, names, build.rollbackModules);
		build.allocationAfterModulePrune = AllocationMeter.sample();
		build.retyped = uniqueSorted(build.retyped);
		build.allocationAfterPrune = AllocationMeter.sample();
	}

	/** Drops the cached functions of one module that neither this typing nor a retained owner still accounts for. */
	static function pruneModule(build:FrontendBuild, name:String, state:ModuleState,
			functionNamesByModule:Map<String, Array<String>>, calledGeneratedHelpers:Map<String, Bool>):Void {
		var owners = build.semanticAssembly.owners,
			generatedByModule = build.semanticAssembly.generatedByModule,
			invalidated = build.semanticAssembly.invalidated,
			typedByName = build.typedByName,
			currentSpecializedOwners = build.currentSpecializedOwners;
		var ast = state.parsedAst(),
			valid:Map<String, Bool> = [];
		var ownedFunctions = functionNamesByModule.get(name);
		if (ownedFunctions != null)
			for (functionName in ownedFunctions)
				valid.set(functionName, true);
		for (cached in state.typedFunctions.keys())
			if (calledGeneratedHelpers.exists(cached)) {
				valid.set(cached, true);
				owners.set(cached, name);
			}
		if (generatedByModule.exists(name)) {
			var lambdaNames = generatedByModule.get(name);
			for (lambdaName in lambdaNames.keys())
				// Syntax names do not include capture hashes. If the owner was retyped, only the closures actually
				// produced by that typing can survive; a formerly capture-free closure may now have another name.
				if (!LambdaName.is(lambdaName)
					|| !typedByName.exists(LambdaName.outermost(lambdaName))
					|| typedByName.exists(lambdaName))
					valid.set(lambdaName, true);
		}
		// An unchanged caller can retain a call to a generated specialization.
		// Such bodies are absent from this request's typedNew, but must survive
		// pruning as long as their source origin still exists and is unchanged.
		// "Unchanged" means not semantically invalidated: an origin that is only re-selected because
		// another function in its module changed is retyped, but the callers that were not retyped
		// never request its specializations again, so the cached bodies must stay.
		var retainedSpecializations:Map<String, Bool> = [];
		var hasRetainedSpecializations = false;
		for (cached => fn in state.typedFunctions) {
			var origin = fn.origin;
			// A lambda or adapter made inside a specialization names that specialization as its origin. When the
			// specialization was typed again in this request, its old lambdas that were not made again belong to the
			// earlier typing (an edit moved them, so they are named by another offset) and must not outlive it.
			var supersededByRetyping = origin != null && typedByName.exists(origin) && !typedByName.exists(cached);
			var initializedClass = origin == null ? null : compiler.semantic.InitializerUnit.ownerClass(origin);
			var sourceOwner = initializedClass != null
				&& owners.exists(initializedClass + ".new") ? initializedClass + ".new" : origin;
			// Shared helpers may move to another requesting module. Keep only the fresh owner's copy,
			// otherwise assembling cached bodies can resurrect the previous owner's stale IR.
			var supersededOwner = typedByName.exists(cached) && owners.get(cached) != name;
			// Even when the generic origin is unchanged, a specialization can depend on a changed type's
			// representation. Its cached body and optional-value helpers are no longer valid in that case.
			if (sourceOwner != null && owners.exists(sourceOwner) && !invalidated.exists(sourceOwner)
				&& !supersededOwner
				&& !invalidated.exists(cached) && !supersededByRetyping) {
				valid.set(cached, true);
				owners.set(cached, name);
				retainedSpecializations.set(cached, true);
				hasRetainedSpecializations = true;
			}
		}
		if (hasRetainedSpecializations) {
			// Retained generated functions own further closures and adapters. Follow
			// that ownership transitively, but never revive children of a retyped body.
			var pending = [for (functionName in retainedSpecializations.keys()) functionName];
			// The functions a function owns, by owner, found once: an origin, or the function a lambda is written in
			// (`LambdaName.enclosing`). Looking for them among all the module's functions for each owner was quadratic.
			var ownedBy:Map<String, Array<String>> = [];
			function ownedFor(owner:String):Array<String> {
				var list = ownedBy.get(owner);
				if (list == null) {
					list = [];
					ownedBy.set(owner, list);
				}
				return list;
			}
			for (nested => fn in state.typedFunctions) {
				if (fn.origin != null)
					ownedFor(fn.origin).push(nested);
				var enclosing = LambdaName.is(nested) ? LambdaName.enclosing(nested) : null;
				if (enclosing != null && enclosing != fn.origin)
					ownedFor(enclosing).push(nested);
			}
			while (pending.length > 0) {
				var parent = pending.pop();
				if (typedByName.exists(parent))
					continue;
				var owned = ownedBy.get(parent);
				if (owned != null)
					for (nested in owned) {
						if (valid.exists(nested) || invalidated.exists(nested))
							continue;
						valid.set(nested, true);
						owners.set(nested, name);
						pending.push(nested);
					}
			}
		}
		if (build.lowerToIr)
			for (pending in state.pendingIrFunctions.keys())
				valid.set(pending, true);
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name),
				hasInstanceInitializer = false,
				hasConstructor = false;
			for (field in classDecl.fields)
				if (!field.isStatic && field.initializer != null)
					hasInstanceInitializer = true;
			for (method in classDecl.methods)
				if (method.name == "new")
					hasConstructor = true;
			if (hasInstanceInitializer || hasConstructor)
				valid.set(className + ".new", true);
		}
		// A specialization cannot survive the removal of its physical owner. Its nested generated
		// functions belong to that same retired body, even when its generic source method is unchanged.
		var retired:Map<String, Bool> = [];
		for (cached => fn in state.typedFunctions)
			if (fn.physicalOwner != null && !currentSpecializedOwners.exists(fn.physicalOwner))
				retired.set(cached, true);
		var foundRetired = true;
		while (foundRetired) {
			foundRetired = false;
			for (cached => fn in state.typedFunctions)
				if (!retired.exists(cached) && fn.origin != null && retired.exists(fn.origin)) {
					retired.set(cached, true);
					foundRetired = true;
				}
		}
		for (cached in retired.keys())
			valid.remove(cached);
		var removed = [for (cached in state.typedFunctions.keys()) if (!valid.exists(cached)) cached];
		if (removed.length > 0)
			removeCachedFunctions(build.context.state.writableState(name, build.rollbackModules), removed);
	}

	/** Lowers the functions an earlier check-only build typed but did not lower, when this build lowers. */
	static function generatePendingIr(build:FrontendBuild):Void {
		var context = build.context,
			modules = context.state.modules,
			generator = build.generator,
			regenerated = build.regenerated;
		if (build.lowerToIr)
			for (name in build.names) {
				if (!modules.exists(name))
					continue;
				var state = modules.get(name),
					pending = [for (functionName in state.pendingIrFunctions.keys()) functionName];
				pending.sort(Reflect.compare);
				if (pending.length > 0)
					state = context.state.writableState(name, build.rollbackModules);
				for (functionName in pending) {
					checkCancelled(build.token);
					var fn = state.typedFunctions.get(functionName);
					if (fn == null)
						throw new InternalError('Pending IR function "$functionName" has no typed function');
					state.irFunctions.set(functionName, generator.generateFunction(fn));
					if (!state.typedSourceRevisions.exists(functionName))
						throw new InternalError('Pending IR function "$functionName" has no typed source revision');
					state.irSourceRevisions.set(functionName, state.typedSourceRevisions.get(functionName));
					var version = state.irVersions.exists(functionName) ? state.irVersions.get(functionName) + 1 : 1;
					state.irVersions.set(functionName, version);
					state.pendingIrFunctions.remove(functionName);
					regenerated.push(functionName);
				}
			}
		build.regenerated = uniqueSorted(regenerated);
		build.irGenerationDoneAt = now();
	}

	/** This pass's line in `CompilationContext.frontendPassReports`. */
	static function reportPass(build:FrontendBuild):Void {
		var context = build.context;
		context.frontendPassReports.push(passReport(context.frontendPassReports.length
			+ 1, [
				stage("graph", build.frontendGraphDoneAt - build.passStartedAt,
					AllocationMeter.delta("graph", build.allocationAtStart, build.allocationAfterGraph)),
				stage("semantic-assembly", build.frontendDoneAt - build.frontendGraphDoneAt,
					AllocationMeter.delta("semantic", build.allocationAfterGraph, build.allocationAfterSemantic)),
				stage("signature-inference", build.analysisDoneAt - build.frontendDoneAt,
					AllocationMeter.delta("analysis", build.allocationAfterSemantic, build.allocationAfterAnalysis)),
				stage("typing", build.typingDoneAt - build.analysisDoneAt,
					AllocationMeter.delta("typing", build.allocationAfterAnalysis, build.allocationAfterProgramTyping)),
				stage("ir-generation", build.irGenerationDoneAt - build.typingDoneAt,
					AllocationMeter.delta("ir-generation", build.allocationAfterProgramTyping,
					AllocationMeter.sample()))
			], context.parseMs
			- build.parseMsAtStart,
			context.parseBytes
			- build.parseBytesAtStart, context.parseCount
			- build.parseCountAtStart));
	}

	/** The end of typing and lowering, and the allocation phases of the whole pass. */
	static function finishTyping(build:FrontendBuild):Void {
		build.typingLoweringDoneAt = now();
		var allocationAfterTyping = AllocationMeter.sample();
		build.allocationAfterTyping = allocationAfterTyping;
		var allocationPhases = [
			AllocationMeter.delta("graph", build.allocationAtStart, build.allocationAfterGraph),
			AllocationMeter.delta("semantic", build.allocationAfterGraph, build.allocationAfterSemantic),
			AllocationMeter.delta("typing-lowering", build.allocationAfterSemantic, allocationAfterTyping),
			AllocationMeter.delta("semantic-analysis", build.allocationAfterSemantic, build.allocationAfterAnalysis),
			AllocationMeter.delta("program-typing", build.allocationAfterAnalysis, build.allocationAfterProgramTyping),
			AllocationMeter.delta("typing-publication", build.allocationAfterProgramTyping, allocationAfterTyping),
			AllocationMeter.delta("publication-index-rebuild", build.allocationAfterProgramTyping,
				build.allocationAfterIndexRebuild),
			AllocationMeter.delta("publication-objects", build.allocationAfterIndexRebuild,
				build.allocationAfterObjects),
			AllocationMeter.delta("publication-functions", build.allocationAfterObjects,
				build.allocationAfterFunctions),
			AllocationMeter.delta("publication-index", build.allocationAfterFunctions,
				build.allocationAfterIndexPublication),
			AllocationMeter.delta("publication-prune", build.allocationAfterIndexPublication,
				build.allocationAfterPrune),
			AllocationMeter.delta("publication-prune-setup", build.allocationAfterIndexPublication,
				build.allocationBeforeModulePrune),
			AllocationMeter.delta("publication-prune-modules", build.allocationBeforeModulePrune,
				build.allocationAfterModulePrune),
			AllocationMeter.delta("publication-pending-ir", build.allocationAfterPrune, allocationAfterTyping)
		];
		for (phase in build.typerMetrics.allocationPhases)
			allocationPhases.push(phase);
		build.allocationPhases = allocationPhases;
	}

	/**
	 * The IR bodies the program is assembled from, one per cached function name, with the current file hashes in their locations.
	 */
	static function collectCachedIr(build:FrontendBuild):Void {
		var context = build.context,
			modules = context.state.modules,
			names = build.names,
			owners = build.semanticAssembly.owners;
		var cachedNames:Array<String> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var state = modules.get(moduleName);
			for (functionName in state.irFunctions.keys())
				cachedNames.push(functionName);
		}
		cachedNames.sort(Reflect.compare);
		cachedNames = uniqueSorted(cachedNames);
		build.cachedNames = cachedNames;
		// A function kept across an edit of its file names the file's old text in its locations; give it the current hashes (see IrSourceRehash).
		var currentHashes:Map<String, Int> = [for (state in modules) state.source.path => state.source.contentHash()];
		build.currentHashes = currentHashes;
		var anyEdited = false;
		for (moduleName in names) {
			var edited = modules.get(moduleName);
			if (edited != null && edited.editedSinceIrScan) {
				anyEdited = true;
				break;
			}
		}
		if (anyEdited)
			for (moduleName in names) {
				var state = modules.get(moduleName);
				if (state == null)
					continue;
				var rehashed:Map<String, IrFunction> = [];
				for (functionName => fn in state.irFunctions) {
					var replacement = compiler.ir.IrSourceRehash.of(fn, currentHashes);
					if (replacement != fn)
						rehashed.set(functionName, replacement);
				}
				if (!rehashed.keys().hasNext() && !state.editedSinceIrScan)
					continue;
				var writable = context.state.writableState(moduleName, build.rollbackModules);
				for (functionName => replacement in rehashed)
					writable.irFunctions.set(functionName, replacement);
				writable.editedSinceIrScan = false;
			}
		var cached:Array<IrFunction> = [];
		for (functionName in cachedNames) {
			if (!owners.exists(functionName))
				throw new InternalError('Cached function "$functionName" has no source owner');
			var owner = owners.get(functionName);
			if (!modules.exists(owner))
				throw new InternalError('Cached function "$functionName" has no source module');
			var functions = modules.get(owner).irFunctions;
			if (!functions.exists(functionName))
				throw new InternalError('Cached function "$functionName" has no IR body');
			cached.push(functions.get(functionName));
		}
		build.cached = cached;
		if (context.options.checkReuse)
			for (functionName in cachedNames) {
				var holder = modules.get(owners.get(functionName));
				if (holder == null)
					throw new InternalError('--check-reuse: cached function "$functionName" has no owning module');
				var held = holder.irFunctions.get(functionName);
				if (compiler.ir.IrSourceRehash.of(held, currentHashes) != held)
					throw new InternalError('--check-reuse: cached function "$functionName" of module "${owners.get(functionName)}" names a file hash that is not the file\'s current one');
			}
		dropUnusedKeyPathFields(build.typedNew, cached);
	}

	/**
	 * Whether this compile prints anonymous structures through generated `__string` methods (IrProgramAssembler.anonymousStringsFrom):
	 * when it has the `__std_string` intrinsic that string conversion lowers to, as every compile configured with the compiler's
	 * intrinsics does.
	 */
	static function printsStructures(context:CompilationContext):Bool
		return context.natives.signatures().exists("__std_string");

	/** The declaration tables, natives and initializers the IR pipeline assembles the program from. */
	static function assembleTables(build:FrontendBuild):Void {
		var context = build.context,
			generator = build.generator,
			typedNew = build.typedNew;
		var resolvedObjects = resolvedObjectsFrom(context.state.objectCache, typedNew,
			functionNamesOf(build.cachedNames, typedNew));
		var objectNames = [for (name in resolvedObjects.keys()) name];
		objectNames.sort(Reflect.compare);
		var irNatives = context.natives.irNatives();
		for (native in IrProgramAssembler.nativesFrom(generator, typedNew)) {
			for (existing in irNatives)
				if (existing.name == native.name)
					throw new InternalError('Native "${native.name}" is declared more than once');
			irNatives.push(native);
		}
		build.irNatives = irNatives;
		var instrumentScope = context.instrumentScope();
		build.instrumentScope = instrumentScope;
		if (instrumentScope != null)
			for (native in compiler.ir.IrInstrumentation.natives())
				if (![for (existing in irNatives) existing.name].contains(native.name))
					irNatives.push(native);
		var irCNatives = context.ffi.cNatives();
		for (native in IrProgramAssembler.cNativesFrom(generator, typedNew))
			if (![for (existing in irCNatives) existing.name].contains(native.name))
				irCNatives.push(native);
		build.irCNatives = irCNatives;
		// A live HashLink build initializes the fields it adds to running objects (see `IrProgramAssembler.liveInitializersFrom`).
		var hashLink = context.state.backend.hashLink(),
			published = hashLink == null ? null : hashLink.assembler,
			liveInitializers = context.livePatching
				&& !context.isWasmTarget()
				&& published != null
				&& published.isPublished() ? IrProgramAssembler.liveInitializersFrom(generator, typedNew,
				name -> published.publishedObject(name),
				(name, field) -> published.publishedField(name, field)) : [];
		var currentHashes = build.currentHashes;
		build.objects = [for (name in objectNames) resolvedObjects.get(name)];
		build.interfaces = IrProgramAssembler.interfacesFrom(generator, typedNew);
		build.enums = IrProgramAssembler.enumsFrom(generator, typedNew);
		build.staticFields = IrProgramAssembler.staticFieldsFrom(generator, typedNew);
		var generationWarnings:Array<compiler.core.Diagnostic> = [];
		build.initializers = [
			for (fn in IrProgramAssembler.staticInitializersFrom(generator, typedNew, build.initializationClasses,
				build.cached, generationWarnings))
				compiler.ir.IrSourceRehash.of(fn, currentHashes)
		].concat(liveInitializers);
		TypingWarnings.publishGeneration(context, build.names, generationWarnings, build.rollbackModules);
		// The printers made with the objects (`context.state.anonymousStrings`), for every structure the program has.
		if (printsStructures(context)) {
			var printers = context.state.anonymousStrings;
			// Every object whose `__string` objectsFrom pointed at a generated printer.
			for (object in build.objects)
				for (method in object.methods)
					if (method.name == "__string"
						&& method.functionName.name == IrProgramAssembler.anonymousStringName(object.name)) {
						var printer = printers.get(method.functionName.name);
						if (printer == null)
							throw new InternalError('Anonymous structure "${object.name}" has no generated __string');
						build.cached.push(printer);
					}
		}
		build.reflectable = IrProgramAssembler.reflectableObjectsFrom(typedNew);
	}

	/**
	 * The final IR: assembled and run through `IrPipeline.target`, or the last build's when every pipeline input is equal (see
	 * `PipelineSnapshot`).
	 */
	static function runIrPipeline(build:FrontendBuild):Void {
		var context = build.context,
			generator = build.generator,
			cached = build.cached,
			irNatives = build.irNatives,
			irCNatives = build.irCNatives,
			objects = build.objects,
			entryPoint = build.semanticAssembly.entryPoint;
		// A plain build whose pipeline inputs equal the last build's gets that build's final IR: no pass runs. With `--check-reuse`
		// the passes run anyway and the result is compared with the reused one.
		var inputs = pipelineInputs(context, generator, build.instrumentScope, cached, build.initializers, irNatives,
			irCNatives, objects,
			build.interfaces, build.enums, build.staticFields, entryPoint, build.reflectable),
			previousPipeline = context.state.pipelineSnapshot,
			reuseMiss = context.livePatching ? "live patching" : previousPipeline == null
				? "no earlier build" : previousPipeline.mismatch(inputs),
			matchesPrevious = reuseMiss == null,
			checkingReuse = context.options.checkReuse,
			reusedPipeline:Null<PipelineSnapshot> = matchesPrevious ? previousPipeline : null,
			ir:IrProgram,
			inlinerChanged:Array<String>;
		build.reuseMiss = reuseMiss;
		build.matchesPrevious = matchesPrevious;
		build.checkingReuse = checkingReuse;
		build.reusedPipeline = reusedPipeline;
		if (reusedPipeline != null && !checkingReuse) {
			ir = reusedPipeline.ir;
			inlinerChanged = [];
		} else {
			var canonicalObjectCache = context.state.canonicalObjectCache;
			var meter = new compiler.core.IrPassMeter();
			ir = IrProgramAssembler.assemble(generator, cached, irNatives, objects, build.interfaces,
				build.enums, build.staticFields,
				build.initializers, entryPoint, irCNatives, build.reflectable,
				context.state.inlineCache.staticChecks, context.valueArrayTarget(),
				context.exportedFunctions(), !context.livePatching && !context.isWasmTarget()
				&& context.options.earlyPrune, [for (object in objects) {
					if (object.isValue && object.nativeLayout != null) {
						var canonical = canonicalObjectCache.get(object.name);
						if (canonical == null)
							throw new InternalError('Missing canonical layout for "${object.name}"');
						canonical;
					} else object;
				}], context.options, meter);
			var cNativeNames = [for (native in irCNatives) native.name].join(","),
				ownPrints:Map<String, String> = [];
			for (fn in cached)
				if (PositionalName.is(fn.name))
					ownPrints.set(fn.name, context.state.inlineCache.positionalFingerprint(fn, cNativeNames));
			context.state.inlineCache.finishPositionalFingerprints();
			ir.positionalFingerprints = PositionalName.nested(ownPrints);
			if (context.livePatching) {
				var texts:Map<String, String> =
					[for (state in context.state.modules) state.source.path => state.source.text];
				for (fn in cached)
					if (PositionalName.is(fn.name)) {
						var place = PositionalName.placeOf(fn),
							parsed = PositionalName.parsePlace(place);
						if (place == null || parsed == null || !texts.exists(parsed.path))
							continue;
						ir.positionalPlaces.set(fn.name, place);
						ir.positionalSources.set(parsed.path, texts.get(parsed.path));
					}
			}
			var semantic = context.state.semanticProgram;
			if (context.livePatching && !context.isWasmTarget() && semantic != null)
				ir.parameterDefaults = parameterDefaults(ir, semantic.signatures);
			// The passes and their order are `IrPipeline.target`, from the closed enum tag ABI to the frontend verifier.
			var passes = new compiler.ir.IrPipelineContext(context.targetProfile(), context.valueArrayTarget());
			passes.livePatching = context.livePatching;
			passes.developmentMetadata = context.developmentMetadata;
			passes.reflectable = build.reflectable;
			passes.inlineCache = context.state.inlineCache;
			passes.options = context.options;
			passes.meter = meter;
			passes.instrumentScope = build.instrumentScope;
			passes.verifyMemo = context.state.verifyMemo;
			ir = compiler.ir.IrPipeline.target.run(ir, passes);
			for (entry in meter.entries())
				context.irPassAllocations.push(entry);
			inlinerChanged = passes.inlinerChanged;
			if (reusedPipeline != null) {
				var difference = PipelineSnapshot.irDifference(reusedPipeline.ir, ir);
				if (difference != null)
					throw new InternalError('--check-reuse: the final IR reused for equal pipeline inputs differs from a fresh run ($difference)');
			}
			// The prune ran early: after the last pass nothing may call what it removed (`IrEntryPrune`).
			if (checkingReuse)
				compiler.ir.IrEntryPrune.checkRemoved("the pipeline", ir.functions, ir.prunedFunctions);
			context.state.pipelineSnapshot = context.livePatching ? null : new PipelineSnapshot(inputs, ir);
		}
		build.ir = ir;
		build.inlinerChanged = inlinerChanged;
	}

	/**
	 * Regenerating a function's IR does not change it when the typed function is the same: a semantic invalidation regenerates every
	 * function of a module whose declarations moved. Only functions whose final IR differs from the published one, or that were typed
	 * again, need lowering and patching; the rest keep their lowered form.
	 */
	static function selectChangedFunctions(build:FrontendBuild):Void {
		var inlinerChanged = build.inlinerChanged;
		var changedIr:Map<String, Bool> = [for (name in inlinerChanged) name => true],
			retypedNow:Map<String, Bool> = [for (name in build.retyped) name => true],
			present:Map<String, Bool> = [for (fn in build.ir.functions) fn.name => true];
		var regenerated = [
			for (name in build.regenerated)
				if (!present.exists(name) || changedIr.exists(name) || retypedNow.exists(name)) name
		];
		var listed:Map<String, Bool> = [for (name in regenerated) name => true];
		for (name in inlinerChanged)
			if (!listed.exists(name)) {
				listed.set(name, true);
				regenerated.push(name);
			}
		regenerated.sort(Reflect.compare);
		build.regenerated = regenerated;
		build.relocated = build.matchesPrevious
			&& !build.checkingReuse
			? [] : [for (name in build.context.state.inlineCache.relocated) if (!listed.exists(name)) name];
	}

	static function result(build:FrontendBuild, ir:Null<IrProgram>, relocated:Array<String>, irAssemblyDoneAt:Float,
			reused:Null<PipelineSnapshot>, reuseMiss:Null<String>):FrontendResult {
		var context = build.context,
			semanticAssembly = build.semanticAssembly;
		return {
			ir: ir,
			moduleNames: build.names,
			typedProgram: build.typedNew,
			retyped: build.retyped,
			invalidations: semanticAssembly.invalidations,
			regenerated: build.regenerated,
			relocated: relocated,
			typerMetrics: build.typerMetrics,
			frontendGraphDoneAt: build.frontendGraphDoneAt,
			semanticAliasMs: semanticAssembly.aliasSetupMs,
			semanticCanonicalizationMs: semanticAssembly.canonicalizationMs,
			semanticContributionReuseMs: semanticAssembly.contributionReuseMs,
			semanticContributionRebuildMs: semanticAssembly.contributionRebuildMs,
			semanticInvalidationMs: semanticAssembly.invalidationMs,
			semanticAllocatedBytes: semanticAssembly.allocatedBytes,
			graphParseMs: build.graphParseMs,
			graphDependencyMs: build.graphDependencyMs,
			graphInitializationMs: build.graphInitializationMs,
			frontendRestarts: context.frontendRestarts,
			frontendPassFunctions: context.frontendPassFunctions,
			frontendPassReports: context.frontendPassReports,
			irPassAllocations: context.irPassAllocations,
			frontendDoneAt: build.frontendDoneAt,
			analysisMs: build.analysisDoneAt - build.frontendDoneAt,
			irGenerationMs: build.irGenerationDoneAt - build.typingDoneAt,
			typingLoweringDoneAt: build.typingLoweringDoneAt,
			irAssemblyDoneAt: irAssemblyDoneAt,
			allocationPhases: build.allocationPhases,
			reused: reused,
			reuseMiss: reuseMiss
		};
	}

	/** Everything the IR pipeline reads for this build (see `PipelineInputs`). */
	static function pipelineInputs(context:CompilationContext, generator:IrGenerator,
			instrumentScope:Null<compiler.ir.IrInstrumentation.IrInstrumentationScope>, functions:Array<IrFunction>,
			initializers:Array<IrFunction>,
			natives:Array<compiler.ir.Ir.IrNative>, cNatives:Array<compiler.ir.Ir.IrCNative>, objects:Array<IrObject>,
			interfaces:Array<compiler.ir.Ir.IrInterface>, enums:Array<compiler.ir.Ir.IrEnum>,
			staticFields:Array<compiler.ir.Ir.IrStaticField>,
			entryPoint:Null<String>, reflectable:Null<Array<String>>):PipelineInputs {
		var objectNames:Map<String, Bool> = [for (object in objects) object.name => true];
		var tables = new IrProgram(entryPoint == null ? "" : entryPoint);
		tables.natives = natives;
		tables.cNatives = cNatives;
		tables.objects = objects;
		tables.interfaces = interfaces;
		tables.enums = enums;
		tables.staticFields = staticFields;
		var environment = [
			"defines:" + context.definesKey(),
			"target:" + Std.string(context.valueArrayTarget()),
			"wasm:" + context.isWasmTarget(),
			"live:" + context.livePatching,
			"development:" + context.developmentMetadata,
			"options:" + context.options.key(),
			"instrument:" + (instrumentScope == null ? "-" : Std.string(instrumentScope)),
			"exports:" + context.exportedFunctions().join(","),
			// Reflection ignores a name that has no object (a typed program can list an empty anonymous type no function uses), and no
			// pass gives such a name an object later.
			"reflectable:"
				+ (reflectable == null
				? "-" : [for (name in reflectable) if (objectNames.exists(name)) name].join(";")),
			"entry:" + entryPoint,
			"generator:" + generator.facts.inputState(generator.profile)
		].join("\n");
		return {
			functions: functions,
			initializers: initializers,
			tables: compiler.ir.codec.CanonicalIrCodec.encodeTables(tables),
			environment: environment
		};
	}

	/**
	 * The modules whose presence changes how types are represented are part of every program that can have them, so no body is
	 * ever typed without one (see `RuntimeDependencyTracker.changesRepresentation`). Today that is the specialized map owner's
	 * `RuntimeType.SPECIALIZED_MAP`: two functions in a program that has no use for it. A program without a stdlib root has no such
	 * module and cannot make a specialized map either.
	 */
	static function seedRepresentationModules(context:CompilationContext):Void {
		var module = context.moduleAnalyzer.loadSourceModuleDependency(compiler.runtime.RuntimeType.SPECIALIZED_MAP);
		if (module != null && context.rootModules.indexOf(module) < 0)
			context.rootModules.push(module);
	}

	static function removeCachedFunctions(state:ModuleState, names:Array<String>):Void
		for (cached in names) {
			state.typedFunctions.remove(cached);
			state.typedSourceRevisions.remove(cached);
			state.purityQueries.remove(cached);
			state.noReturnQueries.remove(cached);
			state.keyPathUses.remove(cached);
			state.defaultArgumentSources.remove(cached);
			state.pendingIrFunctions.remove(cached);
			state.irFunctions.remove(cached);
			state.irSourceRevisions.remove(cached);
			state.irVersions.remove(cached);
		}

	/**
	 * A key path literal helper, and the read and write accessors made with it, stay only while a function that stays in the
	 * program uses the literal. The helper is shared and recorded under one origin (the root's constructor), so the origin alone
	 * would keep it after its last user is edited away or removed.
	 */
	static function pruneUnusedKeyPathHelpers(context:CompilationContext, names:Array<String>,
			rollbackModules:Map<String, ModuleState>):Void {
		var used:Map<String, Bool> = [];
		for (name in names) {
			var state = context.state.modules.get(name);
			if (state != null)
				for (literals in state.keyPathUses)
					for (literal in literals.keys())
						used.set(literal, true);
		}
		for (name in names) {
			var state = context.state.modules.get(name);
			if (state == null)
				continue;
			var unused = [
				for (cached in state.typedFunctions.keys())
					if (StringTools.startsWith(cached, compiler.types.typing.KeyPathTyping.LITERAL_PREFIX)
					&& !used.exists(keyPathLiteralOf(cached))) cached
			];
			if (unused.length > 0)
				removeCachedFunctions(context.state.writableState(name, rollbackModules), unused);
		}
	}

	/** The literal a helper belongs to: a literal's own name ends in its access kind, an accessor adds one more (`:read` or `:write`). */
	static function keyPathLiteralOf(helper:String):String {
		var accessor = StringTools.endsWith(helper, ":read") || StringTools.endsWith(helper, ":write");
		if (!accessor)
			return helper;
		var base = helper.substr(0, helper.lastIndexOf(":"));
		return StringTools.endsWith(base, ":read") || StringTools.endsWith(base, ":write") ? base : helper;
	}

	static function uniqueSorted(names:Array<String>):Array<String> {
		names.sort(Reflect.compare);
		var result:Array<String> = [];
		for (name in names)
			if (result.length == 0 || result[result.length - 1] != name)
				result.push(name);
		return result;
	}

	/**
	 * What unchanged cached functions, and the generated functions they call, still take from the previous typed program:
	 * generic owners and the other generated classes (no source declares them) they refer to, and the static fields they read.
	 */
	static function retainedFromPrevious(context:CompilationContext, modules:Array<String>, selected:Map<String, Bool>,
			lowerToIr:Bool,
			declared:Map<String, Bool>, previousSemantic:Null<SemanticProgram>):Null<RetainedFromPrevious> {
		var result:Map<String, Bool> = [],
			retainedEnums:Map<String, Bool> = [],
			previous = context.state.lastTypedProgram;
		if (previous == null)
			return null;
		// A source declaration removed by this edit is not a generated class, even though it is absent from the new program.
		if (previousSemantic == null)
			throw new InternalError("Internal error: previous typed program has no semantic program");
		var previouslyDeclared:Map<String, Bool> = [for (entry in previousSemantic.program.classes) entry.name => true];
		var known:Map<String, Bool> = [
			for (entry in previous.classes)
				if (entry.specializationOrigin != null
				|| (!declared.exists(entry.name) && !previouslyDeclared.exists(entry.name))) entry.name => true
		],
			knownEnums:Map<String, Bool> = [
				for (entry in previous.enums)
					if (entry.specializationOrigin != null) entry.name => true
			];
		if (!known.keys().hasNext() && !knownEnums.keys().hasNext())
			return {
				program: previous,
				classes: result,
				enums: retainedEnums
			};
		// A type-only request has no complete IR graph to inspect.
		if (!lowerToIr)
			return {
				program: previous,
				classes: known,
				enums: knownEnums
			};
		var functions:Map<String, IrFunction> = [],
			physicalMethods:Map<String, String> = [];
		for (module in modules) {
			var state = context.state.modules.get(module);
			if (state == null)
				continue;
			for (name => fn in state.irFunctions)
				functions.set(name, fn);
			for (name => fn in state.typedFunctions)
				if (fn.physicalOwner != null)
					physicalMethods.set(name, fn.physicalOwner);
		}
		// Every function that stays in the program counts, not only those a source function reaches: later IR passes rewrite
		// the cached bodies (a call to a key path helper is inlined into its callers), so the helpers and generated bodies
		// left behind are the ones that still name the classes and static fields they need. The methods of a generated class
		// and the helpers of an enum specialization are the exception: they name their own type, so they count only once
		// something else retains it.
		var membersByOwner:Map<String, Array<String>> = [],
			membersByEnum:Map<String, Array<String>> = [],
			enumsByHash:Map<String, String> = [];
		function addMember(table:Map<String, Array<String>>, owner:String, member:String):Void {
			var members = table.get(owner);
			if (members == null) {
				members = [];
				table.set(owner, members);
			}
			members.push(member);
		}
		for (name in knownEnums.keys()) {
			var hash = EnumRuntimeType.specializationHash(name);
			if (hash != null)
				enumsByHash.set(hash, name);
		}
		var pending:Array<String> = [];
		for (name in functions.keys()) {
			if (selected.exists(name))
				continue;
			var owner = physicalMethods.get(name),
				helperHash = EnumRuntimeType.helperHash(name),
				helperOf = helperHash == null ? null : enumsByHash.get(helperHash);
			if (owner != null)
				addMember(membersByOwner, owner, name);
			else if (helperOf != null)
				addMember(membersByEnum, helperOf, name);
			else
				pending.push(name);
		}
		function retain(className:String):Void {
			if (result.exists(className))
				return;
			result.set(className, true);
			var members = membersByOwner.get(className);
			if (members != null)
				for (member in members)
					pending.push(member);
		}
		function retainEnum(enumName:String):Void {
			if (retainedEnums.exists(enumName))
				return;
			retainedEnums.set(enumName, true);
			var members = membersByEnum.get(enumName);
			if (members != null)
				for (member in members)
					pending.push(member);
		}
		function visitType(type:IrType):Void {
			switch type {
				case Obj(name):
					if (known.exists(name))
						retain(name);
				case Enum(name):
					if (knownEnums.exists(name))
						retainEnum(name);
				case Array(element), Iterator(element), Nullable(element):
					visitType(element);
				case Function(arguments, value):
					for (argument in arguments)
						visitType(argument);
					visitType(value);
				default:
			}
		}
		while (pending.length > 0) {
			var name = pending.pop(), fn = functions.get(name);
			if (fn == null)
				throw new InternalError('Missing function $name during inline enum reflection reachability');
			for (argument in fn.arguments)
				visitType(argument.type);
			visitType(fn.result);
			for (block in fn.blocks)
				for (located in block.instructions) {
					var instruction = located.value,
						output = compiler.ir.IrOperands.output(instruction);
					if (output != null)
						visitType(output.type);
					for (input in compiler.ir.IrOperands.inputs(instruction))
						visitType(input.type);
					switch instruction {
						case TypeValue(_, type):
							visitType(type);
						case GlobalGet(_, field), GlobalSet(field, _):
							var separator = field.lastIndexOf(".");
							if (separator > 0 && known.exists(field.substr(0, separator)))
								retain(field.substr(0, separator));
						default:
					}
				}
		}
		return {
			program: previous,
			classes: result,
			enums: retainedEnums
		};
	}

	/**
	 * A key path cache holds one static field for each key path literal that is in the program. Which literals stay is known
	 * only once the unused helpers are pruned, so the fields are settled here and a cache carried from the previous program
	 * does not keep a field for a path nothing reads any more.
	 */
	static function dropUnusedKeyPathFields(typed:TypedProgram, functions:Array<IrFunction>):Void {
		var read:Map<String, Bool> = [];
		for (fn in functions)
			if (StringTools.startsWith(fn.name, compiler.types.typing.KeyPathTyping.LITERAL_PREFIX))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case GlobalGet(_, field):
								read.set(field, true);
							default:
						}
		var kept:Array<compiler.types.TypedAst.TypedClass> = [];
		for (entry in typed.classes) {
			if (entry.name.indexOf(".$keypaths$") < 0) {
				kept.push(entry);
				continue;
			}
			var fields = [
				for (field in entry.fields)
					if (!field.isStatic || read.exists(entry.name + "." + field.name)) field
			];
			if (fields.length == 0)
				continue;
			kept.push(fields.length == entry.fields.length ? entry : {
				name: entry.name,
				genericParameters: entry.genericParameters,
				isValue: entry.isValue,
				isFlat: entry.isFlat,
				isPortable: entry.isPortable,
				isNativeValue: entry.isNativeValue,
				nativeLayouts: entry.nativeLayouts,
				base: entry.base,
				interfaces: entry.interfaces,
				fields: fields,
				methods: entry.methods,
				span: entry.span
			});
		}
		typed.classes.splice(0, typed.classes.length);
		for (entry in kept)
			typed.classes.push(entry);
	}

	/** Body-only semantic reuse keeps every previous declaration, so it is valid only for an identical declaration set. */
	/**
	 * Cached equality and wire helpers still called by retained helpers, directly or transitively.
	 * A shared helper has only one recorded origin. When that origin is edited or stops requesting the helper,
	 * pruning by origin or source-module reachability alone would drop a dependency of another retained helper and
	 * the next verification fails on the unknown call. A helper is kept on its own when it was typed again in this
	 * build or its origin is unchanged. Required helper owners join the artifact assembly/pruning set even when
	 * their source module is no longer reachable; unrelated functions in that module are still pruned.
	 */
	/** The names of the helpers the typer generates, by what they implement (equality, hash, enum methods, flags, raw values, key paths). */
	static final helperPrefixes = [
		compiler.types.typing.ValueEqualityGenerator.PREFIX,
		compiler.types.typing.EnumEqualityGenerator.EQUALS_PREFIX,
		compiler.types.typing.EnumEqualityGenerator.REFLECTIVE_PREFIX,
		compiler.types.typing.HashGenerator.HASH_PREFIX,
		compiler.types.typing.EnumConformanceMethods.PREFIX,
		compiler.types.typing.FlagsGenerator.PREFIX,
		compiler.types.typing.RawRepresentableGenerator.PREFIX,
		compiler.types.typing.KeyPathTyping.HELPER_PREFIX
	];

	/**
	 * Check mode, at publication: every call of a generated helper in a function of the program names a function the program holds. A helper dropped with
	 * its first requester while another function still calls it would otherwise surface as an unknown call when the IR is verified, or not at all.
	 */
	static function checkHelperCalls(modules:Map<String, compiler.modules.ModuleState>, names:Array<String>):Void {
		var held:Map<String, Bool> = [];
		for (name in names) {
			var state = modules.get(name);
			if (state != null) {
				// An analysis (no IR) holds typed functions only; a build holds both.
				for (cached in state.typedFunctions.keys())
					held.set(cached, true);
				for (cached in state.irFunctions.keys())
					held.set(cached, true);
			}
		}
		for (name in names) {
			var state = modules.get(name);
			if (state == null)
				continue;
			for (cached => body in state.irFunctions) {
				// An analysis retypes a function without lowering it again: until it is, the body kept is the old one, which is not the program.
				if (state.pendingIrFunctions.exists(cached))
					continue;
				for (block in body.blocks)
					for (instruction in block.instructions)
						switch instruction.value {
							case Call(_, callee, _) if (!held.exists(callee.name)):
								for (prefix in helperPrefixes)
									if (StringTools.startsWith(callee.name, prefix))
										throw new InternalError('generated helper "$callee" is called by "$cached" but the program holds no such function');
							default:
						}
			}
		}
	}

	static function generatedHelpersStillCalled(modules:Map<String, compiler.modules.ModuleState>, names:Array<String>,
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction>, owners:Map<String, String>,
			invalidated:Map<String, Bool>):Map<String, Bool> {
		var reachable = [for (name in names) name => true];
		var holders:Map<String, compiler.modules.ModuleState> = [],
			kept:Map<String, Bool> = [],
			pending:Array<String> = [];
		for (name => state in modules) {
			for (cached => fn in state.typedFunctions) {
				var shared = switch fn.role {
					case ProviderFunction(_,
						operation): compiler.core.Provides.ProviderOperations.sharedAcrossModules(operation);
					default: false;
				};
				if (!shared)
					continue;
				if (!holders.exists(cached) || reachable.exists(name))
					holders.set(cached, state);
				var origin = fn.origin;
				if (reachable.exists(name)
					&& (typedByName.exists(cached)
					|| (origin != null && owners.exists(origin) && !invalidated.exists(origin)))) {
					kept.set(cached, true);
					pending.push(cached);
				}
			}
		}
		var result:Map<String, Bool> = [];
		// A function that stays and was not typed again calls its helpers by name, whoever the helpers were made for: the helper stays
		// while any such caller does. Only the helpers a retyped function requested were made again.
		for (name => state in modules) {
			if (!reachable.exists(name))
				continue;
			for (cached => body in state.irFunctions) {
				if (!owners.exists(cached) || typedByName.exists(cached))
					continue;
				for (block in body.blocks)
					for (instruction in block.instructions)
						switch instruction.value {
							case Call(_, callee,
								_) if (holders.exists(callee.name) && !invalidated.exists(callee.name)):
								result.set(callee.name, true);
								var dependencyOwner = holders.get(callee.name).name;
								if (!reachable.exists(dependencyOwner)) {
									reachable.set(dependencyOwner, true);
									names.push(dependencyOwner);
								}
								if (!kept.exists(callee.name)) {
									kept.set(callee.name, true);
									pending.push(callee.name);
								}
							default:
						}
			}
		}
		while (pending.length > 0) {
			var current = pending.pop(), holder = holders.get(current);
			if (holder == null)
				continue;
			var body = holder.irFunctions.get(current);
			if (body == null)
				continue;
			for (block in body.blocks)
				for (instruction in block.instructions)
					switch instruction.value {
						case Call(_, callee, _) if (holders.exists(callee.name)):
							result.set(callee.name, true);
							var dependencyOwner = holders.get(callee.name).name;
							if (!reachable.exists(dependencyOwner)) {
								reachable.set(dependencyOwner, true);
								names.push(dependencyOwner);
							}
							if (!kept.exists(callee.name)) {
								kept.set(callee.name, true);
								pending.push(callee.name);
							}
						default:
					}
		}
		names.sort(Reflect.compare);
		return result;
	}

	static function sameDeclarations(previous:AstProgram, current:AstProgram):Bool {
		return sameNames([for (decl in previous.enums) decl.name], [for (decl in current.enums) decl.name])
			&& sameNames([for (decl in previous.enumAbstracts) decl.name],
			[for (decl in current.enumAbstracts) decl.name])
			&& sameNames([for (decl in previous.abstracts) decl.name], [for (decl in current.abstracts) decl.name])
			&& sameNames([for (decl in previous.interfaces) decl.name], [for (decl in current.interfaces) decl.name])
			&& sameNames([for (decl in previous.classes) decl.name], [for (decl in current.classes) decl.name])
			&& sameNames([for (decl in previous.functions) decl.name], [for (decl in current.functions) decl.name])
			&& sameNames([for (decl in previous.aliases) decl.name], [for (decl in current.aliases) decl.name]);
	}

	static function sameNames(previous:Array<String>, current:Array<String>):Bool {
		if (previous.length != current.length)
			return false;
		var known = [for (name in previous) name => true];
		for (name in current)
			if (!known.exists(name))
				return false;
		return true;
	}

	/**
	 * Cached closure and anonymous objects outlive the typing pass that produced them and are
	 * kept for when their module becomes reachable again; only objects whose layout resolves
	 * against this program's declarations are lowered.
	 */
	static function resolvedObjectsFrom(objectCache:Map<String, IrObject>, typed:TypedProgram,
			functionNames:Map<String, Bool>):Map<String, IrObject> {
		var enums = [for (decl in typed.enums) decl.name => true],
			interfaces = [for (decl in typed.interfaces) decl.name => true],
			objects = [
				for (name => object in objectCache)
					if (!isOrphanedEnvironment(name, functionNames)) name => object
			];
		var removed = true;
		while (removed) {
			removed = false;
			for (name in [for (name in objects.keys()) name]) {
				var object = objects.get(name),
					resolved = object.base == null || objects.exists(Std.string(object.base));
				for (field in object.fields)
					if (!typeResolved(field.type, objects, enums, interfaces))
						resolved = false;
				if (!resolved) {
					objects.remove(name);
					removed = true;
				}
			}
		}
		return objects;
	}

	/**
	 * The environment object of a lambda or function adapter exists for that function alone. When an edit renames the
	 * function (a lambda is named by its position among the lambdas of its body) or removes it, the old environment must go
	 * with it; anything else kept in the cache is content-named and harmless to keep.
	 */
	static function isGeneratedObjectOfRetypedFunction(name:String, retyped:Map<String, Bool>):Bool {
		for (prefix in ["$cell:", "$lambda-env:", "$function-adapter-env:"])
			if (StringTools.startsWith(name, prefix)) {
				// The owner is followed by ":" and may itself contain ":" (a lambda's name), so try every boundary.
				var rest = name.substr(prefix.length),
					colon = rest.indexOf(":");
				while (colon >= 0) {
					if (retyped.exists(rest.substr(0, colon)))
						return true;
					colon = rest.indexOf(":", colon + 1);
				}
				return false;
			}
		return false;
	}

	static function functionNamesOf(cachedNames:Array<String>, typed:TypedProgram):Map<String, Bool> {
		var names:Map<String, Bool> = [for (name in cachedNames) name => true];
		for (fn in typed.functions)
			names.set(fn.name, true);
		return names;
	}

	static function isOrphanedEnvironment(name:String, functionNames:Map<String, Bool>):Bool {
		for (pair in [["$lambda-env:", "$lambda:"], ["$function-adapter-env:", "$function-adapter:"]])
			if (StringTools.startsWith(name, pair[0]))
				return !functionNames.exists(pair[1] + name.substr(pair[0].length));
		// The environment of a key path composition is named after its functions (`<name>:get` is always made) and, like a lambda's,
		// by the place of the composition: an edit that moves it leaves the old environment with nothing to run.
		if (StringTools.startsWith(name, "$keypath.compose:") && StringTools.endsWith(name, ":environment"))
			return !functionNames.exists(name.substr(0, name.length - ":environment".length) + ":get");
		return false;
	}

	static function typeResolved(type:IrType, objects:Map<String, IrObject>, enums:Map<String, Bool>,
			interfaces:Map<String, Bool>):Bool
		return switch type {
			case Obj(name): objects.exists(name);
			case Enum(name): enums.exists(compiler.types.typing.EnumRuntimeType.declaration(name));
			case Virtual(name): interfaces.exists(name);
			case Array(element), Iterator(element): typeResolved(element, objects, enums, interfaces);
			case Function(arguments, result):
				var resolved = typeResolved(result, objects, enums, interfaces);
				for (argument in arguments)
					if (!typeResolved(argument, objects, enums, interfaces))
						resolved = false;
				resolved;
			default: true;
		};

	/** The literal defaults of the optional parameters of `ir`'s functions (`IrProgram.parameterDefaults`). */
	static function parameterDefaults(ir:IrProgram,
			signatures:Map<String, compiler.syntax.Ast.AstFunction>):Map<String, Map<String, compiler.ir.Ir.IrDefault>> {
		var result:Map<String, Map<String, compiler.ir.Ir.IrDefault>> = [];
		for (fn in ir.functions) {
			var signature = signatures.get(fn.name);
			if (signature == null)
				continue;
			var defaults:Map<String, compiler.ir.Ir.IrDefault> = [];
			for (argument in signature.arguments) {
				var value = argument.defaultValue;
				var literal:Null<compiler.ir.Ir.IrDefault> = value == null
					? (argument.optional == true ? NullDefault : null) : switch value {
						case IntegerLiteral(number, _): IntDefault(number);
						case FloatLiteral(number, _): FloatDefault(number);
						case BoolLiteral(flag, _): BoolDefault(flag);
						case NullLiteral(_): NullDefault;
						default: null;
					};
				if (literal != null)
					defaults.set(argument.name, literal);
			}
			if (defaults.keys().hasNext())
				result.set(fn.name, defaults);
		}
		return result;
	}

	/**
	 * A lambda is retyped, kept and owned with the function it is written in, which it records as its origin; invalidation
	 * relies on that and would skip a lambda that did not. So the two must agree: a function named like a lambda is a
	 * `Lambda` with an origin, and nothing else is.
	 */
	static function checkLambdaOrigin(fn:compiler.types.TypedAst.TypedFunction):Void {
		var named = LambdaName.is(fn.name),
			kind = fn.originKind == compiler.types.TypedAst.FunctionOriginKind.Lambda;
		if (named != kind || (kind && fn.origin == null))
			throw new InternalError('Typed function "${fn.name}" disagrees about being a lambda: named like one: $named, origin kind lambda: $kind, origin: ${fn.origin}');
	}

	static function resolveFunctionModule(fn:compiler.types.TypedAst.TypedFunction, owners:Map<String, String>,
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction>, visiting:Map<String, Bool>):String {
		if (owners.exists(fn.name))
			return owners.get(fn.name);
		if (visiting.exists(fn.name))
			throw new InternalError('Cyclic generated-function ownership involving "${fn.name}"');
		visiting.set(fn.name, true);
		var origin = fn.origin;
		if (origin == null)
			throw new InternalError('No source module owns typed function "${fn.name}" (origin: ${fn.origin})');
		var module:String;
		if (owners.exists(origin))
			module = owners.get(origin);
		else if (initializerModule(origin, owners) != null)
			module = initializerModule(origin, owners);
		else if (typedByName.exists(origin))
			module = resolveFunctionModule(typedByName.get(origin), owners, typedByName, visiting);
		else
			throw new InternalError('No source module owns typed function "${fn.name}" (origin: ${fn.origin})');
		owners.set(fn.name, module);
		visiting.remove(fn.name);
		return module;
	}

	/** Field initializers are pseudo-bodies owned by the declaring class module. */
	static function initializerModule(name:String, owners:Map<String, String>):Null<String> {
		var className = compiler.semantic.InitializerUnit.ownerClass(name);
		return className == null ? null : owners.get(className + ".new");
	}

	static function stage(name:String, ms:Float, allocation:PhaseAllocation):{
		name:String,
		ms:Float,
		allocation:PhaseAllocation
	} return {
		name: name,
		ms: ms,
		allocation: allocation
	};

	/**
	 * One frontend pass as a line: for each stage its time, bytes, objects and collections (with their time), and the parsing done inside
	 * the pass (it happens in the graph and in semantic assembly, so it is shown apart rather than as a stage).
	 */
	static function passReport(number:Int, stages:Array<{name:String, ms:Float, allocation:PhaseAllocation}>,
			parseMs:Float, parseBytes:Float,
			parseCount:Float):String {
		var parts = ['pass$number'];
		for (stage in stages) {
			var a = stage.allocation;
			parts.push('${stage.name}=${Math.round(stage.ms)}ms/${Math.round(a.bytes / 1048576.0)}MB/${Math.round(a.count / 1000.0)}k/${Std.int(a.collections)}gc(${Math.round(a.markMicros / 1000.0)}ms)');
		}
		parts.push('parse-within=${Math.round(parseMs)}ms/${Math.round(parseBytes / 1048576.0)}MB/${Math.round(parseCount / 1000.0)}k');
		return parts.join(" ");
	}

	static function includeTypedRuntimeDependencies(context:CompilationContext, dependencies:Array<{
		var functionName:String;
		var target:String;
	}>,
		typedFunctions:Array<compiler.types.TypedAst.TypedFunction>, owners:Map<String, String>, names:Array<String>,
		rollbackModules:Map<String, ModuleState>):Bool {
		var typedByName:Map<String, compiler.types.TypedAst.TypedFunction> = [];
		for (fn in typedFunctions)
			typedByName.set(fn.name, fn);
		var changed = false;
		for (dependency in dependencies) {
			if (names.indexOf(dependency.target) >= 0)
				continue;
			// Only targets without native dynamic objects (Wasm) call the stdlib's class; elsewhere the dependency is unused.
			if (dependency.target == PlatformAbi.DYNAMIC_OBJECT_CLASS && !context.isWasmTarget())
				continue;
			var target = context.moduleAnalyzer.loadSourceModuleDependency(dependency.target);
			if (target == null)
				throw new InternalError('Typed runtime dependency "${dependency.target}" from "${dependency.functionName}" has no source module');
			if (names.indexOf(target) >= 0)
				continue;
			var fn = typedByName.get(dependency.functionName),
				owner:Null<String> = null;
			if (StringTools.startsWith(dependency.functionName,
				compiler.types.typing.RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX))
				owner = context.state.declarationOwners.get(dependency.functionName
					.substr(compiler.types.typing.RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX.length));
			else if (fn != null)
				owner = resolveFunctionModule(fn, owners, typedByName, []);
			else if (owners.exists(dependency.functionName))
				// Typed in an earlier build and kept: it is not among this pass's typed functions, but its module is known.
				owner = owners.get(dependency.functionName);
			else
				owner = initializerModule(dependency.functionName, owners);
			if (owner == null)
				throw new InternalError('Typed runtime dependency from unknown function "${dependency.functionName}"');
			var state = context.state.writableState(owner, rollbackModules);
			if (state.dependencies.indexOf(target) < 0) {
				context.frontendRestarts.push('${dependency.functionName} needs $target');
				state.dependencies.push(target);
				state.dependencies.sort(Reflect.compare);
				changed = true;
			}
		}
		return changed;
	}

	static function indexTypedInitializers(context:CompilationContext, typed:TypedProgram,
			reindexedModules:Map<String, Bool>):Void {
		for (classDecl in typed.classes)
			for (module in reindexedModules.keys()) {
				if (!context.state.modules.exists(module))
					continue;
				var state = context.state.modules.get(module),
					model = state.semanticModel;
				if (model == null || !modelOwnsType(model.program, classDecl.name))
					continue;
				for (field in classDecl.fields)
					if (field.initializer != null)
						model.index.indexTypedInitializer(classDecl.name + "." + field.name, field.type,
							field.initializer,
							context.state.semanticWorkspace.resolveSymbolId,
							context.state.semanticWorkspace.resolveEnumCaseId);
			}
	}

	/** Replace provisional edges with dependencies proven by typed resolution. */
	static function publishResolvedDependencies(context:CompilationContext, typed:TypedProgram,
			reindexedModules:Map<String, Bool>,
			rollbackModules:Map<String, ModuleState>):Void {
		for (module in reindexedModules.keys()) {
			var state = context.state.writableState(module, rollbackModules),
				model = state.semanticModel;
			if (model == null)
				continue;
			var resolved:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>> = [];
			for (owner => dependencies in state.semanticDependencies)
				for (dependency in dependencies)
					if (dependency.kind != SemanticDependencyKind.Body
						&& dependency.kind != SemanticDependencyKind.Initializer) {
						var targetId = dependency.targetId == null
							? context.state.semanticWorkspace.resolveTypeSymbolId(dependency.target)
							: dependency.targetId;
						SemanticDependencyCollector.addDependency(resolved, owner, dependency.kind, dependency.target,
							targetId);
					}
			for (dependency in model.index.resolvedDependencies())
				SemanticDependencyCollector.addDependency(resolved, dependency.owner, dependency.kind,
					dependency.target, dependency.targetId);
			for (name => fn in state.typedFunctions)
				if (state.typedSourceRevisions.get(name) == state.revision) {
					for (argument in fn.arguments)
						addResolvedTypeDependency(resolved, name, SemanticDependencyKind.Signature, argument.type,
							context);
					addResolvedTypeDependency(resolved, name, SemanticDependencyKind.Signature, fn.result, context);
				}
			for (classDecl in typed.classes)
				if (modelOwnsType(model.program, classDecl.name)) {
					if (classDecl.base != null)
						addResolvedNamedTypeDependency(resolved, classDecl.name, SemanticDependencyKind.Layout,
							classDecl.base, context);
					for (interfaceName in classDecl.interfaces)
						addResolvedNamedTypeDependency(resolved, classDecl.name, SemanticDependencyKind.Layout,
							interfaceName, context);
					for (field in classDecl.fields)
						addResolvedTypeDependency(resolved, classDecl.name, SemanticDependencyKind.Layout, field.type,
							context);
				}
			state.semanticDependencies = resolved;
		}
	}

	static function addResolvedTypeDependency(result:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>>,
			owner:String,
			kind:SemanticDependencyKind, type:CompilerType, context:CompilationContext):Void
		addResolvedTypeDependencyWithin(result, owner, kind, type, context, []);

	/** `explored` holds the anonymous structures already walked: one can contain itself, and a repeat adds nothing. */
	static function addResolvedTypeDependencyWithin(result:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>>,
			owner:String,
			kind:SemanticDependencyKind, type:CompilerType, context:CompilationContext,
			explored:Array<Array<compiler.types.Type.AnonymousField>>):Void
		switch type {
			case TAbstract(name, arguments, representation):
				addResolvedNamedTypeDependency(result, owner, kind, name, context);
				for (argument in arguments)
					addResolvedTypeDependencyWithin(result, owner, kind, argument, context, explored);
				addResolvedTypeDependencyWithin(result, owner, kind, representation, context, explored);
			case TInstance(_, name, arguments):
				addResolvedNamedTypeDependency(result, owner, kind, name, context);
				for (argument in arguments)
					addResolvedTypeDependencyWithin(result, owner, kind, argument, context, explored);
			case TNullable(element), TArray(element), TIterator(element):
				addResolvedTypeDependencyWithin(result, owner, kind, element, context, explored);
			case TMap(key, value):
				addResolvedTypeDependencyWithin(result, owner, kind, key, context, explored);
				addResolvedTypeDependencyWithin(result, owner, kind, value, context, explored);
			case TFunction(arguments, resultType, _):
				for (argument in arguments)
					addResolvedTypeDependencyWithin(result, owner, kind, argument, context, explored);
				addResolvedTypeDependencyWithin(result, owner, kind, resultType, context, explored);
			case TAnonymous(_, fields):
				if (explored.indexOf(fields) < 0) {
					explored.push(fields);
					for (field in fields)
						addResolvedTypeDependencyWithin(result, owner, kind, field.type, context, explored);
				}
			default:
		}

	static function addResolvedNamedTypeDependency(result:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>>,
			owner:String,
			kind:SemanticDependencyKind, target:String, context:CompilationContext):Void {
		var targetId = context.state.semanticWorkspace.resolveTypeSymbolId(target);
		if (targetId != null)
			SemanticDependencyCollector.addDependency(result, owner, kind, target, targetId);
	}

	static function modelOwnsType(program:compiler.syntax.Ast.AstProgram, name:String):Bool {
		var prefix = program.packageName == null || program.packageName.length == 0 ? "" : program.packageName + ".";
		for (classDecl in program.classes)
			if (prefix + classDecl.name == name)
				return true;
		return false;
	}
}
