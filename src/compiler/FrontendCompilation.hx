package compiler;

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

typedef FrontendResult = {
	final ir:Null<IrProgram>;
	final moduleNames:Array<String>;
	final typedProgram:TypedProgram;
	final retyped:Array<String>;
	final regenerated:Array<String>;
	final typerMetrics:TyperPhaseMetrics;
	final frontendDoneAt:Float;
	final typingLoweringDoneAt:Float;
	final irAssemblyDoneAt:Float;
}

/** Builds and validates the reachable source graph through complete IR assembly. */
class FrontendCompilation {
	public static function run(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			snapshotDoneAt:Float, ?lowerToIr = true):FrontendResult {
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
		var retyped = [], regenerated = [];
		for (object in IrGenerator.objectsFrom(typedNew))
			objectCache.set(object.name, object);
		var touchedModules:Map<String, Bool> = [];
		for (fn in typedNew.functions) {
			if (token != null)
				token.check();
			var module:String;
			if (owners.exists(fn.name))
				module = owners.get(fn.name);
			else {
				var genericOrigin = fn.genericOrigin;
				if (genericOrigin == null || !owners.exists(genericOrigin))
					throw 'No source module owns typed function "${fn.name}"';
				module = owners.get(genericOrigin);
				owners.set(fn.name, module);
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
			if (state.semanticModel != null)
				state.semanticModel.index.indexTypedFunction(fn);
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
			regenerated: regenerated,
			typerMetrics: typerMetrics,
			frontendDoneAt: frontendDoneAt,
			typingLoweringDoneAt: typingLoweringDoneAt,
			irAssemblyDoneAt: irAssemblyDoneAt
		};
	}
}
