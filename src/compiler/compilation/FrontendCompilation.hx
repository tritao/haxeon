package compiler.compilation;

import compiler.Diagnostic.CompileError;
import compiler.ir.Ir.IrProgram;
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

typedef FrontendResult = {
	final ir:Null<IrProgram>;
	final moduleNames:Array<String>;
	final typedProgram:TypedProgram;
	final retyped:Array<String>;
	final invalidations:Array<compiler.semantic.Invalidation.InvalidatedArtifact>;
	final regenerated:Array<String>;
	final typerMetrics:TyperPhaseMetrics;
	final frontendDoneAt:Float;
	final typingLoweringDoneAt:Float;
	final irAssemblyDoneAt:Float;
}

/** Builds and validates the reachable source graph through complete IR assembly. */
class FrontendCompilation {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			snapshotDoneAt:Float, ?lowerToIr = true, ?indexSemantics = true):FrontendResult {
		var modules = context.modules,
			graph = context.graph,
			objectCache = context.objectCache,
			genericSpecializations = context.genericSpecializations;
		if (token != null)
			token.check();
		var bodyChanged:Map<String, Bool> = [],
			signatureChanged:Map<String, Bool> = [],
			structuralChanged:Map<String, Bool> = [];
		var reachability = new ModuleReachability(modules, entryModule);
		while (reachability.hasNext(token)) {
			var reachableState = reachability.next();
			if (reachableState.ast == null) {
				reachableState = context.writableState(reachableState.name, rollbackModules);
				context.parse(reachableState, entryModule, bodyChanged, signatureChanged, structuralChanged);
				context.addTypeDependencies(reachableState);
			}
			reachability.includeDependencies(reachableState);
		}
		var names = reachability.finish(token);
		graph.rebuild(modules);
		var initializationNames = graph.initializationOrder(modules, names),
			initializationClasses:Array<String> = [];
		for (name in initializationNames) {
			var state = modules.get(name);
			var ast = state.parsedAst();
			for (classDecl in ast.classes)
				initializationClasses.push(ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name));
		}

		var semanticAssembly = SemanticAssembly.run(context, entryModule, token, rollbackModules, names, bodyChanged, signatureChanged, structuralChanged),
			canonicalProgram = semanticAssembly.canonicalProgram,
			functions = semanticAssembly.functions,
			owners = semanticAssembly.owners,
			generatedByModule = semanticAssembly.generatedByModule,
			selected = semanticAssembly.selected,
			entryPoint = semanticAssembly.entryPoint;
		var frontendDoneAt = Sys.time() * 1000.0;
		var typedNew:TypedProgram, typerMetrics:TyperPhaseMetrics;
		try {
			if (token != null)
				token.check();
			var previousSemantic = context.cachedSemanticProgram;
			var canReuseSemantic = previousSemantic != null
				&& CompilationContext.mapIsEmpty(signatureChanged)
				&& CompilationContext.mapIsEmpty(structuralChanged)
				&& canonicalProgram.classes.length == 0
				&& canonicalProgram.abstracts.length == 0
				&& canonicalProgram.enumAbstracts.length == 0
				&& CompilationContext.explicitFunctionSignatures(canonicalProgram.functions);
			var semantic:SemanticProgram;
			if (canReuseSemantic && previousSemantic != null)
				semantic = previousSemantic.replaceTopLevelBodies(canonicalProgram, selected);
			else
				semantic = SemanticProgram.analyze(canonicalProgram);
			context.cachedSemanticProgram = semantic;
			var typedResult = Typer.typeAnalyzedMeasured(semantic, selected, context.nativeSignatures(), entryPoint, genericSpecializations);
			typedNew = typedResult.program;
			typerMetrics = typedResult.metrics;
		} catch (error:CompileError) {
			for (name in names) {
				var state = modules.get(name);
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
				var model = modules.get(module).semanticModel;
				if (model != null)
					model.index.indexTypeReferences(context.resolveSemanticType, token);
			}
		}
		var retyped = [], regenerated = [];
		for (object in IrGenerator.objectsFrom(typedNew))
			objectCache.set(object.name, object);
		var touchedModules:Map<String, Bool> = [], typedByName:Map<String, compiler.types.TypedAst.TypedFunction> = [], generatedFunctions:Map<String, Bool> = [];
		for (fn in typedNew.functions) {
			typedByName.set(fn.name, fn);
			if (!owners.exists(fn.name))
				generatedFunctions.set(fn.name, true);
		}
		for (fn in typedNew.functions) {
			if (token != null)
				token.check();
			var generated = generatedFunctions.exists(fn.name), module = resolveFunctionModule(fn, owners, typedByName, []);
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
			if (indexSemantics && state.semanticModel != null)
				state.semanticModel.index.indexTypedFunction(fn, context.resolveSemanticSymbol, context.resolveSemanticEnumCase, token);
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
		if (indexSemantics) {
			indexTypedInitializers(context, typedNew, reindexedModules);
			publishResolvedDependencies(context, typedNew, reindexedModules, rollbackModules);
		}
		for (module in touchedModules.keys())
			modules.get(module).typeVersion++;
		for (name in names) {
			if (token != null)
				token.check();
			var state = modules.get(name),
				ast = state.parsedAst(),
				valid:Map<String, Bool> = [];
			for (fn in functions)
				if (owners.exists(fn.name) && owners.get(fn.name) == name)
					valid.set(fn.name, true);
			if (generatedByModule.exists(name)) {
				var lambdaNames = generatedByModule.get(name);
				for (lambdaName in lambdaNames.keys())
					valid.set(lambdaName, true);
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
					state.pendingIrFunctions.remove(cached);
					state.irFunctions.remove(cached);
					state.irSourceRevisions.remove(cached);
					state.irVersions.remove(cached);
				}
			}
		}
		retyped.sort(Reflect.compare);
		if (lowerToIr)
			for (name in names) {
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
					state.irSourceRevisions.set(functionName, state.typedSourceRevisions.get(functionName));
					var version = state.irVersions.exists(functionName) ? state.irVersions.get(functionName) + 1 : 1;
					state.irVersions.set(functionName, version);
					state.pendingIrFunctions.remove(functionName);
					regenerated.push(functionName);
				}
			}
		regenerated.sort(Reflect.compare);
		var typingLoweringDoneAt = Sys.time() * 1000.0;
		if (!lowerToIr)
			return {
				ir: null,
				moduleNames: names,
				typedProgram: typedNew,
				retyped: retyped,
				invalidations: semanticAssembly.invalidations,
				regenerated: regenerated,
				typerMetrics: typerMetrics,
				frontendDoneAt: frontendDoneAt,
				typingLoweringDoneAt: typingLoweringDoneAt,
				irAssemblyDoneAt: typingLoweringDoneAt
			};
		var cachedNames:Array<String> = [];
		for (moduleName in names) {
			var state = modules.get(moduleName);
			for (functionName in state.irFunctions.keys())
				cachedNames.push(functionName);
		}
		cachedNames.sort(Reflect.compare);
		var cached = [
			for (functionName in cachedNames)
				modules.get(owners.get(functionName)).irFunctions.get(functionName)
		];
		if (token != null)
			token.check();
		var objectNames = [for (name in objectCache.keys()) name];
		objectNames.sort(Reflect.compare);
		var irNatives = context.irNatives();
		for (native in IrProgramAssembler.nativesFrom(typedNew)) {
			for (existing in irNatives)
				if (existing.name == native.name)
					throw 'Native "${native.name}" is declared more than once';
			irNatives.push(native);
		}
		var ir = IrGenerator.assemble(cached, irNatives, [for (name in objectNames) objectCache.get(name)], IrGenerator.interfacesFrom(typedNew),
			IrGenerator.enumsFrom(typedNew), IrGenerator.staticFieldsFrom(typedNew), IrGenerator.staticInitializerFrom(typedNew, initializationClasses),
			entryPoint);
		var irAssemblyDoneAt = Sys.time() * 1000.0;
		return {
			ir: ir,
			moduleNames: names,
			typedProgram: typedNew,
			retyped: retyped,
			invalidations: semanticAssembly.invalidations,
			regenerated: regenerated,
			typerMetrics: typerMetrics,
			frontendDoneAt: frontendDoneAt,
			typingLoweringDoneAt: typingLoweringDoneAt,
			irAssemblyDoneAt: irAssemblyDoneAt
		};
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

	static function indexTypedInitializers(context:CompilationContext, typed:TypedProgram, reindexedModules:Map<String, Bool>):Void {
		for (classDecl in typed.classes)
			for (module in reindexedModules.keys()) {
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
			case TNullable(element), TArray(element):
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
