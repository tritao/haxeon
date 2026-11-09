package compiler.compilation;

import compiler.Diagnostic.CompileError;
import compiler.runtime.PlatformAbi;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.abi.PositionalName;
import compiler.ir.IrFunction;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.IrGenerator;
import compiler.ir.IrInliner;
import compiler.ir.IrProgramAssembler;
import compiler.ir.IrVerifier;
import compiler.modules.ModuleReachability;
import compiler.modules.ModuleState;
import compiler.semantic.LambdaName;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.SemanticAssembly;
import compiler.service.CancellationToken;
import compiler.semantic.SemanticProgram;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.typing.EnumRuntimeType;
import compiler.types.typing.RetainedFromPrevious;
import compiler.types.typing.RuntimeDependencyTracker;
import compiler.types.Type.CompilerType;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.SemanticDependencyCollector;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstType;
import compiler.compilation.AllocationMeter.PhaseAllocation;
import compiler.compilation.PipelineSnapshot.PipelineInputs;

typedef FrontendResult = {
	final ir:Null<IrProgram>;
	final moduleNames:Array<String>;
	final typedProgram:TypedProgram;
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
	final frontendDoneAt:Float;
	final typingLoweringDoneAt:Float;
	final irAssemblyDoneAt:Float;
	final allocationPhases:Array<PhaseAllocation>;

	/** The earlier build whose final IR this one equals, when every input of the IR pipeline matched (see `PipelineSnapshot`). */
	final reused:Null<PipelineSnapshot>;

	/** Why no earlier build could be reused, when there was one to compare with; null otherwise. */
	final reuseMiss:Null<String>;
}

/** Builds and validates the reachable source graph through complete IR assembly. */
class FrontendCompilation {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			snapshotDoneAt:Float, ?lowerToIr = true, ?indexSemantics = true, ?pendingBody:Map<String, Bool>, ?pendingSignatures:Map<String, Bool>,
			?pendingStructural:Map<String, Bool>, ?carried:{
			regenerated:Array<String>,
			retyped:Array<String>
		}):FrontendResult {
		seedRepresentationModules(context);
		var allocationAtStart = AllocationMeter.sample();
		var modules = context.modules,
			graph = context.graph,
			objectCache = context.objectCache,
			genericSpecializations = context.genericSpecializations;
		if (token != null)
			token.check();
		var bodyChanged:Map<String, Bool> = pendingBody == null ? [] : pendingBody,
			signatureChanged:Map<String, Bool> = pendingSignatures == null ? [] : pendingSignatures,
			structuralChanged:Map<String, Bool> = pendingStructural == null ? [] : pendingStructural,
			graphParseMs = 0.0,
			graphDependencyMs = 0.0,
			graphInitializationMs = 0.0;
		var names:Array<String> = [],
			initializationClasses:Array<String> = [],
			cachedReachability = context.cachedReachability(entryModule),
			reuseGraph = cachedReachability != null;
		if (cachedReachability != null)
			for (name in cachedReachability.names) {
				var state = modules.get(name);
				if (state == null) {
					reuseGraph = false;
					break;
				}
				if (state.ast == null) {
					var phaseStarted = Sys.time() * 1000.0;
					state = context.writableState(name, rollbackModules);
					context.parse(state, entryModule, bodyChanged, signatureChanged, structuralChanged);
					graphParseMs += Sys.time() * 1000.0 - phaseStarted;
					phaseStarted = Sys.time() * 1000.0;
					context.addTypeDependencies(state);
					graphDependencyMs += Sys.time() * 1000.0 - phaseStarted;
				}
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
				if (reachableState.ast == null) {
					var phaseStarted = Sys.time() * 1000.0;
					reachableState = context.writableState(reachableState.name, rollbackModules);
					context.parse(reachableState, entryModule, bodyChanged, signatureChanged, structuralChanged);
					graphParseMs += Sys.time() * 1000.0 - phaseStarted;
					phaseStarted = Sys.time() * 1000.0;
					context.addTypeDependencies(reachableState);
					graphDependencyMs += Sys.time() * 1000.0 - phaseStarted;
				}
				reachability.includeDependencies(reachableState);
			}
			names = reachability.finish(token);
			var initializationStartedAt = Sys.time() * 1000.0;
			graph.rebuild(modules);
			var initializationNames = graph.initializationOrder(modules, names);
			for (name in initializationNames) {
				var state = modules.get(name), ast = state.parsedAst();
				for (classDecl in ast.classes)
					initializationClasses.push(ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name));
			}
			context.cacheReachability(entryModule, names, initializationClasses);
			graphInitializationMs = Sys.time() * 1000.0 - initializationStartedAt;
		}
		compiler.modules.CodeIdentityTable.refresh(context, names, rollbackModules, entryModule, bodyChanged, signatureChanged, structuralChanged);
		var frontendGraphDoneAt = Sys.time() * 1000.0;
		var allocationAfterGraph = AllocationMeter.sample();

		var semanticAssembly = SemanticAssembly.run(context, entryModule, token, rollbackModules, names, bodyChanged, signatureChanged, structuralChanged,
			indexSemantics, carried != null),
			canonicalProgram = semanticAssembly.canonicalProgram,
			functions = semanticAssembly.functions,
			owners = semanticAssembly.owners,
			generatedByModule = semanticAssembly.generatedByModule,
			invalidated = semanticAssembly.invalidated,
			selected = semanticAssembly.selected,
			entryPoint = semanticAssembly.entryPoint;
		var frontendDoneAt = Sys.time() * 1000.0;
		var allocationAfterSemantic = AllocationMeter.sample();
		var allocationAfterAnalysis = allocationAfterSemantic;
		var allocationAfterProgramTyping = allocationAfterSemantic;
		var typedNew:TypedProgram, typerMetrics:TyperPhaseMetrics;
		var runtimeDependencies:Array<{var functionName:String; var target:String;}> = [];
		var purityQueries:Map<String, Map<String, Bool>>,
			noReturnQueries:Map<String, Map<String, Bool>>,
			keyPathUses:Map<String, Map<String, Bool>>,
			inlineConstantDependencies:Map<String, Map<String, Bool>>,
			defaultArgumentSources:Map<String, Map<String, compiler.Source.SourceFile>>;
		try {
			if (token != null)
				token.check();
			var previousSemantic = context.cachedSemanticProgram;
			var canReuseSemantic = previousSemantic != null
				&& CompilationContext.mapIsEmpty(signatureChanged)
				&& CompilationContext.mapIsEmpty(structuralChanged)
				&& selectedSignaturesExplicit(canonicalProgram, selected)
				&& sameDeclarations(previousSemantic.program, canonicalProgram);
			var semantic:SemanticProgram;
			if (canReuseSemantic && previousSemantic != null)
				semantic = previousSemantic.replaceBodies(canonicalProgram, selected);
			else
				semantic = SemanticProgram.analyze(canonicalProgram);
			allocationAfterAnalysis = AllocationMeter.sample();
			var typedResult = Typer.typeAnalyzedMeasured(semantic, selected, context.nativeSignatures(), entryPoint, genericSpecializations,
				context.nativeLayoutTarget(), canReuseSemantic ? context.lastTypedProgram : null, semanticAssembly.facts, lowerToIr,
				retainedFromPrevious(context, names, selected, lowerToIr, [for (classDecl in canonicalProgram.classes) classDecl.name => true]));
			allocationAfterProgramTyping = AllocationMeter.sample();
			typedNew = typedResult.program;
			context.frontendPassFunctions.push(typedNew.functions.length);
			IrGenerator.bindEnumConstructors(typedNew.enums);
			IrGenerator.bindClasses(typedNew.classes, typedNew.interfaces, typedNew.genericOwnerAliases);
			IrGenerator.bindHeaderlessValueClasses(!context.isWasmTarget());
			IrGenerator.bindDynamicObjectLiterals(!context.isWasmTarget());
			IrGenerator.bindNativeArrayChecks(true);
			IrGenerator.bindNativeStringFastPaths(!context.isWasmTarget());
			IrGenerator.bindNativeReflectionDispatch(context.isWasmTarget());
			typerMetrics = typedResult.metrics;
			runtimeDependencies = typedResult.runtimeDependencies;
			purityQueries = typedResult.purityQueries;
			noReturnQueries = typedResult.noReturnQueries;
			keyPathUses = typedResult.keyPathUses;
			inlineConstantDependencies = typedResult.inlineConstantDependencies;
			defaultArgumentSources = typedResult.defaultArgumentSources;
			// A module that changes a representation is in the program before anything is typed (see `seedRepresentationModules`),
			// so typing cannot have used a representation without it. If one is reported missing, a module was left out of the
			// seeds: fail here, naming it, and do not compile what was typed against the wrong representation.
			for (dependency in runtimeDependencies)
				if (RuntimeDependencyTracker.changesRepresentation(dependency.target)) {
					var representationModule = context.loadSourceModuleDependency(dependency.target);
					if (representationModule == null || names.indexOf(representationModule) < 0)
						throw 'Representation module "${dependency.target}" must be seeded but is not in the program (needed by "${dependency.functionName}")';
				}
			context.cachedSemanticProgram = semantic;
		} catch (error:CompileError) {
			for (name in names) {
				var state:compiler.modules.ModuleState = modules.get(name);
				if (state.source.path == error.diagnostic.span.file.path)
					context.writableState(name, rollbackModules).diagnostics.push(error.diagnostic);
			}
			throw error;
		}
		var reindexedModules:Map<String, Bool> = [];
		for (functionName in selected.keys()) {
			var module = owners.get(functionName);
			if (module != null)
				reindexedModules.set(module, true);
		}
		if (indexSemantics) {
			for (module in reindexedModules.keys()) {
				var state = context.writableState(module, rollbackModules);
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source, state.revision, state.tokens);
			}
			context.invalidateSemanticResolutionCache();
			for (module in reindexedModules.keys()) {
				var state = modules.get(module);
				if (state != null) {
					var model = state.semanticModel;
					if (model != null)
						model.index.indexTypeReferences(context.resolveSemanticType, token);
				}
			}
		}
		var allocationAfterIndexRebuild = AllocationMeter.sample();
		var retyped = carried == null ? [] : carried.retyped.copy(),
			regenerated = carried == null ? [] : carried.regenerated.copy();
		var previousTyped = context.lastTypedProgram;
		var currentSpecializedOwners:Map<String, Bool> = [
			for (classDecl in typedNew.classes)
				if (classDecl.specializationOrigin != null) classDecl.name => true
		];
		if (previousTyped != null) {
			var currentClasses = [for (classDecl in typedNew.classes) classDecl.name => true];
			for (classDecl in previousTyped.classes)
				if (!currentClasses.exists(classDecl.name))
					objectCache.remove(classDecl.name);
		}
		// The objects a function makes for its closures and captured variables are named by source offsets. When the function
		// is typed again they are made again under their new names, and the old ones must not stay behind.
		var retypedNames:Map<String, Bool> = [for (fn in typedNew.functions) fn.name => true];
		for (name in [for (name in objectCache.keys()) name])
			if (isGeneratedObjectOfRetypedFunction(name, retypedNames))
				objectCache.remove(name);
		var typedObjects = IrGenerator.objectsFrom(typedNew);
		for (object in typedObjects)
			objectCache.set(object.name, object);
		var currentObjects:Array<IrObject> = [for (name in objectCache.keys()) objectCache.get(name)];
		IrGenerator.bindGeneratedObjects(currentObjects);
		IrGenerator.bindFlatValueObjects(currentObjects);
		var allocationAfterObjects = AllocationMeter.sample();
		var touchedModules:Map<String, Bool> = [],
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction> = [],
			generatedFunctions:Map<String, Bool> = [];
		for (fn in typedNew.functions) {
			typedByName.set(fn.name, fn);
			if (!owners.exists(fn.name))
				generatedFunctions.set(fn.name, true);
		}
		for (fn in typedNew.functions) {
			if (token != null)
				token.check();
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
			var state = context.writableState(module, rollbackModules);
			state.typedFunctions.set(fn.name, fn);
			state.typedSourceRevisions.set(fn.name, state.revision);
			var dependencies = state.semanticDependencies.get(fn.name);
			if (dependencies != null)
				state.semanticDependencies.set(fn.name, [
					for (dependency in dependencies)
						if (dependency.kind != SemanticDependencyKind.InlineConstant) dependency
				]);
			var constants = inlineConstantDependencies.get(fn.name);
			if (constants != null)
				for (target in constants.keys())
					SemanticDependencyCollector.addDependency(state.semanticDependencies, fn.name, SemanticDependencyKind.InlineConstant, target,
						context.resolveSemanticSymbol(target));
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
				state.semanticModel.index.indexTypedFunction(fn, context.resolveSemanticSymbol, context.resolveSemanticEnumCase, token);
			// A lambda names the function it is written in as its origin, so it is retyped with that function.
			var semanticOrigin = fn.origin;
			var semanticallyInvalidated = invalidated.exists(fn.name) || semanticOrigin != null && invalidated.exists(semanticOrigin);
			if (semanticallyInvalidated)
				retyped.push(fn.name);
			touchedModules.set(module, true);
			if (lowerToIr) {
				state.irFunctions.set(fn.name, IrGenerator.generateFunction(fn));
				state.irSourceRevisions.set(fn.name, state.revision);
				state.pendingIrFunctions.remove(fn.name);
				regenerated.push(fn.name);
				var version = state.irVersions.exists(fn.name) ? state.irVersions.get(fn.name) + 1 : 1;
				state.irVersions.set(fn.name, version);
			} else
				state.pendingIrFunctions.set(fn.name, true);
		}
		for (object in currentObjects)
			objectCache.set(object.name, object);
		var allocationAfterFunctions = AllocationMeter.sample();
		if (indexSemantics) {
			indexTypedInitializers(context, typedNew, reindexedModules);
			publishResolvedDependencies(context, typedNew, reindexedModules, rollbackModules);
		}
		var allocationAfterIndexPublication = AllocationMeter.sample();
		var functionNamesByModule:Map<String, Array<String>> = [];
		for (fn in functions) {
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
		for (module in touchedModules.keys())
			if (modules.exists(module))
				modules.get(module).typeVersion++;
		var allocationBeforeModulePrune = AllocationMeter.sample();
		// Shared generated helpers have one origin, but every retained caller needs their dependencies.
		var calledGeneratedHelpers = generatedHelpersStillCalled(modules, names, typedByName, owners, invalidated);
		for (name in names) {
			if (token != null)
				token.check();
			if (!modules.exists(name))
				continue;
			var state = modules.get(name),
				ast = state.parsedAst(),
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
				var sourceOwner = origin != null
					&& initializerModule(origin, owners) != null ? origin.substr(0, origin.length - INITIALIZER_SUFFIX.length) + ".new" : origin;
				// Shared helpers may move to another requesting module. Keep only the fresh owner's copy,
				// otherwise assembling cached bodies can resurrect the previous owner's stale IR.
				var supersededOwner = typedByName.exists(cached) && owners.get(cached) != name;
				// Even when the generic origin is unchanged, a specialization can depend on a changed type's
				// representation. Its cached body and optional-value helpers are no longer valid in that case.
				if (sourceOwner != null && owners.exists(sourceOwner) && !invalidated.exists(sourceOwner) && !supersededOwner
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
				while (pending.length > 0) {
					var parent = pending.pop();
					if (typedByName.exists(parent))
						continue;
					for (nested => fn in state.typedFunctions) {
						if (valid.exists(nested) || invalidated.exists(nested))
							continue;
						if (fn.origin == parent || StringTools.startsWith(nested, "$lambda:" + parent + ":")) {
							valid.set(nested, true);
							owners.set(nested, name);
							pending.push(nested);
						}
					}
				}
			}
			if (lowerToIr)
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
				removeCachedFunctions(context.writableState(name, rollbackModules), removed);
		}
		pruneUnusedKeyPathHelpers(context, names, rollbackModules);
		var allocationAfterModulePrune = AllocationMeter.sample();
		retyped = uniqueSorted(retyped);
		var allocationAfterPrune = AllocationMeter.sample();
		if (lowerToIr)
			for (name in names) {
				if (!modules.exists(name))
					continue;
				var state = modules.get(name),
					pending = [for (functionName in state.pendingIrFunctions.keys()) functionName];
				pending.sort(Reflect.compare);
				if (pending.length > 0)
					state = context.writableState(name, rollbackModules);
				for (functionName in pending) {
					if (token != null)
						token.check();
					var fn = state.typedFunctions.get(functionName);
					if (fn == null)
						throw 'Pending IR function "$functionName" has no typed function';
					state.irFunctions.set(functionName, IrGenerator.generateFunction(fn));
					if (!state.typedSourceRevisions.exists(functionName))
						throw 'Pending IR function "$functionName" has no typed source revision';
					state.irSourceRevisions.set(functionName, state.typedSourceRevisions.get(functionName));
					var version = state.irVersions.exists(functionName) ? state.irVersions.get(functionName) + 1 : 1;
					state.irVersions.set(functionName, version);
					state.pendingIrFunctions.remove(functionName);
					regenerated.push(functionName);
				}
			}
		regenerated = uniqueSorted(regenerated);
		// A runtime helper found while typing joins the program after this pass. What was typed so far is published, so the next
		// pass is an incremental one over it: it has the newly reachable modules to type, and the work of this pass carries over.
		if (includeTypedRuntimeDependencies(context, runtimeDependencies, typedNew.functions, owners, names, rollbackModules)) {
			context.setLastTypedProgram(typedNew);
			return run(context, entryModule, token, rollbackModules, snapshotDoneAt, lowerToIr, indexSemantics, [], [], [],
				{regenerated: regenerated, retyped: retyped});
		}
		var typingLoweringDoneAt = Sys.time() * 1000.0;
		var allocationAfterTyping = AllocationMeter.sample();
		var allocationPhases = [
			AllocationMeter.delta("graph", allocationAtStart, allocationAfterGraph),
			AllocationMeter.delta("semantic", allocationAfterGraph, allocationAfterSemantic),
			AllocationMeter.delta("typing-lowering", allocationAfterSemantic, allocationAfterTyping),
			AllocationMeter.delta("semantic-analysis", allocationAfterSemantic, allocationAfterAnalysis),
			AllocationMeter.delta("program-typing", allocationAfterAnalysis, allocationAfterProgramTyping),
			AllocationMeter.delta("typing-publication", allocationAfterProgramTyping, allocationAfterTyping),
			AllocationMeter.delta("publication-index-rebuild", allocationAfterProgramTyping, allocationAfterIndexRebuild),
			AllocationMeter.delta("publication-objects", allocationAfterIndexRebuild, allocationAfterObjects),
			AllocationMeter.delta("publication-functions", allocationAfterObjects, allocationAfterFunctions),
			AllocationMeter.delta("publication-index", allocationAfterFunctions, allocationAfterIndexPublication),
			AllocationMeter.delta("publication-prune", allocationAfterIndexPublication, allocationAfterPrune),
			AllocationMeter.delta("publication-prune-setup", allocationAfterIndexPublication, allocationBeforeModulePrune),
			AllocationMeter.delta("publication-prune-modules", allocationBeforeModulePrune, allocationAfterModulePrune),
			AllocationMeter.delta("publication-pending-ir", allocationAfterPrune, allocationAfterTyping)
		];
		for (phase in typerMetrics.allocationPhases)
			allocationPhases.push(phase);
		if (!lowerToIr)
			return {
				ir: null,
				moduleNames: names,
				typedProgram: typedNew,
				retyped: retyped,
				invalidations: semanticAssembly.invalidations,
				regenerated: regenerated,
				relocated: [],
				typerMetrics: typerMetrics,
				frontendGraphDoneAt: frontendGraphDoneAt,
				semanticAliasMs: semanticAssembly.aliasSetupMs,
				semanticCanonicalizationMs: semanticAssembly.canonicalizationMs,
				semanticContributionReuseMs: semanticAssembly.contributionReuseMs,
				semanticContributionRebuildMs: semanticAssembly.contributionRebuildMs,
				semanticInvalidationMs: semanticAssembly.invalidationMs,
				semanticAllocatedBytes: semanticAssembly.allocatedBytes,
				graphParseMs: graphParseMs,
				graphDependencyMs: graphDependencyMs,
				graphInitializationMs: graphInitializationMs,
				frontendRestarts: context.frontendRestarts,
				frontendPassFunctions: context.frontendPassFunctions,
				frontendDoneAt: frontendDoneAt,
				typingLoweringDoneAt: typingLoweringDoneAt,
				irAssemblyDoneAt: typingLoweringDoneAt,
				allocationPhases: allocationPhases,
				reused: null,
				reuseMiss: null
			};
		var cachedNames:Array<String> = [];
		for (moduleName in names) {
			if (!modules.exists(moduleName))
				continue;
			var state = modules.get(moduleName);
			for (functionName in state.irFunctions.keys())
				cachedNames.push(functionName);
		}
		cachedNames.sort(Reflect.compare);
		// A generated helper can be cached by more than one module (the one that asked for it first and the one that owns it now);
		// the program has it once, as a fresh build does.
		var distinctNames:Array<String> = [];
		for (name in cachedNames)
			if (distinctNames.length == 0 || distinctNames[distinctNames.length - 1] != name)
				distinctNames.push(name);
		cachedNames = distinctNames;
		var cached:Array<IrFunction> = [];
		for (functionName in cachedNames) {
			if (!owners.exists(functionName))
				throw 'Cached function "$functionName" has no source owner';
			var owner = owners.get(functionName);
			if (!modules.exists(owner))
				throw 'Cached function "$functionName" has no source module';
			var functions = modules.get(owner).irFunctions;
			if (!functions.exists(functionName))
				throw 'Cached function "$functionName" has no IR body';
			cached.push(functions.get(functionName));
		}
		dropUnusedKeyPathFields(typedNew, cached);
		if (token != null)
			token.check();
		var resolvedObjects = resolvedObjectsFrom(objectCache, typedNew, functionNamesOf(cachedNames, typedNew));
		var objectNames = [for (name in resolvedObjects.keys()) name];
		objectNames.sort(Reflect.compare);
		var irNatives = context.irNatives();
		for (native in IrProgramAssembler.nativesFrom(typedNew)) {
			for (existing in irNatives)
				if (existing.name == native.name)
					throw 'Native "${native.name}" is declared more than once';
			irNatives.push(native);
		}
		var instrumentScope = context.instrumentScope();
		if (instrumentScope != null)
			for (native in compiler.ir.IrInstrumentation.natives())
				if (![for (existing in irNatives) existing.name].contains(native.name))
					irNatives.push(native);
		var irCNatives = context.irCNatives();
		for (native in IrProgramAssembler.cNativesFrom(typedNew))
			if (![for (existing in irCNatives) existing.name].contains(native.name))
				irCNatives.push(native);
		// A live HashLink build initializes the fields it adds to running objects (see `IrProgramAssembler.liveInitializersFrom`).
		var published = context.assembler,
			liveInitializers = context.livePatching
				&& !context.isWasmTarget()
				&& published.isPublished() ? IrProgramAssembler.liveInitializersFrom(typedNew, name -> published.publishedObject(name),
					(name, field) -> published.publishedField(name, field)) : [];
		var generated = {
			objects: [for (name in objectNames) resolvedObjects.get(name)],
			interfaces: IrGenerator.interfacesFrom(typedNew),
			enums: IrGenerator.enumsFrom(typedNew),
			staticFields: IrGenerator.staticFieldsFrom(typedNew),
			initializers: IrGenerator.staticInitializersFrom(typedNew, initializationClasses, cached).concat(liveInitializers),
			reflectable: IrProgramAssembler.reflectableObjectsFrom(typedNew)
		};
		// A plain build whose pipeline inputs equal the last build's gets that build's final IR: no pass runs. With HAXEON_CHECK_REUSE=1
		// the passes run anyway and the result is compared with the reused one.
		var inputs = pipelineInputs(context, instrumentScope, cached, generated.initializers, irNatives, irCNatives, generated.objects, generated.interfaces,
			generated.enums, generated.staticFields, entryPoint, generated.reflectable),
			previousPipeline = context.pipelineSnapshot,
			reuseMiss = context.livePatching ? "live patching" : previousPipeline == null ? "no earlier build" : previousPipeline.mismatch(inputs),
			matchesPrevious = reuseMiss == null, checkingReuse = Sys.getEnv("HAXEON_CHECK_REUSE") == "1",
			reusedPipeline:Null<PipelineSnapshot> = matchesPrevious ? previousPipeline : null, ir:IrProgram, inlinerChanged:Array<String>;
		if (matchesPrevious && !checkingReuse) {
			ir = previousPipeline.ir;
			inlinerChanged = [];
		} else {
			ir = IrGenerator.assemble(cached, irNatives, generated.objects, generated.interfaces, generated.enums, generated.staticFields,
				generated.initializers, entryPoint, irCNatives, generated.reflectable, context.inlineCache().staticChecks, context.valueArrayTarget(),
				context.exportedFunctions());
			var cNativeNames = [for (native in irCNatives) native.name].join(","),
				ownPrints:Map<String, String> = [];
			for (fn in cached)
				if (PositionalName.is(fn.name))
					ownPrints.set(fn.name, context.inlineCache().positionalFingerprint(fn, cNativeNames));
			context.inlineCache().finishPositionalFingerprints();
			ir.positionalFingerprints = PositionalName.nested(ownPrints);
			if (context.livePatching) {
				var texts:Map<String, String> = [for (state in context.modules) state.source.path => state.source.text];
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
			var semantic = context.cachedSemanticProgram;
			if (context.livePatching && !context.isWasmTarget() && semantic != null)
				ir.parameterDefaults = parameterDefaults(ir, semantic.signatures);
			var valueArrayTarget = context.valueArrayTarget();
			compiler.ir.IrValueArrayProgramRewrite.rewriteAll(ir, valueArrayTarget == HashLink ? 64 : 32, valueArrayTarget);
			// Scalarize value joins before choosing the scalar call ABI. The HashLink call rewrite can introduce
			// further value joins, so it needs a second pass after that rewrite.
			if (context.isWasmTarget()) {
				compiler.ir.IrValueConstructors.rewrite(ir);
				compiler.ir.IrValuePhiScalarization.rewrite(ir);
				if (valueArrayTarget == Wasm32 || valueArrayTarget == WasmGc) {
					compiler.ir.IrScalarArguments.rewrite(ir, true);
					compiler.ir.IrValuePhiScalarization.rewrite(ir);
				}
			}
			if (!context.isWasmTarget()) {
				compiler.ir.IrValueConstructors.rewrite(ir);
				compiler.ir.IrValuePhiScalarization.rewrite(ir);
				compiler.ir.IrScalarArguments.rewrite(ir);
				compiler.ir.IrScalarClosures.rewrite(ir);
				compiler.ir.IrValuePhiScalarization.rewrite(ir);
			}
			var scalarObjects = compiler.ir.IrObjectTable.of([for (object in ir.objects) object.name => object]);
			ir.functions = [
				for (fn in ir.functions)
					compiler.ir.IrScalarReplacement.rewrite(fn, scalarObjects, false, !context.isWasmTarget())
			];
			compiler.ir.IrNullableScalarFlow.rewrite(ir);
			// Compare and publish the final IR even when only load/store forwarding is enabled.
			inlinerChanged = IrInliner.run(ir, context.inlineCache(), context.targetProfile(), context.inlineEnabled(), instrumentScope);
			// The final IR is verified here, once, whatever backend follows: only the functions whose IR or reads of the program changed.
			if (!context.livePatching) {
				IrVerifier.verifyReusing(ir, context.verifyMemo);
				if (checkingReuse)
					try
						IrVerifier.verify(ir)
					catch (error:String)
						throw 'HAXEON_CHECK_REUSE: verification skipped a function that fails in full: $error';
			}
			if (matchesPrevious) {
				var difference = PipelineSnapshot.irDifference(previousPipeline.ir, ir);
				if (difference != null)
					throw 'HAXEON_CHECK_REUSE: the final IR reused for equal pipeline inputs differs from a fresh run ($difference)';
			}
			context.pipelineSnapshot = context.livePatching ? null : new PipelineSnapshot(inputs, ir);
		}
		// Regenerating a function's IR does not change it when the typed function is the same: a semantic invalidation
		// regenerates every function of a module whose declarations moved. Only functions whose final IR differs from the
		// published one, or that were typed again, need lowering and patching; the rest keep their lowered form.
		var changedIr:Map<String, Bool> = [for (name in inlinerChanged) name => true],
			retypedNow:Map<String, Bool> = [for (name in retyped) name => true],
			present:Map<String, Bool> = [for (fn in ir.functions) fn.name => true];
		regenerated = [
			for (name in regenerated)
				if (!present.exists(name) || changedIr.exists(name) || retypedNow.exists(name)) name
		];
		var listed:Map<String, Bool> = [for (name in regenerated) name => true];
		for (name in inlinerChanged)
			if (!listed.exists(name)) {
				listed.set(name, true);
				regenerated.push(name);
			}
		regenerated.sort(Reflect.compare);
		var relocated = matchesPrevious
			&& !checkingReuse ? [] : [for (name in context.inlineCache().relocated) if (!listed.exists(name)) name];
		var irAssemblyDoneAt = Sys.time() * 1000.0;
		allocationPhases.push(AllocationMeter.delta("ir-assembly", allocationAfterTyping, AllocationMeter.sample()));
		return {
			ir: ir,
			moduleNames: names,
			typedProgram: typedNew,
			retyped: retyped,
			invalidations: semanticAssembly.invalidations,
			regenerated: regenerated,
			relocated: relocated,
			typerMetrics: typerMetrics,
			frontendGraphDoneAt: frontendGraphDoneAt,
			semanticAliasMs: semanticAssembly.aliasSetupMs,
			semanticCanonicalizationMs: semanticAssembly.canonicalizationMs,
			semanticContributionReuseMs: semanticAssembly.contributionReuseMs,
			semanticContributionRebuildMs: semanticAssembly.contributionRebuildMs,
			semanticInvalidationMs: semanticAssembly.invalidationMs,
			semanticAllocatedBytes: semanticAssembly.allocatedBytes,
			graphParseMs: graphParseMs,
			graphDependencyMs: graphDependencyMs,
			graphInitializationMs: graphInitializationMs,
			frontendRestarts: context.frontendRestarts,
			frontendPassFunctions: context.frontendPassFunctions,
			frontendDoneAt: frontendDoneAt,
			typingLoweringDoneAt: typingLoweringDoneAt,
			irAssemblyDoneAt: irAssemblyDoneAt,
			allocationPhases: allocationPhases,
			reused: reusedPipeline,
			reuseMiss: reuseMiss
		};
		}

	/** Everything the IR pipeline reads for this build (see `PipelineInputs`). */
	static function pipelineInputs(context:CompilationContext, instrumentScope:Null<compiler.ir.IrInstrumentation.IrInstrumentationScope>,
			functions:Array<IrFunction>, initializers:Array<IrFunction>, natives:Array<compiler.ir.Ir.IrNative>, cNatives:Array<compiler.ir.Ir.IrCNative>,
			objects:Array<IrObject>, interfaces:Array<compiler.ir.Ir.IrInterface>, enums:Array<compiler.ir.Ir.IrEnum>,
			staticFields:Array<compiler.ir.Ir.IrStaticField>, entryPoint:Null<String>, reflectable:Null<Array<String>>):PipelineInputs {
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
			"inline:" + context.inlineEnabled(),
			"instrument:" + (instrumentScope == null ? "-" : Std.string(instrumentScope)),
			"exports:" + context.exportedFunctions().join(","),
			// Reflection ignores a name that has no object (a typed program can list an empty anonymous type no function uses), and no
			// pass gives such a name an object later.
			"reflectable:" + (reflectable == null ? "-" : [for (name in reflectable) if (objectNames.exists(name)) name].join(",")),
			"entry:" + entryPoint,
			"generator:" + IrGenerator.inputState()
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
		var module = context.loadSourceModuleDependency(compiler.runtime.RuntimeType.SPECIALIZED_MAP);
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
	static function pruneUnusedKeyPathHelpers(context:CompilationContext, names:Array<String>, rollbackModules:Map<String, ModuleState>):Void {
		var used:Map<String, Bool> = [];
		for (name in names) {
			var state = context.modules.get(name);
			if (state != null)
				for (literals in state.keyPathUses)
					for (literal in literals.keys())
						used.set(literal, true);
		}
		for (name in names) {
			var state = context.modules.get(name);
			if (state == null)
				continue;
			var unused = [
				for (cached in state.typedFunctions.keys())
					if (StringTools.startsWith(cached, compiler.types.typing.KeyPathTyping.LITERAL_PREFIX)
						&& !used.exists(keyPathLiteralOf(cached))) cached
			];
			if (unused.length > 0)
				removeCachedFunctions(context.writableState(name, rollbackModules), unused);
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
	static function retainedFromPrevious(context:CompilationContext, modules:Array<String>, selected:Map<String, Bool>, lowerToIr:Bool,
			declared:Map<String, Bool>):Null<RetainedFromPrevious> {
		var result:Map<String, Bool> = [],
			retainedEnums:Map<String, Bool> = [],
			previous = context.lastTypedProgram;
		if (previous == null)
			return null;
		var known:Map<String, Bool> = [
			for (entry in previous.classes)
				if (entry.specializationOrigin != null || !declared.exists(entry.name)) entry.name => true
		], knownEnums:Map<String, Bool> = [
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
			var state = context.modules.get(module);
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
			var fn = functions.get(pending.pop());
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
	static function generatedHelpersStillCalled(modules:Map<String, compiler.modules.ModuleState>, names:Array<String>,
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction>, owners:Map<String, String>, invalidated:Map<String, Bool>):Map<String, Bool> {
		var reachable = [for (name in names) name => true];
		var holders:Map<String, compiler.modules.ModuleState> = [],
			kept:Map<String, Bool> = [],
			pending:Array<String> = [];
		for (name => state in modules) {
			for (cached => fn in state.typedFunctions) {
				if (!StringTools.startsWith(cached, "$value$equality:")
					&& !StringTools.startsWith(cached, "$enum-equals:")
					&& !StringTools.startsWith(cached, "$enum-reflect-equals:")
					&& !StringTools.startsWith(cached, "$enum-custom:")
					&& !StringTools.startsWith(cached, "$hash$value$equality:")
					&& !StringTools.startsWith(cached, "$wire:")
					&& !StringTools.startsWith(cached, "$json:"))
					continue;
				if (!holders.exists(cached) || reachable.exists(name))
					holders.set(cached, state);
				var origin = fn.origin;
				if (reachable.exists(name)
					&& (typedByName.exists(cached) || (origin != null && owners.exists(origin) && !invalidated.exists(origin)))) {
					kept.set(cached, true);
					pending.push(cached);
				}
			}
		}
		var result:Map<String, Bool> = [];
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
						case Call(_, callee, _) if (holders.exists(callee)):
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
						default:
					}
		}
		names.sort(Reflect.compare);
		return result;
	}

	static function sameDeclarations(previous:AstProgram, current:AstProgram):Bool {
		return sameNames([for (decl in previous.enums) decl.name], [for (decl in current.enums) decl.name])
			&& sameNames([for (decl in previous.enumAbstracts) decl.name], [for (decl in current.enumAbstracts) decl.name])
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
	static function resolvedObjectsFrom(objectCache:Map<String, IrObject>, typed:TypedProgram, functionNames:Map<String, Bool>):Map<String, IrObject> {
		var enums = [for (decl in typed.enums) decl.name => true], interfaces = [for (decl in typed.interfaces) decl.name => true], objects = [
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
		return false;
	}

	static function typeResolved(type:IrType, objects:Map<String, IrObject>, enums:Map<String, Bool>, interfaces:Map<String, Bool>):Bool
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
				var literal:Null<compiler.ir.Ir.IrDefault> = value == null ? (argument.optional == true ? NullDefault : null) : switch value {
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

	static function selectedSignaturesExplicit(program:AstProgram, selected:Map<String, Bool>):Bool {
		for (fn in program.functions)
			if (selected.exists(fn.name) && !explicitSignature(fn))
				return false;
		for (decl in program.classes)
			for (method in decl.methods)
				if (selected.exists(decl.name + "." + method.name) && !explicitSignature(method))
					return false;
		for (decl in program.abstracts)
			for (method in decl.methods)
				if (selected.exists(decl.name + "." + method.name) && !explicitSignature(method))
					return false;
		return true;
	}

	static function explicitSignature(fn:compiler.syntax.Ast.AstFunction):Bool {
		if ((switch (fn.result) {
			case InferredType: true;
			default: false;
		}))
			return false;
		for (argument in fn.arguments)
			if ((switch (argument.type) {
				case InferredType: true;
				default: false;
			}))
				return false;
		return true;
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
			throw 'Typed function "${fn.name}" disagrees about being a lambda: named like one: $named, origin kind lambda: $kind, origin: ${fn.origin}';
	}

	static function resolveFunctionModule(fn:compiler.types.TypedAst.TypedFunction, owners:Map<String, String>,
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction>, visiting:Map<String, Bool>):String {
		if (owners.exists(fn.name))
			return owners.get(fn.name);
		if (visiting.exists(fn.name))
			throw 'Cyclic generated-function ownership involving "${fn.name}"';
		visiting.set(fn.name, true);
		var origin = fn.origin;
		if (origin == null)
			throw 'No source module owns typed function "${fn.name}"';
		var module:String;
		if (owners.exists(origin))
			module = owners.get(origin);
		else if (initializerModule(origin, owners) != null)
			module = initializerModule(origin, owners);
		else if (typedByName.exists(origin))
			module = resolveFunctionModule(typedByName.get(origin), owners, typedByName, visiting);
		else
			throw 'No source module owns typed function "${fn.name}"';
		owners.set(fn.name, module);
		visiting.remove(fn.name);
		return module;
	}

	static inline var INITIALIZER_SUFFIX = ".__init";

	/** Field initializers are pseudo-bodies owned by the declaring class module. */
	static function initializerModule(name:String, owners:Map<String, String>):Null<String> {
		if (!StringTools.endsWith(name, INITIALIZER_SUFFIX))
			return null;
		var className = name.substr(0, name.length - INITIALIZER_SUFFIX.length);
		return owners.get(className + ".new");
	}

	static function includeTypedRuntimeDependencies(context:CompilationContext, dependencies:Array<{var functionName:String; var target:String;}>,
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
			var target = context.loadSourceModuleDependency(dependency.target);
			if (target == null)
				throw 'Typed runtime dependency "${dependency.target}" from "${dependency.functionName}" has no source module';
			if (names.indexOf(target) >= 0)
				continue;
			var fn = typedByName.get(dependency.functionName),
				owner:Null<String> = null;
			if (StringTools.startsWith(dependency.functionName, compiler.types.typing.RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX))
				owner = context.declarationOwner(dependency.functionName.substr(compiler.types.typing.RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX.length));
			else if (fn != null)
				owner = resolveFunctionModule(fn, owners, typedByName, []);
			else
				owner = initializerModule(dependency.functionName, owners);
			if (owner == null)
				throw 'Typed runtime dependency from unknown function "${dependency.functionName}"';
			var state = context.writableState(owner, rollbackModules);
			if (state.dependencies.indexOf(target) < 0) {
				context.frontendRestarts.push('${dependency.functionName} needs $target');
				state.dependencies.push(target);
				state.dependencies.sort(Reflect.compare);
				changed = true;
			}
		}
		return changed;
	}

	static function indexTypedInitializers(context:CompilationContext, typed:TypedProgram, reindexedModules:Map<String, Bool>):Void {
		for (classDecl in typed.classes)
			for (module in reindexedModules.keys()) {
				if (!context.modules.exists(module))
					continue;
				var state = context.modules.get(module),
					model = state.semanticModel;
				if (model == null || !modelOwnsType(model.program, classDecl.name))
					continue;
				for (field in classDecl.fields)
					if (field.initializer != null)
						model.index.indexTypedInitializer(classDecl.name + "." + field.name, field.initializer, context.resolveSemanticSymbol,
							context.resolveSemanticEnumCase);
			}
	}

	/** Replace provisional edges with dependencies proven by typed resolution. */
	static function publishResolvedDependencies(context:CompilationContext, typed:TypedProgram, reindexedModules:Map<String, Bool>,
			rollbackModules:Map<String, ModuleState>):Void {
		for (module in reindexedModules.keys()) {
			var state = context.writableState(module, rollbackModules),
				model = state.semanticModel;
			if (model == null)
				continue;
			var resolved:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>> = [];
			for (owner => dependencies in state.semanticDependencies)
				for (dependency in dependencies)
					if (dependency.kind != SemanticDependencyKind.Body && dependency.kind != SemanticDependencyKind.Initializer) {
						var targetId = dependency.targetId == null ? context.resolveSemanticType(dependency.target) : dependency.targetId;
						SemanticDependencyCollector.addDependency(resolved, owner, dependency.kind, dependency.target, targetId);
					}
			for (dependency in model.index.resolvedDependencies())
				SemanticDependencyCollector.addDependency(resolved, dependency.owner, dependency.kind, dependency.target, dependency.targetId);
			for (name => fn in state.typedFunctions)
				if (state.typedSourceRevisions.get(name) == state.revision) {
					for (argument in fn.arguments)
						addResolvedTypeDependency(resolved, name, SemanticDependencyKind.Signature, argument.type, context);
					addResolvedTypeDependency(resolved, name, SemanticDependencyKind.Signature, fn.result, context);
				}
			for (classDecl in typed.classes)
				if (modelOwnsType(model.program, classDecl.name)) {
					if (classDecl.base != null)
						addResolvedNamedTypeDependency(resolved, classDecl.name, SemanticDependencyKind.Layout, classDecl.base, context);
					for (interfaceName in classDecl.interfaces)
						addResolvedNamedTypeDependency(resolved, classDecl.name, SemanticDependencyKind.Layout, interfaceName, context);
					for (field in classDecl.fields)
						addResolvedTypeDependency(resolved, classDecl.name, SemanticDependencyKind.Layout, field.type, context);
				}
			state.semanticDependencies = resolved;
		}
	}

	static function addResolvedTypeDependency(result:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>>, owner:String,
			kind:SemanticDependencyKind, type:CompilerType, context:CompilationContext):Void
		addResolvedTypeDependencyWithin(result, owner, kind, type, context, []);

	/** `explored` holds the anonymous structures already walked: one can contain itself, and a repeat adds nothing. */
	static function addResolvedTypeDependencyWithin(result:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>>, owner:String,
			kind:SemanticDependencyKind, type:CompilerType, context:CompilationContext, explored:Array<Array<compiler.types.Type.AnonymousField>>):Void
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
			case TFunction(arguments, resultType):
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

	static function addResolvedNamedTypeDependency(result:Map<String, Array<compiler.modules.ModuleState.SemanticDependency>>, owner:String,
			kind:SemanticDependencyKind, target:String, context:CompilationContext):Void {
		var targetId = context.resolveSemanticType(target);
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
