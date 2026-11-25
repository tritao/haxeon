package compiler.compilation;
import compiler.ir.model.IrTypeIds;
import compiler.syntax.CanonicalComparison.PositionsCount;

import compiler.abi.PositionalName;
import compiler.compilation.PipelineSnapshot.PipelineInputs;
import compiler.core.AllocationMeter;
import compiler.core.AllocationMeter.AllocationSnapshot;
import compiler.core.AllocationMeter.PhaseAllocation;
import compiler.core.CancellationToken;
import compiler.core.Diagnostic.CompileError;
import compiler.core.InternalError;
import compiler.core.PeakProbe;
import compiler.core.PhaseCollections;
import compiler.ir.gen.IrGenerator;
import compiler.ir.model.Ir.IrCNative;
import compiler.ir.model.Ir.IrEnum;
import compiler.ir.model.Ir.IrInterface;
import compiler.ir.model.Ir.IrNative;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrStaticField;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.IrFunction;
import compiler.ir.pipeline.IrProgramAssembler;
import compiler.ir.tools.IrInstrumentation.IrInstrumentationScope;
import compiler.modules.ModuleReachability;
import compiler.modules.ModuleState;
import compiler.runtime.PlatformAbi;
import compiler.semantic.LambdaName;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.SemanticAssembly;
import compiler.semantic.SemanticAssembly.SemanticAssemblyResult;
import compiler.semantic.SemanticProgram;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstProgram;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.types.typing.EnumRuntimeType;
import compiler.types.typing.RetainedFromPrevious;
import compiler.types.typing.TypingFailure;

typedef FrontendResult = {
	final ir:Null<IrProgram>;
	final moduleNames:Array<String>;
	/**
	 * Null when a compile that keeps no session (`CompileOptions.keepSession`) has released it: once the IR tables are assembled
	 * from it, or before the backend.
	 */
	var typedProgram:Null<TypedProgram>;

	/** The typed program's native type descriptors, which outlive it. */
	final nativeTypeDescriptors:Array<compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData>;
	final retyped:Array<String>;
	final invalidations:Array<compiler.semantic.Invalidation.InvalidatedArtifact>;
	final regenerated:Array<String>;

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
	final frontendTypedFunctions:Int;
	final frontendStages:String;
	final irPassCosts:Array<compiler.core.IrPassMeter.IrPassCost>;
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
 * One frontend build: its inputs, what its phases hand to each other, and the time and allocation readings taken at the phase
 * boundaries. `FrontendCompilation.run` makes one per compile.
 */
private class FrontendBuild {
	public final context:CompilationContext;
	public final entryModule:String;
	public final token:Null<CancellationToken>;
	public final rollbackModules:Map<String, ModuleState>;
	public final lowerToIr:Bool;
	public final indexSemantics:Bool;

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
	/** Null once released (`FrontendCompilation.throughTables`); its native type descriptors are kept below. */
	public var typedNew:Null<TypedProgram>;

	/** The typed program, which the phases up to the IR tables read; an error once it is released. */
	public function typed():TypedProgram {
		var program = typedNew;
		if (program == null)
			throw new InternalError("The typed program was read after it was released");
		return program;
	}

	public var nativeTypeDescriptors:Array<compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData> = [];
	public var typerMetrics:TyperPhaseMetrics;
	public var generator:IrGenerator;
	public var runtimeDependencies:Array<{
		var functionName:String;
		var target:String;
	}>;
	public var keyPathUses:Map<String, Map<String, Bool>>;
	public var typedUnits:Map<String, Bool>;

	/** The signatures of the unannotated functions this build typed, by key, which `publishInferredSignatures` keeps. */
	public var inferredSignatures:Map<String, compiler.types.DeclarationTypes.InferredSignature> = [];

	/** What the units typed in this build read (`DeclarationReads`), which `publishUnitReads` keeps in their modules. */
	public var reads:Null<compiler.semantic.DeclarationReads>;

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

	public function new(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>, lowerToIr:Bool, indexSemantics:Bool) {
		this.context = context;
		this.entryModule = entryModule;
		this.token = token;
		this.rollbackModules = rollbackModules;
		this.lowerToIr = lowerToIr;
		this.indexSemantics = indexSemantics;
	}
}

/** What a previous IR function names that `FrontendCompilation.retainedFromPrevious` may retain: classes and enums, each once. */
typedef TypeMentions = {
	final classes:Array<String>;
	final enums:Array<String>;
}

/** Builds and validates the reachable source graph through complete IR assembly. */
class FrontendCompilation {
	/**
	 * The frontend, as a sequence of phases over one `FrontendBuild`. The graph has every module typing can call before anything is
	 * typed (`RuntimeType.programModules`, `RuntimeType.companionModules`), so the phases run once.
	 */
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>,
			snapshotDoneAt:Float, ?lowerToIr = true, ?indexSemantics = true, ?pendingBody:Map<String, Bool>,
			?pendingSignatures:Map<String, Bool>,
			?pendingStructural:Map<String, Bool>):FrontendResult {
		var tables = throughTables(context, entryModule, token, rollbackModules, lowerToIr, indexSemantics, pendingBody,
			pendingSignatures, pendingStructural);
		if (tables.result != null)
			return tables.result;
		var build = tables.build;
		if (build == null)
			throw new InternalError("The frontend ended with neither a result nor a build to lower");
		runIrPipeline(build);
		PeakProbe.mark("ir-done");
		PhaseCollections.end("ir", context.options.phaseCollections);
		selectChangedFunctions(build);
		var irAssemblyDoneAt = now();
		build.allocationPhases.push(AllocationMeter.delta("ir-assembly", build.allocationAfterTyping,
			AllocationMeter.sample()));
		return result(build, build.ir, irAssemblyDoneAt, build.reusedPipeline, build.reuseMiss);
	}

	/**
	 * The frontend up to the IR tables: a result when the compile ends there, else the build to run the IR pipeline on. It runs in
	 * a frame of its own, which is gone by the time the IR passes run: a
	 * compile that keeps no session releases the typed program here, and a dead slot of a longer-lived frame would keep it alive.
	 */
	static function throughTables(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>, lowerToIr:Bool, indexSemantics:Bool,
			pendingBody:Null<Map<String, Bool>>, pendingSignatures:Null<Map<String, Bool>>,
			pendingStructural:Null<Map<String, Bool>>):{
				result:Null<FrontendResult>,
				build:Null<FrontendBuild>
			} {
		PeakProbe.mark("frontend-start");
		seedTypedRuntimeModules(context);
		var build = new FrontendBuild(context, entryModule, token, rollbackModules, lowerToIr, indexSemantics);
		startPass(build);
		checkCancelled(token);
		resolveGraph(build, pendingBody, pendingSignatures, pendingStructural);
		assembleSemantics(build);
		typeProgram(build);
		TypingWarnings.publish(context, entryModule, build.names, build.typed(), rollbackModules);
		rebuildSemanticIndex(build, typedFieldTypes(build));
		publishObjects(build);
		publishFunctions(build);
		publishIndex(build);
		pruneCachedFunctions(build);
		generatePendingIr(build);
		reportStages(build);
		if (context.options.checkReuse)
			checkHelperCalls(build.context.state.modules, build.names);
		finishTyping(build);
		if (!lowerToIr)
			return {
				result: result(build, null, build.typingLoweringDoneAt, null, null),
				build: null
			};
		collectCachedIr(build);
		checkCancelled(token);
		PeakProbe.mark("typing-done");
		// A compile that keeps no session assembles the IR from the typed program alone; the syntax is no longer needed.
		if (!context.options.keepSession) {
			context.state.releaseSyntax();
			context.moduleAnalyzer.releaseLookupParses();
		}
		assembleTables(build);
		PeakProbe.mark("tables-done");
		// The IR is made from the tables from here on: a compile that keeps no session lets the typed program go.
		if (!context.options.keepSession) {
			build.typedNew = null;
			context.state.lastTypedProgram = null;
			context.state.releaseIncrementalRecords();
			// The reads recorded while typing hold the facts they name; only a next build's invalidation reads them.
			build.reads = null;
			var semantic = context.state.semanticProgram;
			if (semantic != null)
				semantic.declarations.bindReads(null);
			// Nothing reads the typed bodies past the tables; live patching still reads the semantic program's parameter defaults.
			build.typedByName = [];
			for (state in context.state.modules)
				state.typedFunctions = [];
			if (!context.livePatching)
				context.state.semanticProgram = null;
		}
		PhaseCollections.end("tables", context.options.phaseCollections);
		return {result: null, build: build};
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
		// What is reachable depends on the roots as much as on the entry (an analysis can add roots of its own).
		var reachabilityKey = entryModule + "\n" + context.rootModules.join("\n"),
			names:Array<String> = [],
			initializationClasses:Array<String> = [],
			cachedReachability = context.state.cachedReachability(reachabilityKey),
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
			try names = reachability.finish(token) catch (error:CompileError) {
				context.moduleAnalyzer.suggestImports(error.diagnostics);
				throw error;
			}
			var initializationStartedAt = now();
			graph.rebuild(modules);
			// Haxe's type order: modules by path, each module's classes as it declares them (`StaticInitializationOrder`).
			var initializationNames = names.copy();
			initializationNames.sort(compiler.ir.pipeline.StaticInitializationOrder.compareModules);
			for (name in initializationNames) {
				var state = modules.get(name), ast = state.parsedAst();
				for (classDecl in ast.classes)
					initializationClasses.push(ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name));
			}
			context.state.cacheReachability(reachabilityKey, names, initializationClasses);
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
			build.names, build.structuralChanged, build.indexSemantics);
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
			// What each unit typed now reads is recorded while it is typed, and published with it (`publishUnitReads`).
			var reads = new compiler.semantic.DeclarationReads(context.state.declarationFacts);
			build.reads = reads;
			semantic.declarations.bindReads(reads);
			semantic.declarations.bindSourcePackages(new compiler.SourcePackages(context.options.sourcePackages));
			build.allocationAfterAnalysis = AllocationMeter.sample();
			build.analysisDoneAt = now();
			var typedResult = Typer.typeAnalyzedMeasured(semantic, selected, context.natives.signatures(),
				semanticAssembly.entryPoint, context.state.genericSpecializations,
				context.nativeLayoutTarget(), canReuseSemantic ? context.state.lastTypedProgram : null,
				semanticAssembly.facts, build.lowerToIr || context.requireEntry,
				retainedFromPrevious(context, names, selected, semanticAssembly.invalidated, build.lowerToIr,
				[for (classDecl in canonicalProgram.classes) classDecl.name => true],
				previousSemantic), context.options.reverseTypingOrder, {
					signatures: previousSignatures(context, names),
					check: context.options.checkReuse
				}, context.options.elaborateGenerics, semanticAssembly.entrySpan, context.options.nullSafety);
			build.allocationAfterProgramTyping = AllocationMeter.sample();
			build.typingDoneAt = now();
			var typedNew = typedResult.program;
			build.typedNew = typedNew;
			build.nativeTypeDescriptors = typedNew.nativeTypeDescriptors;
			context.frontendTypedFunctions = typedNew.functions.length;
			build.generator = new IrGenerator(compiler.ir.pipeline.ProgramFacts.of(typedNew), context.targetProfile());
			build.typerMetrics = typedResult.metrics;
			var runtimeDependencies = typedResult.runtimeDependencies;
			build.runtimeDependencies = runtimeDependencies;
			build.keyPathUses = typedResult.keyPathUses;
			build.typedUnits = typedResult.typedUnits;
			build.inferredSignatures = typedResult.inferredSignatures;
			checkTypedRuntimeDependencies(context, runtimeDependencies, names);
			context.state.semanticProgram = semantic;
			semantic.declarations.bindReads(null);
		} catch (error:CompileError) {
			context.moduleAnalyzer.suggestImports(error.diagnostics);
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
		for (classDecl in build.typed().classes)
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
			typedNew = build.typed(),
			generator = build.generator,
			objectCache = context.state.objectCache,
			canonicalObjectCache = context.state.canonicalObjectCache;
		build.retyped = [];
		build.regenerated = [];
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
		keepStructureObjects(build, generator, typedObjects);
		var canonicalAbi = compiler.ir.passes.enums.IrInlineEnumLayout.CANONICAL_ABI;
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
	 * The anonymous structures' objects among `typedObjects` (`IrProgramAssembler.objectsFrom` lists them last, in the typed
	 * program's order), with their printers. An object the same as the one the cache holds is that one, and its printer is the
	 * one made from it (`SessionState.structurePrinters`), since the printer reads nothing else of the structure: its fields'
	 * names and lowered types, in order. A later build may take an object from the cache without typing its structure again, so
	 * a printer is kept as long as its object.
	 */
	static function keepStructureObjects(build:FrontendBuild, generator:IrGenerator,
			typedObjects:Array<IrObject>):Void {
		var context = build.context,
			anonymousTypes = build.typed().anonymousTypes,
			objectCache = context.state.objectCache,
			printers = printsStructures(context) ? context.state.structurePrinters : null,
			first = typedObjects.length - anonymousTypes.length;
		if (printers != null)
			printers.checks = context.options.checkReuse;
		for (index in 0...anonymousTypes.length) {
			var anonymous = anonymousTypes[index], object = typedObjects[first + index];
			if (object.name != anonymous.name)
				throw new InternalError('Anonymous structure "${anonymous.name}" has no object where objectsFrom lists it');
			var cached = objectCache.get(object.name);
			if (cached != null && compiler.ir.model.IrDeclarationEquality.sameObject(cached, object))
				typedObjects[first + index] = object = cached;
			if (printers != null)
				printers.made(IrProgramAssembler.anonymousStringName(anonymous.name), [object],
					() -> IrProgramAssembler.anonymousString(generator, anonymous));
		}
	}

	/**
	 * Each typed function into its module's state, with the dependencies and queries typing recorded for it, and lowered to IR
	 * when the build lowers.
	 */
	static function publishFunctions(build:FrontendBuild):Void {
		var context = build.context,
			token = build.token,
			rollbackModules = build.rollbackModules,
			typedNew = build.typed(),
			generator = build.generator,
			owners = build.semanticAssembly.owners,
			generatedByModule = build.semanticAssembly.generatedByModule,
			invalidated = build.semanticAssembly.invalidated,
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
		// The module each generated function was held by before this build, found when one first needs it.
		var heldBy:Null<Map<String, String>> = null;
		function previouslyHeld(name:String):Null<String> {
			var held = heldBy;
			if (held == null) {
				held = [];
				for (module => state in context.state.modules)
					for (functionName in state.irFunctions.keys())
						if (generatedFunctions.exists(functionName))
							held.set(functionName, module);
				heldBy = held;
			}
			return held.get(name);
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
				var ir = generator.generateFunction(fn),
					previous = state.pendingIrFunctions.exists(fn.name) ? null : state.irFunctions.get(fn.name),
					previousVersion = state.irVersions.exists(fn.name) ? state.irVersions.get(fn.name) : 0;
				// A helper is owned by the module of the code that asked for it first, which another build can ask from elsewhere:
				// what it had is in the module that owned it before, until pruning drops that copy.
				if (previous == null && generated && !state.irFunctions.exists(fn.name)) {
					var held = previouslyHeld(fn.name);
					var holder = held == null ? null : context.state.modules.get(held);
					if (holder != null && !holder.pendingIrFunctions.exists(fn.name)) {
						previous = holder.irFunctions.get(fn.name);
						previousVersion = holder.irVersions.exists(fn.name) ? holder.irVersions.get(fn.name) : 0;
					}
				}
				state.irSourceRevisions.set(fn.name, state.revision);
				state.pendingIrFunctions.remove(fn.name);
				// What the session keeps of the IR it had is its body alone: the new IR is compared as rows, encoded, and keeps that
				// encoding as its body, which the encode point then takes as it is.
				if (previous != null && previous.body != null)
					ir.encodedBody();
				// Typed again to the IR it already had (a helper every build types from the program's requests, an edit that changes
				// nothing the function compiles to): the function keeps that IR and its version, so nothing after it sees a change.
				if (previous != null && compiler.ir.codec.IrFunctionStateEquality.same(previous, ir)) {
					state.irFunctions.set(fn.name, previous);
					state.irVersions.set(fn.name, previousVersion);
					continue;
				}
				state.irFunctions.set(fn.name, ir);
				regenerated.push(fn.name);
				state.irVersions.set(fn.name, context.state.irVersions.next());
			} else
				state.pendingIrFunctions.set(fn.name, true);
		}
		publishUnitReads(build);
		publishDeclarationTypeDigests(build);
		publishInferredSignatures(build);
		var objectCache = context.state.objectCache;
		for (object in build.currentObjects)
			objectCache.set(object.name, object);
		build.allocationAfterFunctions = AllocationMeter.sample();
	}

	/**
	 * Records what each unit typed in this build read, as of this build's revision, with the module whose state holds it: the next
	 * build types it again only when one of those facts changed after that. The records are written in the build's transaction,
	 * which taking the build commits (`DeclarationFacts.recordUnit`).
	 */
	static function publishUnitReads(build:FrontendBuild):Void {
		var reads = build.reads;
		if (reads == null)
			return;
		var context = build.context,
			facts = context.state.declarationFacts,
			owners = build.semanticAssembly.owners;
		for (unit => read in reads.units) {
			var module = unitModule(unit, owners, build.typedByName);
			// A unit no function holds (a generic body typed for its errors alone) is read by nothing.
			if (module == null)
				continue;
			var specializations:Null<Array<Int>> = null;
			for (fact in read)
				if (facts.aspect(fact) == compiler.semantic.DeclarationFacts.FactAspect.Unit
					&& compiler.semantic.GeneratedNames.isSpecialization(facts.name(fact))) {
					if (specializations == null)
						specializations = [];
					specializations.push(fact);
				}
			facts.recordUnit(facts.id(compiler.semantic.DeclarationFacts.FactAspect.Unit, unit),
				new compiler.semantic.DeclarationFacts.UnitReads(facts.revision, read, module, specializations));
		}
	}

	/**
	 * The module whose state holds unit `unit`: its function's, the class's for a field initializer or an inline constant, and the
	 * module of the code that first asked for a specialization.
	 */
	static function unitModule(unit:String, owners:Map<String, String>,
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction>):Null<String> {
		var owner = owners.get(unit);
		if (owner != null)
			return owner;
		var typed = typedByName.get(unit);
		if (typed != null)
			return resolveFunctionModule(typed, owners, typedByName, []);
		if (StringTools.startsWith(unit, compiler.types.typing.TypingSession.INLINE_CONSTANT_PREFIX)) {
			var field = unit.substr(compiler.types.typing.TypingSession.INLINE_CONSTANT_PREFIX.length);
			return owners.get(compiler.core.QualifiedName.parentOrEmpty(field) + ".new");
		}
		return initializerModule(unit, owners);
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
		for (fn in build.typed().functions)
			if (inferred.exists(fn.name))
				publish(owners.get(fn.name), fn.name,
					TFunction([for (argument in fn.arguments) argument.type], fn.result, []));
		for (classDecl in build.typed().classes)
			for (field in classDecl.fields)
				if (inferred.exists(classDecl.name + "." + field.name))
					publish(owners.get(classDecl.name + ".new"), classDecl.name + "." + field.name, field.type);
		if (!context.options.checkReuse || changed.length == 0)
			return;
		var facts = context.state.declarationFacts, reads = build.reads;
		for (change in changed) {
			// The unit that gives the declaration its type, which its readers read (`TypingSession.readUnit`).
			var unit = inferredUnit(change.declaration, owners, build.typed());
			var fact = facts.existing(compiler.semantic.DeclarationFacts.FactAspect.Unit, unit);
			if (fact < 0)
				continue;
			for (id in 0...facts.resultLimit) {
				var record = facts.unitRecord(id);
				if (record == null || build.names.indexOf(record.module) < 0 || record.reads.indexOf(fact) < 0)
					continue;
				var reader = facts.name(id);
				if (reads == null || !reads.units.exists(reader))
					throw new InternalError('--check-reuse: "${change.declaration}" changed type from ${change.before} to ${change.after}, '
						+ 'but "$reader", which read it, kept the body typed against the old one');
			}
		}
	}

	/** The unit that types unannotated declaration `declaration`: its function, or its field's initializer or inline constant. */
	static function inferredUnit(declaration:String, owners:Map<String, String>, typed:TypedProgram):String {
		if (owners.exists(declaration)
			&& !owners.exists(compiler.core.QualifiedName.parentOrEmpty(declaration) + ".new"))
			return declaration;
		var owner = compiler.core.QualifiedName.parentOrEmpty(declaration),
			name = compiler.core.QualifiedName.last(declaration);
		for (classDecl in typed.classes)
			if (classDecl.name == owner)
				for (field in classDecl.fields)
					if (field.name == name)
						return field.isInline ? compiler.types.typing.TypingSession.INLINE_CONSTANT_PREFIX + declaration
							: compiler.semantic.InitializerUnit.of(owner,
							name);
		return declaration;
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
			indexTypedInitializers(build.context, build.typed(), build.reindexedModules);
			// An unannotated function's signature, as the table gave it, also where this build did not index its body.
			for (module in build.reindexedModules.keys()) {
				var state = build.context.state.modules.get(module);
				if (state != null)
					for (key => signature in state.inferredSignatures)
						recordInferredSignature(build.context, module, key, signature);
			}
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
			build.semanticAssembly.invalidated, context.state.irCalls);
		var readSpecializations = reachedSpecializations(build);
		for (name in names) {
			checkCancelled(build.token);
			if (!modules.exists(name))
				continue;
			pruneModule(build, name, modules.get(name), functionNamesByModule, calledGeneratedHelpers,
				readSpecializations);
		}
		pruneUnusedKeyPathHelpers(context, names, build.rollbackModules);
		build.allocationAfterModulePrune = AllocationMeter.sample();
		build.retyped = uniqueSorted(build.retyped);
		build.allocationAfterPrune = AllocationMeter.sample();
	}

	/**
	 * The specializations of generic functions that the build's roots reach, by name: the units of the build's modules it typed or
	 * keeps ask for them, and so do the specializations they reach. A unit that calls one reads it (`TypingSession.useSharedUnit`),
	 * so the units' records name them. A specialization typed in an earlier build and not again stays only while it is reached:
	 * once the last of its callers is typed without it, a fresh build would not make it, and the prune sweeps its body and record.
	 */
	static function reachedSpecializations(build:FrontendBuild):Map<String, Bool> {
		var modules = build.context.state.modules,
			facts = build.context.state.declarationFacts,
			typedByName = build.typedByName,
			currentSpecializedOwners = build.currentSpecializedOwners;
		// Whether `unit` was typed earlier and stays only while something reaches it: a generic function's specialization, or a
		// member of a specialized owner this build no longer has.
		function reachedOnly(record:compiler.semantic.DeclarationFacts.UnitReads, unit:String):Bool {
			if (typedByName.exists(unit))
				return false;
			var state = modules.get(record.module), fn = state == null ? null : state.typedFunctions.get(unit);
			return fn != null && fn.originKind == compiler.types.TypedAst.FunctionOriginKind.Specialization
				&& (fn.physicalOwner == null || !currentSpecializedOwners.exists(fn.physicalOwner));
		}
		var reached:Map<String, Bool> = [],
			pending:Array<compiler.semantic.DeclarationFacts.UnitReads> = [];
		function reach(record:compiler.semantic.DeclarationFacts.UnitReads):Void {
			var asked = record.specializations;
			if (asked != null)
				for (fact in asked) {
					var unit = facts.name(fact);
					if (reached.exists(unit))
						continue;
					reached.set(unit, true);
					// A specialization that stays asks for the ones its own body calls.
					var kept = facts.unitRecord(fact);
					if (kept != null && reachedOnly(kept, unit))
						pending.push(kept);
				}
		}
		var inBuild:Map<String, Bool> = [for (name in build.names) name => true];
		for (id in 0...facts.resultLimit) {
			var record = facts.unitRecord(id);
			if (record != null && record.specializations != null && inBuild.exists(record.module)
				&& !reachedOnly(record, facts.name(id)))
				reach(record);
		}
		var next = 0;
		while (next < pending.length)
			reach(pending[next++]);
		return reached;
	}

	/** Drops the cached functions of one module that neither this typing nor a retained owner still accounts for. */
	static function pruneModule(build:FrontendBuild, name:String, state:ModuleState,
			functionNamesByModule:Map<String, Array<String>>, calledGeneratedHelpers:Map<String, Bool>,
			readSpecializations:Map<String, Bool>):Void {
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
			// representation. Its cached body and optional-value helpers are no longer valid in that case. A specialization is a
			// unit of its own, invalidated by what it read, whatever retyped its generic function. A generic function's specialization
			// also needs a caller that stays.
			var specialization = fn.originKind == compiler.types.TypedAst.FunctionOriginKind.Specialization;
			if (sourceOwner != null && owners.exists(sourceOwner)
				&& (specialization || !invalidated.exists(sourceOwner))
				&& (!specialization || fn.physicalOwner != null || readSpecializations.exists(cached))
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
		// A specialization dropped because nothing in the program asks for it changes for the units outside the program that still
		// do: one that comes back unchanged is typed again, and asks for it again.
		var facts = build.context.state.declarationFacts;
		for (cached in removed) {
			var fn = state.typedFunctions.get(cached);
			if (fn != null && fn.originKind == compiler.types.TypedAst.FunctionOriginKind.Specialization
				&& fn.physicalOwner == null && !typedByName.exists(cached) && !readSpecializations.exists(cached)) {
				var unit = facts.existing(compiler.semantic.DeclarationFacts.FactAspect.Unit, cached);
				if (unit >= 0)
					facts.changed(unit);
			}
		}
		if (removed.length > 0)
			removeCachedFunctions(build.context.state, build.context.state.writableState(name, build.rollbackModules),
				removed);
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
					state.irVersions.set(functionName, context.state.irVersions.next());
					state.pendingIrFunctions.remove(functionName);
					regenerated.push(functionName);
				}
			}
		build.regenerated = uniqueSorted(regenerated);
		build.irGenerationDoneAt = now();
	}

	/** The generator's version of each function of the program (`ModuleState.irVersions`), 0 for one it does not hold. */
	static function generatedVersions(build:FrontendBuild):String->Int {
		var modules = build.context.state.modules, owners = build.semanticAssembly.owners;
		return function(name:String):Int {
			var owner = owners.get(name), state = owner == null ? null : modules.get(owner);
			if (state == null || !state.irFunctions.exists(name))
				return 0;
			var version = state.irVersions.get(name);
			return version == null ? 0 : version;
		};
	}

	/** Where the frontend's stages spent their time and allocation: `CompilationContext.frontendStages`. */
	static function reportStages(build:FrontendBuild):Void {
		var context = build.context;
		context.frontendStages = stagesReport([
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
			- build.parseCountAtStart);
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

	/** The IR bodies the program is assembled from, one per cached function name. */
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
		dropUnusedKeyPathFields(build.typed(), cached);
	}

	/**
	 * Whether this compile prints anonymous structures through generated `__string` methods (IrProgramAssembler.anonymousString):
	 * when it has the `__std_string` intrinsic that string conversion lowers to, as every compile configured with the compiler's
	 * intrinsics does.
	 */
	static function printsStructures(context:CompilationContext):Bool
		return context.natives.signatures().exists("__std_string");

	/** The declaration tables, natives and initializers the IR pipeline assembles the program from. */
	static function assembleTables(build:FrontendBuild):Void {
		var context = build.context,
			generator = build.generator,
			typedNew = build.typed();
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
			for (native in compiler.ir.tools.IrInstrumentation.natives())
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
		build.objects = [for (name in objectNames) resolvedObjects.get(name)];
		build.interfaces = IrProgramAssembler.interfacesFrom(generator, typedNew);
		build.enums = IrProgramAssembler.enumsFrom(generator, typedNew);
		build.staticFields = IrProgramAssembler.staticFieldsFrom(generator, typedNew);
		var generationWarnings:Array<compiler.core.Diagnostic> = [];
		context.state.initializerFunctions.checks = context.options.checkReuse;
		build.initializers = IrProgramAssembler.staticInitializersFrom(generator, typedNew, build.initializationClasses,
			build.cached, generationWarnings, context.state.staticReferences, context.state.initializerFunctions)
			.concat(liveInitializers);
		context.state.staticReferences.endBuild();
		context.state.initializerFunctions.sweep();
		TypingWarnings.publishGeneration(context, build.names, generationWarnings, build.rollbackModules);
		// The printers made with the objects (`context.state.structurePrinters`), for every structure the program has.
		if (printsStructures(context)) {
			var printers = context.state.structurePrinters;
			// Every object whose `__string` objectsFrom pointed at a generated printer.
			for (object in build.objects)
				for (method in object.methods)
					if (method.name == "__string"
						&& method.functionName.name == IrProgramAssembler.anonymousStringName(object.name)) {
						var printer = printers.kept(method.functionName.name, [object]);
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
		// A build that keeps no session has no next build to give its final IR to, so it records no inputs to match.
		var inputs = context.options.keepSession ? inputsOf(build) : null,
			previousPipeline = context.state.pipelineSnapshot,
			reuseMiss = context.livePatching ? "live patching" : previousPipeline == null
				|| inputs == null ? "no earlier build" : previousPipeline.mismatch(inputs),
			matchesPrevious = reuseMiss == null,
			checkingReuse = context.options.checkReuse,
			reusedPipeline:Null<PipelineSnapshot> = matchesPrevious ? previousPipeline : null,
			ir:IrProgram,
			inlinerChanged:Array<String>;
		if (checkingReuse && inputs != null && context.state.compiledOnce && !context.livePatching)
			checkFrontendReuse(build, inputs);
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
				context.state.inlineCache, context.valueArrayTarget(),
				context.exportedFunctions(), context.isWasmTarget() || !context.livePatching,
				!context.livePatching && !context.isWasmTarget() && context.options.earlyPrune,
				[for (object in objects) {
					if (object.isValue && object.nativeLayout != null) {
						var canonical = canonicalObjectCache.get(object.name);
						if (canonical == null)
							throw new InternalError('Missing canonical layout for "${object.name}"');
						canonical;
					} else object;
				}], context.options, meter, context.state.stageMemos, generatedVersions(build));
			// The fingerprints go into the runtime ABI only.
			if (context.describesRuntimeAbi()) {
				var cNativeNames = [for (native in irCNatives) native.name].join(","),
					ownPrints:Map<String, String> = [];
				for (fn in cached)
					if (PositionalName.is(fn.name))
						ownPrints.set(fn.name, context.state.inlineCache.positionalFingerprint(fn, cNativeNames));
				context.state.inlineCache.finishPositionalFingerprints();
				ir.positionalFingerprints = PositionalName.nested(ownPrints);
			}
			if (context.livePatching) {
				var texts:Map<String, String> =
					[for (state in context.state.modules) state.source.path => state.source.text],
					sources = context.sourceAnchors();
				for (fn in cached)
					if (PositionalName.is(fn.name)) {
						var place = PositionalName.placeOf(fn, sources),
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
			var passes = new compiler.ir.pipeline.IrPipelineContext(context.targetProfile(),
				context.valueArrayTarget());
			passes.livePatching = context.livePatching;
			passes.developmentMetadata = context.developmentMetadata;
			passes.sources = context.sourceAnchors();
			passes.reflectable = build.reflectable;
			passes.inlineCache = context.state.inlineCache;
			passes.options = context.options;
			passes.meter = meter;
			passes.instrumentScope = build.instrumentScope;
			passes.verifyMemo = context.state.verifyMemo;
			// The lineage of the assembly continues through the stages over bodies (`IrLineage.bodies`).
			var stageMemos = context.state.stageMemos;
			passes.lineage = context.options.keepSession ? stageMemos.lineage : null;
			// The generator's functions are the pipeline's input and only a next build reads them again: a build that keeps no
			// session lets them go while the passes run, which then hold the only copy of the program.
			if (!context.options.keepSession) {
				build.cached = [];
				cached = [];
				context.state.releaseGeneratedIr();
			}
			ir = compiler.ir.pipeline.IrPipeline.target.run(ir, passes);
			for (entry in meter.entries())
				context.irPassCosts.push(entry);
			inlinerChanged = passes.inlinerChanged;
			if (reusedPipeline != null) {
				var difference = PipelineSnapshot.irDifference(reusedPipeline.ir, ir);
				if (difference != null)
					throw new InternalError('--check-reuse: the final IR reused for equal pipeline inputs differs from a fresh run ($difference)');
			}
			// The prune ran early: after the last pass nothing may call what it removed (`IrEntryPrune`).
			if (checkingReuse)
				compiler.ir.analysis.IrEntryPrune.checkRemoved("the pipeline", ir.functions, ir.prunedFunctions);
			context.state.pipelineSnapshot = context.livePatching
				|| inputs == null ? null : new PipelineSnapshot(inputs, ir);
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
	}

	static function result(build:FrontendBuild, ir:Null<IrProgram>, irAssemblyDoneAt:Float,
			reused:Null<PipelineSnapshot>, reuseMiss:Null<String>):FrontendResult {
		var context = build.context,
			semanticAssembly = build.semanticAssembly;
		return {
			ir: ir,
			moduleNames: build.names,
			typedProgram: build.typedNew,
			nativeTypeDescriptors: build.nativeTypeDescriptors,
			retyped: build.retyped,
			invalidations: semanticAssembly.invalidations,
			regenerated: build.regenerated,
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
			frontendTypedFunctions: context.frontendTypedFunctions,
			frontendStages: context.frontendStages,
			irPassCosts: context.irPassCosts,
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

	/** What the build gives the IR pipeline (see `PipelineInputs`), with `objects` and `functions` in place of the build's when given. */
	static function inputsOf(build:FrontendBuild, ?objects:Array<IrObject>, ?functions:Array<IrFunction>):PipelineInputs
		return pipelineInputs(build.context, build.generator, build.instrumentScope, functions ?? build.cached,
			build.initializers, build.irNatives, build.irCNatives, objects ?? build.objects, build.interfaces,
			build.enums, build.staticFields, build.semanticAssembly.entryPoint, build.reflectable);

	/**
	 * `--check-reuse` of what the frontend kept from earlier builds (typed bodies, their IR, objects): the frontend run again on the
	 * same sources from a fresh state (`SessionState.freshFromSources`) must give the IR pipeline the same inputs, positions
	 * included. The IR and backend checks recompute from these inputs, so a body kept typed against a declaration's old position
	 * passes them. The object cache may also hold content-named objects an edit left unused (`isGeneratedObjectOfRetypedFunction`),
	 * which nothing reads and a fresh state has not made: those and their printers are left out. A live build is not checked: it
	 * keeps the layouts and identities of the module it patches, which a fresh state has not.
	 */
	static function checkFrontendReuse(build:FrontendBuild, inputs:PipelineInputs):Void {
		var fresh = build.context.over(build.context.state.freshFromSources()), freshBuild:Null<FrontendBuild> = null;
		try
			freshBuild = throughTables(fresh, build.entryModule, build.token, [], true, false, null, null, null).build
		catch (error:CompileError)
			throw new InternalError('--check-reuse: the frontend run afresh fails where the warm build passed (${error.message})');
		if (freshBuild == null)
			throw new InternalError("--check-reuse: the frontend run afresh produced no IR tables");
		var made = [for (object in freshBuild.objects) object.name => true],
			unusedPrinters = [
				for (object in build.objects)
					if (!made.exists(object.name)) IrProgramAssembler.anonymousStringName(object.name) => true
			],
			difference = PipelineSnapshot.inputsDifference(inputsOf(freshBuild),
				inputsOf(build, [for (object in build.objects) if (made.exists(object.name)) object],
				[for (fn in build.cached) if (!unusedPrinters.exists(fn.name)) fn]));
		if (difference != null)
			throw new InternalError('--check-reuse: what the frontend kept from earlier builds differs from a fresh frontend run ($difference)');
	}

	/** Everything the IR pipeline reads for this build (see `PipelineInputs`). */
	static function pipelineInputs(context:CompilationContext, generator:IrGenerator,
			instrumentScope:Null<compiler.ir.tools.IrInstrumentation.IrInstrumentationScope>,
			functions:Array<IrFunction>,
			initializers:Array<IrFunction>,
			natives:Array<compiler.ir.model.Ir.IrNative>, cNatives:Array<compiler.ir.model.Ir.IrCNative>,
			objects:Array<IrObject>,
			interfaces:Array<compiler.ir.model.Ir.IrInterface>, enums:Array<compiler.ir.model.Ir.IrEnum>,
			staticFields:Array<compiler.ir.model.Ir.IrStaticField>,
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
	 * The modules typing can call although no source names them, and cannot tell it will before bodies are typed, are part of
	 * every program that can have them (`RuntimeType.programModules`), so the graph is complete before anything is typed. One of
	 * them, the specialized map owner, also changes how types are represented: no body is ever typed without it. A program without
	 * a stdlib root has none of them, and can make no call into one.
	 */
	static function seedTypedRuntimeModules(context:CompilationContext):Void
		for (path in compiler.runtime.RuntimeType.programModules(context.isWasmTarget(), context.natives.has)) {
			var module = context.moduleAnalyzer.loadSourceModuleDependency(path);
			if (module != null && context.rootModules.indexOf(module) < 0)
				context.rootModules.push(module);
		}

	/** Drops functions of module `state` with what they were typed and lowered to, and the records of what they read. */
	static function removeCachedFunctions(session:SessionState, state:ModuleState, names:Array<String>):Void
		for (cached in names) {
			state.typedFunctions.remove(cached);
			state.typedSourceRevisions.remove(cached);
			var facts = session.declarationFacts,
				unit = facts.existing(compiler.semantic.DeclarationFacts.FactAspect.Unit, cached),
				record = facts.unitRecord(unit);
			if (record != null && record.module == state.name)
				facts.removeUnit(unit);
			state.keyPathUses.remove(cached);
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
				removeCachedFunctions(context.state, context.state.writableState(name, rollbackModules), unused);
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
			invalidated:Map<String, Bool>, lowerToIr:Bool,
			declared:Map<String, Bool>, previousSemantic:Null<SemanticProgram>):Null<RetainedFromPrevious> {
		var result:Map<String, Bool> = [],
			retainedEnums:Map<String, Bool> = [],
			previous = context.state.lastTypedProgram;
		if (previous == null)
			return null;
		// As pruning keeps them (`pruneModule`): not typed again, and neither the function nor its origin invalidated. A
		// specialization is a unit of its own, kept while what it read is current, however its generic function was invalidated.
		var units:Map<String, Bool> = [];
		for (module in modules) {
			var state = context.state.modules.get(module);
			if (state != null)
				for (name => fn in state.typedFunctions)
					if (!selected.exists(name) && !invalidated.exists(name)
						&& (fn.origin == null
						|| fn.originKind == compiler.types.TypedAst.FunctionOriginKind.Specialization
						|| !invalidated.exists(fn.origin)))
						units.set(name, true);
		}
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
				enums: retainedEnums,
				units: units
			};
		// A type-only request has no complete IR graph to inspect.
		if (!lowerToIr)
			return {
				program: previous,
				classes: known,
				enums: knownEnums,
				units: units
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
		var mentions = context.state.irTypeMentions;
		while (pending.length > 0) {
			var name = pending.pop(), fn = functions.get(name);
			if (fn == null)
				throw new InternalError('Missing function $name during inline enum reflection reachability');
			var named = mentions.get(fn);
			if (named == null) {
				named = typeMentions(fn);
				mentions.set(fn, named);
			}
			for (target in named.classes)
				if (known.exists(target))
					retain(target);
			for (target in named.enums)
				if (knownEnums.exists(target))
					retainEnum(target);
		}
		mentions.endBuild();
		return {
			program: previous,
			classes: result,
			enums: retainedEnums,
			units: units
		};
	}

	/**
	 * The classes and specialized-enum candidates `fn` names in its signature, values, type values and globals, each
	 * once: what `retainedFromPrevious` reads of a function, kept by the session while the function is the same object
	 * (`SessionState.irTypeMentions`), so an unchanged one is not read again.
	 */
	static function typeMentions(fn:IrFunction):TypeMentions {
		var names:TypeMentions = {classes: [], enums: []};
		function add(mention:String):Void
			if (names.classes.indexOf(mention) < 0)
				names.classes.push(mention);
		function addEnum(mention:String):Void
			if (names.enums.indexOf(mention) < 0)
				names.enums.push(mention);
		function visitType(type:IrType):Void
			switch type {
				case Obj(name):
					add(name);
				case Enum(name):
					addEnum(name);
				case Array(element), Iterator(element), Nullable(element):
					visitType(element);
				case Function(arguments, value):
					for (argument in arguments)
						visitType(argument);
					visitType(value);
				default:
			}
		for (argument in fn.arguments)
			visitType(argument.type);
		visitType(fn.result);
		// A function kept as its body alone is read from the body: its value types, type values and globals, not decoded.
		var body = fn.body;
		if (body != null) {
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var output = body.output(row);
					if (output.exists())
						visitType(body.valueType(output));
					for (index in 0...body.operandCount(row))
						visitType(body.valueType(body.operand(row, index)));
					switch body.opcode(row) {
						case compiler.ir.model.IrOpcode.TypeValue:
							visitType(IrTypeIds.type(body.aux(row)));
						case compiler.ir.model.IrOpcode.GlobalGet, compiler.ir.model.IrOpcode.GlobalSet:
							var field = body.symbol(row).name, separator = field.lastIndexOf(".");
							if (separator > 0)
								add(field.substr(0, separator));
						default:
					}
					row = body.nextRow(row);
				}
			}
			return names;
		}
		for (block in fn.blocks)
			for (located in block.instructions) {
				var instruction = located.value,
					output = compiler.ir.model.IrOperands.output(instruction);
				if (output != null)
					visitType(output.type);
				for (input in compiler.ir.model.IrOperands.inputs(instruction))
					visitType(input.type);
				switch instruction {
					case TypeValue(_, type):
						visitType(type);
					case GlobalGet(_, field), GlobalSet(field, _):
						var separator = field.lastIndexOf(".");
						if (separator > 0)
							add(field.substr(0, separator));
					default:
				}
			}
		return names;
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
			invalidated:Map<String, Bool>, calls:compiler.ir.reuse.IrFunctionMemo<Array<String>>):Map<String, Bool> {
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
				for (callee in callsOf(body, calls))
					if (holders.exists(callee) && !invalidated.exists(callee)) {
						result.set(callee, true);
						var dependencyOwner = holders.get(callee).name;
						if (!reachable.exists(dependencyOwner)) {
							reachable.set(dependencyOwner, true);
							names.push(dependencyOwner);
						}
						if (!kept.exists(callee)) {
							kept.set(callee, true);
							pending.push(callee);
						}
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
			for (callee in callsOf(body, calls))
				if (holders.exists(callee)) {
					result.set(callee, true);
					var dependencyOwner = holders.get(callee).name;
					if (!reachable.exists(dependencyOwner)) {
						reachable.set(dependencyOwner, true);
						names.push(dependencyOwner);
					}
					if (!kept.exists(callee)) {
						kept.set(callee, true);
						pending.push(callee);
					}
				}
		}
		calls.endBuild();
		names.sort(Reflect.compare);
		return result;
	}

	/**
	 * The functions `fn` calls, each once, in the order it first calls them: kept by the session while `fn` is the same object
	 * (`SessionState.irCalls`), so the helpers a build keeps are found without reading every function that stays.
	 */
	static function callsOf(fn:IrFunction, calls:compiler.ir.reuse.IrFunctionMemo<Array<String>>):Array<String> {
		var known = calls.get(fn);
		if (known != null)
			return known;
		var found:Array<String> = [], body = fn.body;
		// A function kept as its body alone is read from the body, not decoded.
		if (body != null) {
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == compiler.ir.model.IrOpcode.Call) {
						var callee = body.symbol(row).name;
						if (found.indexOf(callee) < 0)
							found.push(callee);
					}
					row = body.nextRow(row);
				}
			}
			calls.set(fn, found);
			return found;
		}
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case Call(_, callee, _) if (found.indexOf(callee.name) < 0):
						found.push(callee.name);
					default:
				}
		calls.set(fn, found);
		return found;
	}

	static function sameDeclarations(previous:AstProgram, current:AstProgram):Bool {
		// Structural type signatures ignore field order and metadata, which the codec reads from the declaration.
		if (previous.aliases.length != current.aliases.length)
			return false;
		for (index in 0...current.aliases.length)
			if (previous.aliases[index] != current.aliases[index]
				&& !compiler.syntax.CanonicalComparison.aliases(previous.aliases[index], current.aliases[index],
				PositionsCount.Ignored))
				return false;
		return sameNames([for (decl in previous.enums) decl.name], [for (decl in current.enums) decl.name])
			&& sameNames([for (decl in previous.abstracts) decl.name], [for (decl in current.abstracts) decl.name])
			&& sameNames([for (decl in previous.abstracts) if (decl.values != null) decl.name],
			[for (decl in current.abstracts) if (decl.values != null) decl.name])
			&& sameNames([for (decl in previous.interfaces) decl.name], [for (decl in current.interfaces) decl.name])
			&& sameNames([for (decl in previous.classes) decl.name], [for (decl in current.classes) decl.name])
			&& sameNames([for (decl in previous.functions) decl.name], [for (decl in current.functions) decl.name]);
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
			signatures:Map<String, compiler.syntax.Ast.AstFunction>):Map<String, Map<String, compiler.ir.model.Ir.IrDefault>> {
		var result:Map<String, Map<String, compiler.ir.model.Ir.IrDefault>> = [];
		for (fn in ir.functions) {
			var signature = signatures.get(fn.name);
			if (signature == null)
				continue;
			var defaults:Map<String, compiler.ir.model.Ir.IrDefault> = [];
			for (argument in signature.arguments) {
				var value = argument.defaultValue;
				var literal:Null<compiler.ir.model.Ir.IrDefault> = value == null
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
	static function stagesReport(stages:Array<{name:String, ms:Float, allocation:PhaseAllocation}>, parseMs:Float,
			parseBytes:Float, parseCount:Float):String {
		var parts = [];
		for (stage in stages) {
			var a = stage.allocation;
			parts.push('${stage.name}=${Math.round(stage.ms)}ms/${Math.round(a.bytes / 1048576.0)}MB/${Math.round(a.count / 1000.0)}k/${Std.int(a.collections)}gc(${Math.round(a.markMicros / 1000.0)}ms)');
		}
		parts.push('parse-within=${Math.round(parseMs)}ms/${Math.round(parseBytes / 1048576.0)}MB/${Math.round(parseCount / 1000.0)}k');
		return parts.join(" ");
	}

	/**
	 * Every module typing called into without the source naming it was in the graph before anything was typed (`RuntimeType`
	 * declares them; `seedTypedRuntimeModules` and `ModuleAnalyzer.addTypeDependencies` add them). A module missing here is a typer
	 * rule whose module `RuntimeType` does not declare: fail, naming it, and compile nothing typed without it.
	 */
	static function checkTypedRuntimeDependencies(context:CompilationContext, dependencies:Array<{
		var functionName:String;
		var target:String;
	}>, names:Array<String>):Void {
		var program = [for (name in names) name => true];
		for (dependency in dependencies) {
			if (!compiler.runtime.RuntimeType.isTypedDependency(dependency.target))
				throw new InternalError('Typing made "${dependency.functionName}" call "${dependency.target}", which RuntimeType does not declare, so the graph does not add it');
			// Only targets without native dynamic objects (Wasm) call the stdlib's class; elsewhere the dependency is unused.
			if (dependency.target == PlatformAbi.DYNAMIC_OBJECT_CLASS && !context.isWasmTarget())
				continue;
			var module = context.moduleAnalyzer.loadSourceModuleDependency(dependency.target);
			if (module == null || !program.exists(module))
				throw new InternalError('Module "${dependency.target}", which typing made "${dependency.functionName}" call, is not in the program');
		}
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

	static function modelOwnsType(program:compiler.syntax.Ast.AstProgram, name:String):Bool {
		var prefix = program.packageName == null || program.packageName.length == 0 ? "" : program.packageName + ".";
		for (classDecl in program.classes)
			if (prefix + classDecl.name == name)
				return true;
		return false;
	}
}
