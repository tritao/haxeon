package compiler.compilation;

import compiler.Diagnostic.CompileError;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrFunction;
import compiler.ir.IrGenerator;
import compiler.ir.IrProgramAssembler;
import compiler.modules.ModuleReachability;
import compiler.modules.ModuleState;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.SemanticAssembly;
import compiler.service.CancellationToken;
import compiler.semantic.SemanticProgram;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.Type.CompilerType;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.SemanticDependencyCollector;
import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstType;
import compiler.compilation.AllocationMeter.PhaseAllocation;

typedef FrontendResult = {
	final ir:Null<IrProgram>;
	final moduleNames:Array<String>;
	final typedProgram:TypedProgram;
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
	final frontendDoneAt:Float;
	final typingLoweringDoneAt:Float;
	final irAssemblyDoneAt:Float;
	final allocationPhases:Array<PhaseAllocation>;
}

/** Builds and validates the reachable source graph through complete IR assembly. */
class FrontendCompilation {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			snapshotDoneAt:Float, ?lowerToIr = true, ?indexSemantics = true):FrontendResult {
		var allocationAtStart = AllocationMeter.sample();
		var modules = context.modules,
			graph = context.graph,
			objectCache = context.objectCache,
			genericSpecializations = context.genericSpecializations;
		if (token != null)
			token.check();
		var bodyChanged:Map<String, Bool> = [],
			signatureChanged:Map<String, Bool> = [],
			structuralChanged:Map<String, Bool> = [],
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
				if (cachedReachability.dependencyKeys.get(name) != state.dependencies.join("\x00"))
					reuseGraph = false;
			}
		if (!CompilationContext.mapIsEmpty(structuralChanged))
			reuseGraph = false;
		if (reuseGraph && cachedReachability != null) {
			names = cachedReachability.names.copy();
			initializationClasses = cachedReachability.initializationClasses.copy();
		} else {
			var reachability = new ModuleReachability(modules, entryModule);
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
		var frontendGraphDoneAt = Sys.time() * 1000.0;
		var allocationAfterGraph = AllocationMeter.sample();

		var semanticAssembly = SemanticAssembly.run(context, entryModule, token, rollbackModules, names, bodyChanged, signatureChanged, structuralChanged),
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
		var purityQueries:Map<String, Map<String, Bool>>,
			noReturnQueries:Map<String, Map<String, Bool>>;
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
				context.nativeLayoutTarget(), canReuseSemantic ? context.lastTypedProgram : null);
			allocationAfterProgramTyping = AllocationMeter.sample();
			typedNew = typedResult.program;
			IrGenerator.bindEnumConstructors(typedNew.enums);
			IrGenerator.bindDynamicObjectLiterals(!context.isWasmTarget());
			IrGenerator.bindNativeArrayChecks(true);
			typerMetrics = typedResult.metrics;
			purityQueries = typedResult.purityQueries;
			noReturnQueries = typedResult.noReturnQueries;
			if (includeTypedRuntimeDependencies(context, typedResult.runtimeDependencies, typedNew, owners, names, rollbackModules))
				return run(context, entryModule, token, rollbackModules, snapshotDoneAt, lowerToIr, indexSemantics);
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
		var retyped = [], regenerated = [];
		var previousTyped = context.lastTypedProgram;
		if (previousTyped != null) {
			var currentClasses = [for (classDecl in typedNew.classes) classDecl.name => true];
			for (classDecl in previousTyped.classes)
				if (!currentClasses.exists(classDecl.name))
					objectCache.remove(classDecl.name);
		}
		for (object in IrGenerator.objectsFrom(typedNew))
			objectCache.set(object.name, object);
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
			if (indexSemantics && state.semanticModel != null)
				state.semanticModel.index.indexTypedFunction(fn, context.resolveSemanticSymbol, context.resolveSemanticEnumCase, token);
			var semanticOrigin = fn.genericOrigin;
			var semanticallyInvalidated = invalidated.exists(fn.name) || semanticOrigin != null && invalidated.exists(semanticOrigin);
			if (!semanticallyInvalidated && StringTools.startsWith(fn.name, "$lambda:"))
				for (origin in invalidated.keys())
					if (StringTools.startsWith(fn.name, "$lambda:" + origin + ":")) {
						semanticallyInvalidated = true;
						break;
					}
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
			if (generatedByModule.exists(name)) {
				var lambdaNames = generatedByModule.get(name);
				for (lambdaName in lambdaNames.keys())
					valid.set(lambdaName, true);
			}
			// An unchanged caller can retain a call to a generated specialization.
			// Such bodies are absent from this request's typedNew, but must survive
			// pruning as long as their source origin still exists and is unchanged.
			var retainedSpecializations:Map<String, Bool> = [];
			var hasRetainedSpecializations = false;
			for (cached => fn in state.typedFunctions) {
				var origin = fn.genericOrigin;
				if (origin != null && owners.exists(origin) && !selected.exists(origin)) {
					valid.set(cached, true);
					owners.set(cached, name);
					retainedSpecializations.set(cached, true);
					hasRetainedSpecializations = true;
				}
			}
			if (hasRetainedSpecializations)
				for (nested in state.typedFunctions.keys()) {
					if (!StringTools.startsWith(nested, "$lambda:"))
						continue;
					for (specialization in retainedSpecializations.keys())
						if (StringTools.startsWith(nested, "$lambda:" + specialization + ":")) {
							valid.set(nested, true);
							owners.set(nested, name);
							break;
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
			var removed = [for (cached in state.typedFunctions.keys()) if (!valid.exists(cached)) cached];
			if (removed.length > 0) {
				state = context.writableState(name, rollbackModules);
				for (cached in removed) {
					state.typedFunctions.remove(cached);
					state.typedSourceRevisions.remove(cached);
					state.purityQueries.remove(cached);
					state.noReturnQueries.remove(cached);
					state.pendingIrFunctions.remove(cached);
					state.irFunctions.remove(cached);
					state.irSourceRevisions.remove(cached);
					state.irVersions.remove(cached);
				}
			}
		}
		var allocationAfterModulePrune = AllocationMeter.sample();
		retyped.sort(Reflect.compare);
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
		regenerated.sort(Reflect.compare);
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
				frontendDoneAt: frontendDoneAt,
				typingLoweringDoneAt: typingLoweringDoneAt,
				irAssemblyDoneAt: typingLoweringDoneAt,
				allocationPhases: allocationPhases
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
		if (token != null)
			token.check();
		var resolvedObjects = resolvedObjectsFrom(objectCache, typedNew);
		var objectNames = [for (name in resolvedObjects.keys()) name];
		objectNames.sort(Reflect.compare);
		var irNatives = context.irNatives();
		for (native in IrProgramAssembler.nativesFrom(typedNew)) {
			for (existing in irNatives)
				if (existing.name == native.name)
					throw 'Native "${native.name}" is declared more than once';
			irNatives.push(native);
		}
		var irCNatives = context.irCNatives();
		for (native in IrProgramAssembler.cNativesFrom(typedNew))
			if (![for (existing in irCNatives) existing.name].contains(native.name))
				irCNatives.push(native);
		var ir = IrGenerator.assemble(cached, irNatives, [for (name in objectNames) resolvedObjects.get(name)], IrGenerator.interfacesFrom(typedNew),
			IrGenerator.enumsFrom(typedNew), IrGenerator.staticFieldsFrom(typedNew), IrGenerator.staticInitializersFrom(typedNew, initializationClasses),
			entryPoint, irCNatives);
		var irAssemblyDoneAt = Sys.time() * 1000.0;
		allocationPhases.push(AllocationMeter.delta("ir-assembly", allocationAfterTyping, AllocationMeter.sample()));
		return {
			ir: ir,
			moduleNames: names,
			typedProgram: typedNew,
			retyped: retyped,
			invalidations: semanticAssembly.invalidations,
			regenerated: regenerated,
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
			frontendDoneAt: frontendDoneAt,
			typingLoweringDoneAt: typingLoweringDoneAt,
			irAssemblyDoneAt: irAssemblyDoneAt,
			allocationPhases: allocationPhases
		};
	}

	/** Body-only semantic reuse keeps every previous declaration, so it is valid only for an identical declaration set. */
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
	static function resolvedObjectsFrom(objectCache:Map<String, IrObject>, typed:TypedProgram):Map<String, IrObject> {
		var enums = [for (decl in typed.enums) decl.name => true],
			interfaces = [for (decl in typed.interfaces) decl.name => true],
			objects = [for (name => object in objectCache) name => object];
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

	static function typeResolved(type:IrType, objects:Map<String, IrObject>, enums:Map<String, Bool>, interfaces:Map<String, Bool>):Bool
		return switch type {
			case Obj(name): objects.exists(name);
			case Enum(name): enums.exists(name);
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
		if (fn.result == InferredType)
			return false;
		for (argument in fn.arguments)
			if (argument.type == InferredType)
				return false;
		return true;
	}

	static function resolveFunctionModule(fn:compiler.types.TypedAst.TypedFunction, owners:Map<String, String>,
			typedByName:Map<String, compiler.types.TypedAst.TypedFunction>, visiting:Map<String, Bool>):String {
		if (owners.exists(fn.name))
			return owners.get(fn.name);
		if (visiting.exists(fn.name))
			throw 'Cyclic generated-function ownership involving "${fn.name}"';
		visiting.set(fn.name, true);
		var origin = fn.genericOrigin;
		if (origin == null)
			throw 'No source module owns typed function "${fn.name}"';
		var module:String;
		if (owners.exists(origin))
			module = owners.get(origin);
		else if (typedByName.exists(origin))
			module = resolveFunctionModule(typedByName.get(origin), owners, typedByName, visiting);
		else
			throw 'No source module owns typed function "${fn.name}"';
		owners.set(fn.name, module);
		visiting.remove(fn.name);
		return module;
	}

	static function includeTypedRuntimeDependencies(context:CompilationContext, dependencies:Array<{final functionName:String; final target:String;}>,
			typed:TypedProgram, owners:Map<String, String>, names:Array<String>, rollbackModules:Map<String, ModuleState>):Bool {
		var typedByName:Map<String, compiler.types.TypedAst.TypedFunction> = [];
		for (fn in typed.functions)
			typedByName.set(fn.name, fn);
		var changed = false;
		for (dependency in dependencies) {
			if (names.indexOf(dependency.target) >= 0)
				continue;
			var target = context.loadSourceModuleDependency(dependency.target);
			if (target == null)
				throw 'Typed runtime dependency "${dependency.target}" from "${dependency.functionName}" has no source module';
			if (names.indexOf(target) >= 0)
				continue;
			var fn = typedByName.get(dependency.functionName);
			if (fn == null)
				throw 'Typed runtime dependency from unknown function "${dependency.functionName}"';
			var owner = resolveFunctionModule(fn, owners, typedByName, []),
				state = context.writableState(owner, rollbackModules);
			if (state.dependencies.indexOf(target) < 0) {
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
		switch type {
			case TAbstract(name, arguments, representation):
				addResolvedNamedTypeDependency(result, owner, kind, name, context);
				for (argument in arguments)
					addResolvedTypeDependency(result, owner, kind, argument, context);
				addResolvedTypeDependency(result, owner, kind, representation, context);
			case TInstance(_, name, arguments):
				addResolvedNamedTypeDependency(result, owner, kind, name, context);
				for (argument in arguments)
					addResolvedTypeDependency(result, owner, kind, argument, context);
			case TNullable(element), TArray(element), TIterator(element):
				addResolvedTypeDependency(result, owner, kind, element, context);
			case TMap(key, value):
				addResolvedTypeDependency(result, owner, kind, key, context);
				addResolvedTypeDependency(result, owner, kind, value, context);
			case TFunction(arguments, resultType):
				for (argument in arguments)
					addResolvedTypeDependency(result, owner, kind, argument, context);
				addResolvedTypeDependency(result, owner, kind, resultType, context);
			case TAnonymous(_, fields):
				for (field in fields)
					addResolvedTypeDependency(result, owner, kind, field.type, context);
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
