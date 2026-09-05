package compiler.modules;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrGenerator;
import compiler.types.Typer;
import compiler.types.SemanticSignature;
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.HlCode;
import compiler.hl.HlModuleAssembler;
import compiler.hl.HlPatchWriter;
import compiler.hl.HlRuntimeIdentity;
import compiler.hl.HlAssemblerStateCodec;
import haxe.io.Bytes;
import compiler.types.Type.CompilerType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;
import compiler.service.CancellationToken;
import compiler.abi.RuntimeAbi;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.modules.CompilerPublication.CompilerSnapshot;
import compiler.modules.CompilerPublication.PublicationStatus;
import compiler.modules.CompilerPublication.ReconnectDecision;
import compiler.modules.CompilerPublication.ReconnectReason;
import compiler.modules.ModuleState.SemanticDependency;
import compiler.modules.ModuleState.SemanticDependencyKind;

typedef NativeFunction = {final name:String; final library:String; final symbol:String; final arguments:Array<CompilerType>; final result:CompilerType;}

typedef CompileResult = {
	final ir:IrProgram;
	final module:HlCode;
	final retyped:Array<String>;
	final regenerated:Array<String>;
	final changedFunctions:Array<Int>;
	final requiresReload:Bool;
	final reloadReasons:Array<AbiChange>;
	final functionIndices:Map<String, Int>;
	final functionIds:Map<String, Int>;
	final runtimeIdentity:Bytes;
	final revision:Int;
	final patchBytes:Null<Bytes>;
	final metrics:CompileMetrics;
}

typedef CompileMetrics = {
	final elapsedMs:Float;
	final modules:Int;
	final retypedFunctions:Int;
	final regeneratedFunctions:Int;
	final changedFunctions:Int;
	final moduleFunctions:Int;
	final moduleNatives:Int;
	final patchBytes:Int;
}

typedef ValidationResult = {
	final valid:Bool;
	final diagnostic:Null<Diagnostic>;
}

class Compiler {
	public final modules:Map<String, ModuleState> = [];

	/** Last successfully assembled typed program; failed edits never replace it. */
	public var lastTypedProgram:Null<TypedProgram> = null;

	final graph = new ModuleGraph();
	var assembler:HlModuleAssembler;
	final moduleId:Bytes;

	public var types(default, null):TypeRegistry;

	final natives:Map<String, NativeFunction> = [];
	var objectCache:Map<String, IrObject> = [];
	var publishedAbi:Null<RuntimeAbiDescriptor>;
	var compiledOnce = false;
	final publication = new CompilerPublication();
	var rehydrationBaseline:Null<Map<String, Bytes>>;

	public function new(?identityState:Bytes) {
		if (identityState == null) {
			moduleId = HlRuntimeIdentity.createModuleId();
			assembler = new HlModuleAssembler();
			types = new TypeRegistry();
		} else {
			var identity = HlRuntimeIdentity.decodePersistent(identityState);
			moduleId = identity.moduleId;
			assembler = identity.assemblerState == null ? new HlModuleAssembler(identity.stableIds) : HlAssemblerStateCodec.decode(identity.assemblerState);
			for (name => id in identity.stableIds)
				if (assembler.cache.stableIds.get(name) != id)
					throw "Assembler stable identities do not match compiler state";
			for (name => id in assembler.cache.stableIds)
				if (identity.stableIds.get(name) != id)
					throw "Assembler stable identities do not match compiler state";
			types = new TypeRegistry(identity.typeState);
			publishedAbi = identity.publishedAbi;
			if (identity.publicationTracking)
				publication.enable(identity.acknowledgedRevision, identity.acknowledgedAbi, identity.assemblerState != null);
			if (identity.assemblerState != null) {
				compiledOnce = true;
				beginRehydration(assembler);
			}
		}
	}

	public function exportIdentityState():Bytes {
		var state = publication.persistence();
		var backend = state.tracking && state.revision > 0 ? HlAssemblerStateCodec.encode(assembler) : null;
		return HlRuntimeIdentity.encodePersistent(moduleId, assembler.cache.stableIds, types.exportState(), publishedAbi, state.tracking, state.revision,
			state.abi, backend);
	}

	public function enablePublicationTracking():Void {
		publication.enable();
	}

	public function publicationStatus():PublicationStatus
		return publication.status();

	public function reconcileRuntime(runtimeModuleId:Bytes, runtimeRevision:Int):ReconnectDecision {
		if (runtimeModuleId.length != moduleId.length || runtimeModuleId.compare(moduleId) != 0)
			return ReloadDomain(ModuleIdentityMismatch);
		return publication.reconcile(runtimeRevision);
	}

	function beginRehydration(restored:HlModuleAssembler):Void {
		rehydrationBaseline = [];
		for (name => fn in restored.cache.functions)
			rehydrationBaseline.set(name, compiler.ir.IrFunctionStateCodec.encode(fn));
	}

	public function acknowledgePublication(revision:Int):Void
		publication.acknowledge(revision);

	public function rejectPublication(revision:Int):Void {
		var candidate = publication.reject(revision);
		restore(candidate.snapshot);
		assembler = candidate.assembler;
	}

	public function registerNative(name:String, library:String, symbol:String, arguments:Array<CompilerType>, result:CompilerType):Void {
		if (compiledOnce)
			throw "Native registrations are frozen after the first compilation";
		if (name == "__exit"
			|| name == "__array_alloc_i32"
			|| name == "__array_alloc_f64"
			|| name == "__array_alloc_bytes"
			|| name == "__array_alloc_bool"
			|| name == "__array_alloc_ref"
			|| StringTools.startsWith(name, "__array_")
			|| StringTools.startsWith(name, "__map_")
			|| name == "__string_concat"
			|| name == "__string_length"
			|| name == "__string_equal"
			|| name == "__string_index_of"
			|| name == "__string_substring")
			throw 'Native "$name" is reserved by the compiler runtime ABI';
		if (natives.exists(name))
			throw 'Native "$name" is already registered';
		natives.set(name, {
			name: name,
			library: library,
			symbol: symbol,
			arguments: arguments.copy(),
			result: result
		});
	}

	public function compact(entryModule:String):CompileResult {
		assembler = new HlModuleAssembler(assembler.cache.stableIds);
		return compile(entryModule);
	}

	public function update(path:String, source:String):ModuleState {
		var name = ModulePath.fromFile(path),
			file = new SourceFile(path, source);
		var state = modules.get(name);
		if (state == null) {
			state = new ModuleState(name, file);
			modules.set(name, state);
		} else
			state.update(file);
		return state;
	}

	/**
		Validate an unsaved edit without mutating this compiler's live snapshot.
		The candidate is rebuilt from the persistent identity state and current
		sources; callers can then decide whether to commit the edit normally.
	 */
	public function validate(path:String, source:String, entryModule:String, ?token:CancellationToken):ValidationResult {
		var candidate = fork(), moduleName = ModulePath.fromFile(path);
		for (name in [for (name in candidate.modules.keys()) name])
			if (name == moduleName)
				candidate.modules.remove(name);
		candidate.update(path, source);
		try {
			candidate.compile(entryModule, token);
			return {valid: true, diagnostic: null};
		} catch (error:CompileError)
			return {valid: false, diagnostic: error.diagnostic};
	}

	/** Compile a temporary Int-returning expression without changing this compiler. */
	public function compileExpressionInt(expression:String):CompileResult {
		var candidate = fork();
		candidate.update("__repl__.hx", 'function __repl_value():Int { return $expression; } function main():Int { return __repl_value(); }');
		return candidate.compile("__repl__");
	}

	function fork():Compiler {
		var candidate = new Compiler(exportIdentityState());
		var nativeNames = [for (name in natives.keys()) name];
		nativeNames.sort(Reflect.compare);
		for (name in nativeNames) {
			var native = natives.get(name);
			candidate.registerNative(native.name, native.library, native.symbol, native.arguments, native.result);
		}
		var moduleNames = [for (name in modules.keys()) name];
		moduleNames.sort(Reflect.compare);
		for (name in moduleNames) {
			var state = modules.get(name);
			candidate.update(state.source.path, state.source.text);
		}
		return candidate;
	}

	public function compile(entryModule:String, ?token:CancellationToken):CompileResult {
		publication.beforeCompile();
		var snapshot = snapshot();
		var previousAssembler = assembler;
		try {
			var result = compileCandidate(entryModule, token);
			publication.candidate(result.revision, publishedAbi, snapshot, previousAssembler);
			return result;
		} catch (error:Dynamic) {
			var failedDiagnostics:Map<String, Array<Diagnostic>> = [];
			for (name => state in modules)
				failedDiagnostics.set(name, state.diagnostics.copy());
			restore(snapshot);
			for (name => diagnostics in failedDiagnostics)
				if (modules.exists(name))
					modules.get(name).diagnostics = diagnostics;
			throw error;
		}
	}

	function compileCandidate(entryModule:String, ?token:CancellationToken):CompileResult {
		var startedAt = haxe.Timer.stamp();
		if (token != null)
			token.check();
		if (!modules.exists(entryModule))
			throw 'Missing entry module "$entryModule"';
		var names = [for (name in modules.keys()) name];
		names.sort(Reflect.compare);
		var bodyChanged:Map<String, Bool> = [],
			signatureChanged:Map<String, Bool> = [],
			structuralChanged:Map<String, Bool> = [];
		for (name in names)
			if (token != null)
				token.check();
		for (name in names)
			parse(modules.get(name), entryModule, bodyChanged, signatureChanged, structuralChanged);
		if (token != null)
			token.check();
		graph.rebuild(modules);
		for (name in names)
			if (token != null)
				token.check();
		for (name in names)
			for (dependency in modules.get(name).dependencies)
				if (!modules.exists(dependency)) {
					var state = modules.get(name),
						span = state.source.span(0, state.source.text.length);
					var diagnostic = new Diagnostic("E2001", 'Missing module "$dependency"', span);
					state.diagnostics.push(diagnostic);
					throw new CompileError(diagnostic);
				}
		var initializationNames = graph.initializationOrder(modules, names),
			initializationClasses:Array<String> = [];
		for (name in initializationNames) {
			var state = modules.get(name);
			for (classDecl in state.ast.classes)
				initializationClasses.push(qualifiedTypeName(state.ast.packageName, classDecl.name));
		}

		var functions:Array<AstFunction> = [],
			programFunctions:Array<AstFunction> = [],
			typeAliases:Array<compiler.Ast.AstTypeAlias> = [],
			enums:Array<compiler.Ast.AstEnum> = [],
			interfaces:Array<compiler.Ast.AstInterface> = [],
			classes:Array<compiler.Ast.AstClass> = [],
			owners:Map<String, String> = [],
			generatedByModule:Map<String, Map<String, Bool>> = [],
			reverseCalls:Map<String, Array<String>> = [];
		for (name in names) {
			if (token != null)
				token.check();
			var state = modules.get(name),
				locals:Map<String, Bool> = [],
				aliases = importAliases(state.ast.imports);
			addDeclaredTypeAliases(aliases, state.ast, state.ast.packageName);
			for (interfaceDecl in state.ast.interfaces)
				interfaces.push(canonicalInterface(interfaceDecl, aliases, state.ast.packageName));
			for (alias in state.ast.aliases)
				typeAliases.push(canonicalAlias(alias, aliases, state.ast.packageName));
			for (enumDecl in state.ast.enums)
				enums.push(canonicalEnum(enumDecl, aliases, state.ast.packageName));
			for (fn in state.ast.functions)
				locals.set(fn.name, true);
			for (fn in state.ast.functions) {
				var canonical = canonicalFunction(fn, name, entryModule, locals, null, aliases);
				functions.push(canonical);
				programFunctions.push(canonical);
				owners.set(canonical.name, name);
				var calls:Map<String, Bool> = [];
				var aliases:Map<String, String> = [];
				for (statement in canonical.statements)
					scanCalls(statement, calls, aliases);
				collectLambdas(canonical.statements, canonical.name, name, generatedByModule);
				for (callee in calls.keys()) {
					var callers = reverseCalls.get(callee);
					if (callers == null) {
						callers = [];
						reverseCalls.set(callee, callers);
					}
					callers.push(canonical.name);
				}
			}
			for (classDecl in state.ast.classes) {
				var className = qualifiedTypeName(state.ast.packageName, classDecl.name);
				var classMethods:Array<AstFunction> = [];
				for (method in classDecl.methods) {
					var canonical = canonicalFunction(method, name, entryModule, locals, className + "." + method.name, aliases);
					functions.push(canonical);
					classMethods.push({
						name: method.name,
						isStatic: method.isStatic,
						arguments: canonical.arguments,
						result: canonical.result,
						span: method.span,
						statements: canonical.statements
					});
					owners.set(canonical.name, name);
					var calls:Map<String, Bool> = [];
					var aliases:Map<String, String> = [];
					for (statement in canonical.statements)
						scanCalls(statement, calls, aliases);
					collectLambdas(canonical.statements, canonical.name, name, generatedByModule);
					for (callee in calls.keys()) {
						var callers = reverseCalls.get(callee);
						if (callers == null) {
							callers = [];
							reverseCalls.set(callee, callers);
						}
						callers.push(canonical.name);
					}
				}
				classes.push({
					name: className,
					base: classDecl.base == null ? null : resolveTypeName(classDecl.base, aliases),
					interfaces: [
						for (interfaceName in classDecl.interfaces)
							resolveTypeName(interfaceName, aliases)
					],
					fields: [
						for (field in classDecl.fields)
							{
								name: field.name,
								type: canonicalType(field.type, aliases),
								initializer: field.initializer == null ? null : canonicalExpression(field.initializer, name, entryModule, locals, aliases),
								isStatic: field.isStatic,
								isFinal: field.isFinal,
								span: field.span
							}
					],
					methods: classMethods,
					span: classDecl.span
				});
				owners.set(className + ".new", name);
			}
		}
		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		var invalid:Map<String, Bool> = [];
		for (change in structuralChanged.keys()) {
			var separator = change.indexOf(":"),
				target = separator < 0 ? change : change.substr(separator + 1);
			for (state in modules)
				for (owner => dependencies in state.semanticDependencies)
					for (dependency in dependencies)
						if (sameDependencyTarget(dependency.target, target)) {
							var matchedFunction = false;
							for (fn in functions)
								if (fn.name == owner || StringTools.startsWith(fn.name, owner + ".")) {
									invalid.set(fn.name, true);
									matchedFunction = true;
								}
							if (matchedFunction)
								break;
						}
		}
		for (name in bodyChanged.keys())
			invalid.set(name, true);
		var work = [for (name in signatureChanged.keys()) name];
		while (work.length > 0) {
			if (token != null)
				token.check();
			var changed = work.pop();
			if (invalid.exists(changed)) {} else
				invalid.set(changed, true);
			var callers = reverseCalls.get(changed);
			if (callers != null)
				for (caller in callers)
					if (!invalid.exists(caller))
						work.push(caller);
		}
		var selected:Map<String, Bool> = [];
		for (name in invalid.keys())
			selected.set(name, true);
		var typedNew:TypedProgram;
		try {
			if (token != null)
				token.check();
			typedNew = Typer.typeSelected({
				packageName: null,
				imports: [],
				aliases: typeAliases,
				enums: enums,
				interfaces: interfaces,
				classes: classes,
				functions: programFunctions
			}, selected, nativeSignatures());
		} catch (error:CompileError) {
			for (name in names) {
				var state = modules.get(name);
				if (state.source.path == error.diagnostic.span.file.path)
					state.diagnostics.push(error.diagnostic);
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
			var module = owners.get(fn.name), state = modules.get(module);
			state.typedFunctions.set(fn.name, fn);
			retyped.push(fn.name);
			touchedModules.set(module, true);
			state.irFunctions.set(fn.name, IrGenerator.generateFunction(fn));
			regenerated.push(fn.name);
			var version = state.irVersions.get(fn.name);
			state.irVersions.set(fn.name, version == null ? 1 : version + 1);
		}
		for (module in touchedModules.keys())
			modules.get(module).typeVersion++;
		for (name in names) {
			if (token != null)
				token.check();
			var state = modules.get(name), valid:Map<String, Bool> = [];
			for (fn in functions)
				if (owners.get(fn.name) == name)
					valid.set(fn.name, true);
			var lambdaNames = generatedByModule.get(name);
			if (lambdaNames != null)
				for (lambdaName in lambdaNames.keys())
					valid.set(lambdaName, true);
			for (classDecl in state.ast.classes) {
				var className = qualifiedTypeName(state.ast.packageName, classDecl.name),
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
			for (cached in state.typedFunctions.keys())
				if (!valid.exists(cached)) {
					state.typedFunctions.remove(cached);
					state.irFunctions.remove(cached);
					state.irVersions.remove(cached);
				}
		}
		retyped.sort(Reflect.compare);
		regenerated.sort(Reflect.compare);
		var cachedNames:Array<String> = [];
		for (state in modules)
			for (functionName in state.irFunctions.keys())
				cachedNames.push(functionName);
		cachedNames.sort(Reflect.compare);
		var cached = [
			for (functionName in cachedNames)
				modules.get(owners.get(functionName)).irFunctions.get(functionName)
		];
		if (token != null)
			token.check();
		var objectNames = [for (name in objectCache.keys()) name];
		objectNames.sort(Reflect.compare);
		var ir = IrGenerator.assemble(cached, irNatives(), [for (name in objectNames) objectCache.get(name)], IrGenerator.interfacesFrom(typedNew),
			IrGenerator.enumsFrom(typedNew), IrGenerator.staticFieldsFrom(typedNew), IrGenerator.staticInitializerFrom(typedNew, initializationClasses));
		var nextAbi = RuntimeAbi.describe(ir),
			decision = PatchPlanner.plan(publishedAbi, nextAbi),
			reloadReasons:Array<AbiChange> = switch decision {
				case Patch: [];
				case ReloadDomain(reasons): reasons;
				case Reject(diagnostics): throw diagnostics.join("; ");
			};
		reloadReasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		if (reloadReasons.length > 0)
			decision = ReloadDomain(reloadReasons);
		var candidateAssembler = compiledOnce
			&& PatchPlanner.requiresFreshLayout(decision) ? new HlModuleAssembler(copyIndices(assembler.cache.stableIds)) : assembler.copy();
		var assembly = candidateAssembler.assemble(ir, rehydratedChanges(regenerated, ir), decision);
		if (token != null)
			token.check();
		var patchBytes = reloadReasons.length > 0
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, moduleId, assembly.changedSlots,
				stableIdsBySlot(candidateAssembler, assembly.functionIndices), assembly.revision - 1, assembly.revision, assembly.baseInts,
				assembly.baseFloats, assembly.baseStrings, assembly.baseTypes);
		lastTypedProgram = typedNew;
		publishedAbi = nextAbi;
		assembler = candidateAssembler;
		rehydrationBaseline = null;
		for (name in names) {
			var state = modules.get(name);
			state.lastGoodTokens = state.tokens;
			state.lastGoodAst = state.ast;
			state.lastGoodSource = state.source;
			state.lastGoodRevision = state.revision;
		}
		compiledOnce = true;
		return {
			ir: ir,
			module: assembly.module,
			retyped: retyped,
			regenerated: regenerated,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			reloadReasons: reloadReasons,
			functionIndices: copyIndices(assembly.functionIndices),
			functionIds: copyIndices(assembler.cache.stableIds),
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.revision, assembly.functionIndices, assembler.cache.stableIds),
			revision: assembly.revision,
			patchBytes: patchBytes,
			metrics: {
				elapsedMs: (haxe.Timer.stamp() - startedAt) * 1000.0,
				modules: names.length,
				retypedFunctions: retyped.length,
				regeneratedFunctions: regenerated.length,
				changedFunctions: assembly.changedFunctions.length,
				moduleFunctions: assembly.module.functions.length,
				moduleNatives: assembly.module.natives.length,
				patchBytes: patchBytes == null ? 0 : patchBytes.length
			}
		};
	}

	function rehydratedChanges(regenerated:Array<String>, program:IrProgram):Array<String> {
		if (rehydrationBaseline == null)
			return regenerated;
		var current:Map<String, compiler.ir.IrFunction> = [], changed = [];
		for (fn in program.functions)
			current.set(fn.name, fn);
		for (name in regenerated) {
			var old = rehydrationBaseline.get(name), next = current.get(name);
			if (old == null || next == null || old.compare(compiler.ir.IrFunctionStateCodec.encode(next)) != 0)
				changed.push(name);
		}
		return changed;
	}

	function snapshot():CompilerSnapshot {
		var moduleCopies:Map<String, ModuleState> = [],
			objectCopies:Map<String, IrObject> = [];
		for (name => state in modules)
			moduleCopies.set(name, state.copy());
		for (name => object in objectCache)
			objectCopies.set(name, object);
		return {
			modules: moduleCopies,
			types: types.copy(),
			objectCache: objectCopies,
			lastTypedProgram: lastTypedProgram,
			publishedAbi: publishedAbi,
			compiledOnce: compiledOnce,
			rehydrationBaseline: rehydrationBaseline
		};
	}

	function restore(snapshot:CompilerSnapshot):Void {
		for (name in [for (name in modules.keys()) name])
			modules.remove(name);
		for (name => state in snapshot.modules)
			modules.set(name, state);
		types = snapshot.types;
		objectCache = snapshot.objectCache;
		lastTypedProgram = snapshot.lastTypedProgram;
		publishedAbi = snapshot.publishedAbi;
		compiledOnce = snapshot.compiledOnce;
		rehydrationBaseline = snapshot.rehydrationBaseline;
	}

	function nativeSignatures():Map<String, {arguments:Array<CompilerType>, result:CompilerType}> {
		var result:Map<String, {arguments:Array<CompilerType>, result:CompilerType}> = [];
		for (name => native in natives)
			result.set(name, {arguments: native.arguments, result: native.result});
		return result;
	}

	function irNatives():Array<IrNative> {
		var names = [for (name in natives.keys()) name];
		names.sort(Reflect.compare);
		return [
			for (name in names) {
				var native = natives.get(name);
				{
					name: native.name,
					library: native.library,
					symbol: native.symbol,
					arguments: [for (type in native.arguments) irType(type)],
					result: irType(native.result)
				}
			}
		];
	}

	static function irType(type:CompilerType):compiler.ir.Ir.IrType
		return switch type {
			case TInt: I32;
			case TBool: Bool;
			case TFloat: F64;
			case TString: Bytes;
			case TDynamic: Dyn;
			case TVoid: Void;
			case TClass(name): Obj(name);
			case TMap(_, _): Abstract("map_string_i32");
			case TInterface(name): Virtual(name);
			case TEnum(name): Enum(name);
			case TNull: Void;
			case TNullable(element): irType(element);
			case TArray(element): Array(irType(element));
			case TFunction(arguments, result): Function([for (argument in arguments) irType(argument)], irType(result));
		};

	function stableIdsBySlot(sourceAssembler:HlModuleAssembler, layout:Map<String, Int>):Map<Int, Int> {
		var result:Map<Int, Int> = [];
		for (name => id in sourceAssembler.cache.stableIds)
			if (layout.exists(name))
				result.set(layout.get(name), id);
		return result;
	}

	function parse(state:ModuleState, entry:String, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>,
			structuralChanged:Map<String, Bool>):Void {
		if (state.ast != null)
			return;
		try {
			state.tokens = new Lexer(state.source).tokenize();
			state.ast = new Parser(state.tokens).parseProgram();
			state.parseVersion++;
		} catch (error:CompileError) {
			state.diagnostics.push(error.diagnostic);
			throw error;
		}
		var dependencies:Map<String, Bool> = [];
		if (state.ast.imports != null)
			for (dependency in state.ast.imports)
				dependencies.set(dependency, true);
		for (fn in state.ast.functions)
			for (statement in fn.statements)
				scanStatement(statement, dependencies);
		for (classDecl in state.ast.classes)
			for (field in classDecl.fields)
				if (field.initializer != null)
					scanExpression(field.initializer, dependencies);
		for (classDecl in state.ast.classes)
			dependencies.remove(classDecl.name);
		for (enumDecl in state.ast.enums)
			dependencies.remove(enumDecl.name);
		for (importPath in state.ast.imports) {
			var dot = importPath.lastIndexOf("."),
				alias = dot < 0 ? importPath : importPath.substr(dot + 1);
			if (alias != importPath)
				dependencies.remove(alias);
		}
		// Dotted native names such as Sys.time look like module-qualified calls
		// to the dependency scanner.  Registered natives own those prefixes and
		// must not require a source module with the same name.
		for (dependency in [for (dependency in dependencies.keys()) dependency])
			if (nativePrefixExists(dependency))
				dependencies.remove(dependency);
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
		var typeAliases = importAliases(state.ast.imports);
		addDeclaredTypeAliases(typeAliases, state.ast, state.ast.packageName);
		state.semanticDependencies = collectSemanticDependencies(state, entry, typeAliases);
		var signatures:Map<String, String> = [],
			bodies:Map<String, String> = [];
		var interfaces:Map<String, String> = [];
		for (interfaceDecl in state.ast.interfaces) {
			var signature = interfaceDecl.name + " extends " + interfaceDecl.bases.join(",") + " {" + [
				for (method in interfaceDecl.methods)
					method.name + ":" + signatureFingerprint(method, state.ast.aliases)
			].join(";") + "}";
			interfaces.set(interfaceDecl.name, signature);
			if (state.interfaceFingerprints.get(interfaceDecl.name) != signature)
				structuralChanged.set('interface:${interfaceDecl.name}', true);
		}
		for (old in state.interfaceFingerprints.keys())
			if (!interfaces.exists(old))
				structuralChanged.set('interface:$old', true);
		state.interfaceFingerprints = interfaces;
		var aliases:Map<String, String> = [];
		for (alias in state.ast.aliases) {
			var aliasName = qualifiedTypeName(state.ast.packageName, alias.name),
				signature = aliasName + "=" + SemanticSignature.parsed(alias.type, state.ast.aliases);
			aliases.set(aliasName, signature);
			if (state.aliasFingerprints.get(aliasName) != signature)
				structuralChanged.set('alias:$aliasName', true);
		}
		for (old in state.aliasFingerprints.keys())
			if (!aliases.exists(old))
				structuralChanged.set('alias:$old', true);
		state.aliasFingerprints = aliases;
		var enums:Map<String, String> = [];
		for (enumDecl in state.ast.enums) {
			var enumName = qualifiedTypeName(state.ast.packageName, enumDecl.name),
				signature = enumName + "{" + [
					for (caseDecl in enumDecl.cases)
						caseDecl.name + "(" + [
							for (param in caseDecl.params)
								SemanticSignature.parsed(param, state.ast.aliases)
						].join(",") + ")"
				].join(";") + "}";
			enums.set(enumName, signature);
			if (state.enumFingerprints.get(enumName) != signature)
				structuralChanged.set('enum:$enumName', true);
		}
		for (old in state.enumFingerprints.keys())
			if (!enums.exists(old))
				structuralChanged.set('enum:$old', true);
		state.enumFingerprints = enums;
		var staticInitializers:Map<String, String> = [],
			instanceInitializers:Map<String, String> = [];
		for (classDecl in state.ast.classes) {
			var className = qualifiedTypeName(state.ast.packageName, classDecl.name);
			for (field in classDecl.fields) {
				switch field.initializer {
					case null:
					case expression:
						var fieldName = className + "." + field.name,
							initializer = state.source.text.substring(field.span.start, field.span.end);
						if (field.isStatic) {
							staticInitializers.set(fieldName, initializer);
							if (state.staticInitializerFingerprints.get(fieldName) != initializer)
								structuralChanged.set('static:$fieldName', true);
						} else {
							instanceInitializers.set(fieldName, initializer);
							if (state.instanceInitializerFingerprints.get(fieldName) != initializer) {
								bodyChanged.set(className + ".new", true);
								if (classDecl.methods.filter(function(method) return method.name == "new").length == 0
									&& state.instanceInitializerFingerprints.get(fieldName) == null) {
									structuralChanged.set(className, true);
									signatureChanged.set(className + ".new", true);
								}
							}
						}
				}
			}
		}
		for (old in state.staticInitializerFingerprints.keys())
			if (!staticInitializers.exists(old))
				structuralChanged.set('static:$old', true);
		state.staticInitializerFingerprints = staticInitializers;
		for (old in state.instanceInitializerFingerprints.keys())
			if (!instanceInitializers.exists(old)) {
				var className = old.substr(0, old.lastIndexOf(".")),
					hasConstructor = false;
				for (classDecl in state.ast.classes)
					if (qualifiedTypeName(state.ast.packageName, classDecl.name) == className)
						for (method in classDecl.methods)
							if (method.name == "new")
								hasConstructor = true;
				bodyChanged.set(className + ".new", true);
				if (!hasConstructor) {
					structuralChanged.set(className, true);
					signatureChanged.set(className + ".new", true);
				}
			}
		state.instanceInitializerFingerprints = instanceInitializers;
		for (fn in state.ast.functions) {
			var canonical = state.name == entry && fn.name == "main" ? "main" : state.name + "." + fn.name;
			var signature = signatureFingerprint(fn, state.ast.aliases),
				body = state.source.text.substring(fn.span.start, fn.span.end);
			signatures.set(fn.name, signature);
			bodies.set(fn.name, body);
			if (state.signatureFingerprints.get(fn.name) != signature)
				signatureChanged.set(canonical, true);
			else if (state.bodyFingerprints.get(fn.name) != body)
				bodyChanged.set(canonical, true);
		}
		for (classDecl in state.ast.classes) {
			var className = qualifiedTypeName(state.ast.packageName, classDecl.name),
				baseName = classDecl.base == null ? null : resolveTypeName(classDecl.base, typeAliases);
			var classFields = [
				for (field in classDecl.fields)
					{name: field.name, type: SemanticSignature.parsed(field.type, state.ast.aliases)}
			], classMethods = [
				for (method in classDecl.methods)
					{name: method.name, signature: signatureFingerprint(method, state.ast.aliases)}
				];
			var typeResult = types.declareClass(className, baseName, classFields, classMethods);
			if (compiledOnce && typeResult.compatibility != Compatible)
				structuralChanged.set(className, true);
			for (method in classDecl.methods) {
				var localName = className + "." + method.name,
					canonical = localName,
					signature = signatureFingerprint(method, state.ast.aliases),
					body = state.source.text.substring(method.span.start, method.span.end);
				signatures.set(localName, signature);
				bodies.set(localName, body);
				if (state.signatureFingerprints.get(localName) != signature)
					signatureChanged.set(canonical, true);
				else if (state.bodyFingerprints.get(localName) != body)
					bodyChanged.set(canonical, true);
			}
		}
		for (old in state.signatureFingerprints.keys())
			if (!signatures.exists(old)) {
				var canonical = canonicalName(state.name, entry, old);
				signatureChanged.set(canonical, true);
			}
		state.signatureFingerprints = signatures;
		state.bodyFingerprints = bodies;
		state.dirty = false;
	}

	static function canonicalFunction(fn:AstFunction, module:String, entry:String, locals:Map<String, Bool>, ?explicitName:String,
			?aliases:Map<String, String>):AstFunction {
		var name = explicitName != null ? explicitName : module == entry && fn.name == "main" ? "main" : module + "." + fn.name;
		return {
			name: name,
			isStatic: fn.isStatic,
			arguments: [
				for (argument in fn.arguments)
					{name: argument.name, type: canonicalType(argument.type, aliases), span: argument.span}
			],
			result: canonicalType(fn.result, aliases),
			span: fn.span,
			statements: [for (s in fn.statements) canonicalStatement(s, module, entry, locals, aliases)]
		};
	}

	static function canonicalName(module:String, entry:String, local:String):String
		return module == entry && local == "main" ? "main" : local.indexOf(".") >= 0 ? local : module + "." + local;

	static function qualifiedTypeName(packageName:Null<String>, name:String):String
		return packageName == null || packageName.length == 0 ? name : packageName + "." + name;

	static function addDeclaredTypeAliases(aliases:Map<String, String>, program:compiler.Ast.AstProgram, packageName:Null<String>):Void {
		for (alias in program.aliases)
			aliases.set(alias.name, qualifiedTypeName(packageName, alias.name));
		for (enumDecl in program.enums)
			aliases.set(enumDecl.name, qualifiedTypeName(packageName, enumDecl.name));
		for (interfaceDecl in program.interfaces)
			aliases.set(interfaceDecl.name, qualifiedTypeName(packageName, interfaceDecl.name));
		for (classDecl in program.classes)
			aliases.set(classDecl.name, qualifiedTypeName(packageName, classDecl.name));
	}

	static function canonicalAlias(alias:compiler.Ast.AstTypeAlias, aliases:Map<String, String>, packageName:Null<String>):compiler.Ast.AstTypeAlias
		return {name: qualifiedTypeName(packageName, alias.name), type: canonicalType(alias.type, aliases), span: alias.span};

	static function canonicalEnum(enumDecl:compiler.Ast.AstEnum, aliases:Map<String, String>, packageName:Null<String>):compiler.Ast.AstEnum
		return {
			name: qualifiedTypeName(packageName, enumDecl.name),
			cases: [
				for (caseDecl in enumDecl.cases)
					{name: caseDecl.name, params: [for (param in caseDecl.params) canonicalType(param, aliases)], span: caseDecl.span}
			],
			span: enumDecl.span
		};

	static function canonicalInterface(interfaceDecl:compiler.Ast.AstInterface, aliases:Map<String, String>, packageName:Null<String>):compiler.Ast.AstInterface
		return {
			name: qualifiedTypeName(packageName, interfaceDecl.name),
			bases: [for (base in interfaceDecl.bases) resolveTypeName(base, aliases)],
			methods: [
				for (method in interfaceDecl.methods)
					{
						name: method.name,
						isStatic: false,
						arguments: [
							for (argument in method.arguments)
								{name: argument.name, type: canonicalType(argument.type, aliases), span: argument.span}
						],
						result: canonicalType(method.result, aliases),
						statements: [],
						span: method.span
					}
			],
			span: interfaceDecl.span
		};

	static function astTypeName(type:compiler.Ast.AstType):String
		return switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case NamedType(name): name;
			case ArrayType(element): 'Array<${astTypeName(element)}>';
			case MapType(key, value): 'Map<${astTypeName(key)},${astTypeName(value)}>';
			case NullableType(element): 'Null<${astTypeName(element)}>';
			case FunctionType(arguments, result): '(' + [for (argument in arguments) astTypeName(argument)].join(',') + ')->' + astTypeName(result);
		};

	static function canonicalStatement(s, module, entry, locals, ?aliases):AstStatement
		return switch s {
			case VarDeclaration(n, t, e,
				span): VarDeclaration(n, t == null ? null : canonicalType(t, aliases), canonicalExpression(e, module, entry, locals, aliases), span);
			case Assignment(n, e, span): Assignment(n, canonicalExpression(e, module, entry, locals, aliases), span);
			case IndexAssignment(array, offset, e,
				span): IndexAssignment(canonicalExpression(array, module, entry, locals, aliases),
					canonicalExpression(offset, module, entry, locals, aliases), canonicalExpression(e, module, entry, locals, aliases), span);
			case Return(e, span): Return(canonicalExpression(e, module, entry, locals, aliases), span);
			case Throw(e, span): Throw(canonicalExpression(e, module, entry, locals, aliases), span);
			case Try(tryBranch, catches, span): Try([for (x in tryBranch) canonicalStatement(x, module, entry, locals, aliases)], [
					for (catchClause in catches)
						{
							name: catchClause.name,
							type: canonicalType(catchClause.type, aliases),
							statements: [
								for (x in catchClause.statements)
									canonicalStatement(x, module, entry, locals, aliases)
							],
							span: catchClause.span
						}
				], span);
			case ReturnVoid(span): ReturnVoid(span);
			case Break(span): Break(span);
			case Continue(span): Continue(span);
			case Increment(name, delta, span): Increment(name, delta, span);
			case If(c, y, n,
				span): If(canonicalExpression(c, module, entry, locals, aliases), [for (x in y) canonicalStatement(x, module, entry, locals, aliases)],
					[for (x in n) canonicalStatement(x, module, entry, locals, aliases)], span);
			case While(c, b,
				span): While(canonicalExpression(c, module, entry, locals, aliases), [for (x in b) canonicalStatement(x, module, entry, locals, aliases)],
					span);
			case ForIn(name, iterable, body,
				span): ForIn(name, canonicalExpression(iterable, module, entry, locals, aliases),
					[for (x in body) canonicalStatement(x, module, entry, locals, aliases)], span);
			case Switch(expression, cases, defaultBranch, hasDefault, span):
				Switch(canonicalExpression(expression, module, entry, locals, aliases), [
					for (switchCase in cases)
						{
							value: canonicalExpression(switchCase.value, module, entry, locals, aliases),
							statements: [
								for (x in switchCase.statements)
									canonicalStatement(x, module, entry, locals, aliases)
							],
							span: switchCase.span
						}
				],
					[for (x in defaultBranch) canonicalStatement(x, module, entry, locals, aliases)], hasDefault, span);
			case Expression(e, span): Expression(canonicalExpression(e, module, entry, locals, aliases), span);
		}

	static function canonicalExpression(e, module, entry, locals, ?aliases):AstExpression
		return switch e {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_): e;
			case Variable(name, span):
				if (name.indexOf(".") < 0 && locals.exists(name)) Variable(module == entry
					&& name == "main" ? "main" : module + "." + name, span); else e;
			case Member(object, name, s): Member(canonicalExpression(object, module, entry, locals, aliases), name, s);
			case Add(a, b, s): Add(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Sub(a, b, s): Sub(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Mul(a, b, s): Mul(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Div(a, b, s): Div(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Mod(a, b, s): Mod(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Negate(value, s): Negate(canonicalExpression(value, module, entry, locals, aliases), s);
			case Less(a, b, s): Less(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case LessEqual(a, b,
				s): LessEqual(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Greater(a, b, s): Greater(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case GreaterEqual(a, b,
				s): GreaterEqual(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Equal(a, b, s): Equal(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case NotEqual(a, b, s): NotEqual(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Not(value, s): Not(canonicalExpression(value, module, entry, locals, aliases), s);
			case And(a, b, s): And(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Or(a, b, s): Or(canonicalExpression(a, module, entry, locals, aliases), canonicalExpression(b, module, entry, locals, aliases), s);
			case Call(name, args, s):
				var resolved = name;
				var dot = name.indexOf("."),
					prefix = dot < 0 ? name : name.substr(0, dot),
					imported = aliases == null ? null : aliases.get(prefix);
				if (imported != null)
					resolved = imported + (dot < 0 ? "" : name.substr(dot));
				else if (name.indexOf(".") < 0 && locals.exists(name))
					resolved = module == entry && name == "main" ? "main" : module + "." + name;
				Call(resolved, [for (a in args) canonicalExpression(a, module, entry, locals, aliases)], s);
			case MethodCall(object, name, args,
				s): MethodCall(canonicalExpression(object, module, entry, locals, aliases), name,
					[for (a in args) canonicalExpression(a, module, entry, locals, aliases)], s);
			case New(typeName, args, s): New(resolveTypeName(typeName, aliases), [for (a in args) canonicalExpression(a, module, entry, locals, aliases)], s);
			case NewArray(element, length, s): NewArray(element, canonicalExpression(length, module, entry, locals, aliases), s);
			case NewMap(key, value, s): NewMap(key, value, s);
			case Index(array, offset,
				s): Index(canonicalExpression(array, module, entry, locals, aliases), canonicalExpression(offset, module, entry, locals, aliases), s);
			case Lambda(arguments, body, s):
				Lambda(arguments, [
					for (statement in body)
						canonicalStatement(statement, module, entry, locals, aliases)
				], s);
		}

	static function importAliases(imports:Array<String>):Map<String, String> {
		var aliases:Map<String, String> = [];
		for (path in imports) {
			var dot = path.lastIndexOf("."),
				alias = dot < 0 ? path : path.substr(dot + 1);
			aliases.set(alias, path);
		}
		return aliases;
	}

	static function resolveTypeName(name:String, aliases:Null<Map<String, String>>):String {
		var imported = aliases == null ? null : aliases.get(name);
		if (imported == null)
			return name;
		return imported;
	}

	static function canonicalType(type:compiler.Ast.AstType, aliases:Null<Map<String, String>>):compiler.Ast.AstType
		return switch type {
			case NamedType(name): NamedType(resolveTypeName(name, aliases));
			case ArrayType(element): ArrayType(canonicalType(element, aliases));
			case MapType(key, value): MapType(canonicalType(key, aliases), canonicalType(value, aliases));
			case NullableType(element): NullableType(canonicalType(element, aliases));
			case FunctionType(arguments, result): FunctionType([for (argument in arguments) canonicalType(argument, aliases)], canonicalType(result, aliases));
			default: type;
		};

	static function collectSemanticDependencies(state:ModuleState, entry:String, typeAliases:Map<String, String>):Map<String, Array<SemanticDependency>> {
		var result:Map<String, Array<SemanticDependency>> = [];
		for (fn in state.ast.functions) {
			var owner = state.name == entry && fn.name == "main" ? "main" : state.name + "." + fn.name;
			for (argument in fn.arguments)
				addTypeDependency(result, owner, Signature, argument.type, typeAliases);
			addTypeDependency(result, owner, Signature, fn.result, typeAliases);
			addBodyDependencies(result, owner, fn.statements, state.name, entry);
		}
		for (classDecl in state.ast.classes) {
			var className = qualifiedTypeName(state.ast.packageName, classDecl.name);
			if (classDecl.base != null)
				addDependency(result, className, Layout, resolveTypeName(classDecl.base, typeAliases));
			for (interfaceName in classDecl.interfaces)
				addDependency(result, className, Layout, resolveTypeName(interfaceName, typeAliases));
			for (field in classDecl.fields) {
				addTypeDependency(result, className, Layout, field.type, typeAliases);
				if (field.initializer != null)
					addExpressionDependencies(result, className + "." + field.name, Initializer, field.initializer, state.name, entry);
			}
			for (method in classDecl.methods) {
				var owner = className + "." + method.name;
				for (argument in method.arguments)
					addTypeDependency(result, owner, Signature, argument.type, typeAliases);
				addTypeDependency(result, owner, Signature, method.result, typeAliases);
				addBodyDependencies(result, owner, method.statements, state.name, entry);
			}
		}
		return result;
	}

	static function addTypeDependency(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind, type:compiler.Ast.AstType,
			aliases:Map<String, String>):Void
		switch type {
			case NamedType(name):
				addDependency(result, owner, kind, resolveTypeName(name, aliases));
			case ArrayType(element), NullableType(element):
				addTypeDependency(result, owner, kind, element, aliases);
			case MapType(key, value):
				addTypeDependency(result, owner, kind, key, aliases);
				addTypeDependency(result, owner, kind, value, aliases);
			case FunctionType(arguments, returnType):
				for (argument in arguments)
					addTypeDependency(result, owner, kind, argument, aliases);
				addTypeDependency(result, owner, kind, returnType, aliases);
			case IntType, BoolType, FloatType, StringType, VoidType:
		}

	static function addBodyDependencies(result:Map<String, Array<SemanticDependency>>, owner:String, statements:Array<AstStatement>, module:String,
			entry:String):Void
		for (statement in statements)
			switch statement {
				case VarDeclaration(_, type, expression, _):
					if (type != null)
						addTypeDependency(result, owner, Body, type, []);
					addExpressionDependencies(result, owner, Body, expression, module, entry);
				case Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					addExpressionDependencies(result, owner, Body, expression, module, entry);
				case IndexAssignment(array, offset, expression, _):
					for (item in [array, offset, expression])
						addExpressionDependencies(result, owner, Body, item, module, entry);
				case If(condition, yes, no, _):
					addExpressionDependencies(result, owner, Body, condition, module, entry);
					addBodyDependencies(result, owner, yes, module, entry);
					addBodyDependencies(result, owner, no, module, entry);
				case While(condition, body, _):
					addExpressionDependencies(result, owner, Body, condition, module, entry);
					addBodyDependencies(result, owner, body, module, entry);
				case ForIn(_, iterable, body, _):
					addExpressionDependencies(result, owner, Body, iterable, module, entry);
					addBodyDependencies(result, owner, body, module, entry);
				case Try(body, catches, _):
					addBodyDependencies(result, owner, body, module, entry);
					for (clause in catches)
						addBodyDependencies(result, owner, clause.statements, module, entry);
				case Switch(expression, cases, fallback, _, _):
					addExpressionDependencies(result, owner, Body, expression, module, entry);
					for (switchCase in cases)
						addBodyDependencies(result, owner, switchCase.statements, module, entry);
					addBodyDependencies(result, owner, fallback, module, entry);
				case ReturnVoid(_), Break(_), Continue(_), Increment(_, _, _):
			}

	static function addExpressionDependencies(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind,
			expression:AstExpression, module:String, entry:String):Void {
		var calls:Map<String, Bool> = [], locals:Map<String, String> = [];
		scanCallExpression(expression, calls, locals);
		for (name in calls.keys())
			addDependency(result, owner, kind, canonicalName(module, entry, name));
	}

	static function addDependency(result:Map<String, Array<SemanticDependency>>, owner:String, kind:SemanticDependencyKind, target:String):Void {
		var dependencies = result.get(owner);
		if (dependencies == null) {
			dependencies = [];
			result.set(owner, dependencies);
		}
		for (dependency in dependencies)
			if (dependency.kind == kind && dependency.target == target)
				return;
		dependencies.push({kind: kind, target: target});
	}

	static function sameDependencyTarget(dependency:String, changed:String):Bool
		return dependency == changed || StringTools.endsWith(dependency, "." + changed) || StringTools.endsWith(changed, "." + dependency);

	static function scanStatement(s, dependencies):Void
		switch s {
			case VarDeclaration(_, _, e, _), Assignment(_, e, _), Return(e, _), Throw(e, _):
				scanExpression(e, dependencies);
			case Try(tryBranch, catches, _):
				for (x in tryBranch)
					scanStatement(x, dependencies);
				for (catchClause in catches)
					for (x in catchClause.statements)
						scanStatement(x, dependencies);
			case IndexAssignment(array, offset, e, _):
				scanExpression(array, dependencies);
				scanExpression(offset, dependencies);
				scanExpression(e, dependencies);
			case ReturnVoid(_):
			case Break(_), Continue(_):
			case Increment(_, _, _):
			case If(c, y, n, _):
				scanExpression(c, dependencies);
				for (x in y)
					scanStatement(x, dependencies);
				for (x in n)
					scanStatement(x, dependencies);
			case While(c, b, _):
				scanExpression(c, dependencies);
				for (x in b)
					scanStatement(x, dependencies);
			case ForIn(_, iterable, b, _):
				scanExpression(iterable, dependencies);
				for (x in b)
					scanStatement(x, dependencies);
			case Switch(expression, cases, defaultBranch, _, _):
				scanExpression(expression, dependencies);
				for (switchCase in cases) {
					scanExpression(switchCase.value, dependencies);
					for (x in switchCase.statements)
						scanStatement(x, dependencies);
				}
				for (x in defaultBranch)
					scanStatement(x, dependencies);
			case Expression(e, _):
				scanExpression(e, dependencies);
		}

	static function scanExpression(e, dependencies):Void
		switch e {
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _),
				GreaterEqual(a, b, _), Equal(a, b, _), NotEqual(a, b, _):
				scanExpression(a, dependencies);
				scanExpression(b, dependencies);
			case Not(value, _):
				scanExpression(value, dependencies);
			case Negate(value, _):
				scanExpression(value, dependencies);
			case And(left, right, _), Or(left, right, _):
				scanExpression(left, dependencies);
				scanExpression(right, dependencies);
			case Index(array, offset, _):
				scanExpression(array, dependencies);
				scanExpression(offset, dependencies);
			case Member(object, _, _):
				scanExpression(object, dependencies);
			case Variable(name, _):
				scanQualifiedDependency(name, dependencies);
			case MethodCall(object, _, args, _):
				scanExpression(object, dependencies);
				for (a in args)
					scanExpression(a, dependencies);
			case Call(name, args, _):
				var dot = name.indexOf(".");
				if (dot > 0) {
					var prefix = name.substr(0, dot);
					// Lowercase dotted calls are instance calls on locals (for
					// example box.get), not module dependencies.
					if (prefix.length > 0 && prefix.charCodeAt(0) >= 65 && prefix.charCodeAt(0) <= 90)
						dependencies.set(prefix, true);
				}
				for (a in args)
					scanExpression(a, dependencies);
			case NewArray(_, length, _):
				scanExpression(length, dependencies);
			case NewMap(_, _, _):
			default:
		}

	function nativePrefixExists(prefix:String):Bool {
		for (name in natives.keys()) {
			var dot = name.indexOf(".");
			if (dot > 0 && name.substr(0, dot) == prefix)
				return true;
		}
		return false;
	}

	static function scanQualifiedDependency(name:String, dependencies:Map<String, Bool>):Void {
		var dot = name.indexOf(".");
		if (dot > 0) {
			var prefix = name.substr(0, dot);
			if (prefix.length > 0 && prefix.charCodeAt(0) >= 65 && prefix.charCodeAt(0) <= 90)
				dependencies.set(prefix, true);
		}
	}

	static function scanCalls(statement:AstStatement, calls:Map<String, Bool>, aliases:Map<String, String>):Void
		switch statement {
			case VarDeclaration(name, _, e, _):
				scanCallExpression(e, calls, aliases);
				rememberAlias(name, e, aliases);
			case Assignment(name, e, _):
				scanCallExpression(e, calls, aliases);
				rememberAlias(name, e, aliases);
			case IndexAssignment(array, offset, e, _):
				scanCallExpression(array, calls, aliases);
				scanCallExpression(offset, calls, aliases);
				scanCallExpression(e, calls, aliases);
			case Return(e, _):
				scanCallExpression(e, calls, aliases);
			case Throw(e, _):
				scanCallExpression(e, calls, aliases);
			case Try(tryBranch, catches, _):
				for (s in tryBranch)
					scanCalls(s, calls, aliases);
				for (catchClause in catches)
					for (s in catchClause.statements)
						scanCalls(s, calls, aliases);
			case ReturnVoid(_):
			case Break(_), Continue(_):
			case Increment(_, _, _):
			case If(c, y, n, _):
				scanCallExpression(c, calls, aliases);
				for (s in y)
					scanCalls(s, calls, aliases);
				for (s in n)
					scanCalls(s, calls, aliases);
			case While(c, b, _):
				scanCallExpression(c, calls, aliases);
				for (s in b)
					scanCalls(s, calls, aliases);
			case ForIn(_, iterable, b, _):
				scanCallExpression(iterable, calls, aliases);
				for (s in b)
					scanCalls(s, calls, aliases);
			case Switch(expression, cases, defaultBranch, _, _):
				scanCallExpression(expression, calls, aliases);
				for (switchCase in cases) {
					scanCallExpression(switchCase.value, calls, aliases);
					for (s in switchCase.statements)
						scanCalls(s, calls, aliases);
				}
				for (s in defaultBranch)
					scanCalls(s, calls, aliases);
			case Expression(e, _):
				scanCallExpression(e, calls, aliases);
		}

	static function scanCallExpression(e:AstExpression, calls:Map<String, Bool>, aliases:Map<String, String>):Void
		switch e {
			case Call(name, args, _):
				calls.set(aliases.get(name) == null ? name : aliases.get(name), true);
				for (a in args)
					scanCallExpression(a, calls, aliases);
			case MethodCall(object, _, args, _):
				scanCallExpression(object, calls, aliases);
				for (a in args)
					scanCallExpression(a, calls, aliases);
			case Member(object, _, _):
				scanCallExpression(object, calls, aliases);
			case Variable(name, _):
				if (name.indexOf(".") >= 0)
					calls.set(name, true);
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _),
				GreaterEqual(a, b, _), Equal(a, b, _), NotEqual(a, b, _):
				scanCallExpression(a, calls, aliases);
				scanCallExpression(b, calls, aliases);
			case Not(value, _):
				scanCallExpression(value, calls, aliases);
			case Negate(value, _):
				scanCallExpression(value, calls, aliases);
			case And(left, right, _), Or(left, right, _):
				scanCallExpression(left, calls, aliases);
				scanCallExpression(right, calls, aliases);
			case New(typeName, args, _):
				calls.set(typeName + ".new", true);
				for (a in args)
					scanCallExpression(a, calls, aliases);
			case NewArray(_, length, _):
				scanCallExpression(length, calls, aliases);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				scanCallExpression(array, calls, aliases);
				scanCallExpression(offset, calls, aliases);
			case Lambda(_, body, _):
				for (statement in body)
					scanCalls(statement, calls, aliases);
			default:
		}

	static function rememberAlias(name:String, expression:AstExpression, aliases:Map<String, String>):Void
		switch expression {
			case Variable(target, _):
				var resolved = aliases.get(target);
				aliases.set(name, resolved == null ? target : resolved);
			default:
				aliases.remove(name);
		}

	static function collectLambdas(statements:Array<AstStatement>, functionName:String, module:String, generatedByModule:Map<String, Map<String, Bool>>):Void {
		for (statement in statements)
			switch statement {
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Throw(expression, _), Expression(expression, _):
					collectLambdaExpression(expression, functionName, module, generatedByModule);
				case Try(tryBranch, catches, _):
					collectLambdas(tryBranch, functionName, module, generatedByModule);
					for (catchClause in catches)
						collectLambdas(catchClause.statements, functionName, module, generatedByModule);
				case IndexAssignment(array, offset, expression, _):
					collectLambdaExpression(array, functionName, module, generatedByModule);
					collectLambdaExpression(offset, functionName, module, generatedByModule);
					collectLambdaExpression(expression, functionName, module, generatedByModule);
				case ReturnVoid(_):
				case Break(_), Continue(_):
				case Increment(_, _, _):
				case If(condition, yes, no, _):
					collectLambdaExpression(condition, functionName, module, generatedByModule);
					collectLambdas(yes, functionName, module, generatedByModule);
					collectLambdas(no, functionName, module, generatedByModule);
				case While(condition, body, _):
					collectLambdaExpression(condition, functionName, module, generatedByModule);
					collectLambdas(body, functionName, module, generatedByModule);
				case ForIn(_, iterable, body, _):
					collectLambdaExpression(iterable, functionName, module, generatedByModule);
					collectLambdas(body, functionName, module, generatedByModule);
				case Switch(expression, cases, defaultBranch, _, _):
					collectLambdaExpression(expression, functionName, module, generatedByModule);
					for (switchCase in cases) {
						collectLambdaExpression(switchCase.value, functionName, module, generatedByModule);
						collectLambdas(switchCase.statements, functionName, module, generatedByModule);
					}
					collectLambdas(defaultBranch, functionName, module, generatedByModule);
			}
	}

	static function collectLambdaExpression(expression:AstExpression, functionName:String, module:String, generatedByModule:Map<String, Map<String, Bool>>):Void
		switch expression {
			case Lambda(_, body, span):
				var names = generatedByModule.get(module);
				if (names == null) {
					names = [];
					generatedByModule.set(module, names);
				}
				names.set('$' + 'lambda:' + functionName + ':' + span.start, true);
				collectLambdas(body, functionName, module, generatedByModule);
			case Call(_, args, _):
				for (argument in args)
					collectLambdaExpression(argument, functionName, module, generatedByModule);
			case MethodCall(object, _, args, _):
				collectLambdaExpression(object, functionName, module, generatedByModule);
				for (argument in args)
					collectLambdaExpression(argument, functionName, module, generatedByModule);
			case Member(object, _, _):
				collectLambdaExpression(object, functionName, module, generatedByModule);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), Less(left, right, _),
				LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _), NotEqual(left, right, _):
				collectLambdaExpression(left, functionName, module, generatedByModule);
				collectLambdaExpression(right, functionName, module, generatedByModule);
			case Not(value, _):
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case Negate(value, _):
				collectLambdaExpression(value, functionName, module, generatedByModule);
			case And(left, right, _), Or(left, right, _):
				collectLambdaExpression(left, functionName, module, generatedByModule);
				collectLambdaExpression(right, functionName, module, generatedByModule);
			case New(_, args, _):
				for (argument in args)
					collectLambdaExpression(argument, functionName, module, generatedByModule);
			case NewArray(_, length, _):
				collectLambdaExpression(length, functionName, module, generatedByModule);
			case NewMap(_, _, _):
			case Index(array, offset, _):
				collectLambdaExpression(array, functionName, module, generatedByModule);
				collectLambdaExpression(offset, functionName, module, generatedByModule);
			default:
		}

	static function signatureFingerprint(fn:AstFunction, aliases:Array<compiler.Ast.AstTypeAlias>):String
		return SemanticSignature.parsedFunction(fn, aliases);

	static function owner(name:String, entry:String):String {
		var dot = name.indexOf(".");
		return dot < 0 ? entry : name.substr(0, dot);
	}

	static function copyIndices(source:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (name => index in source)
			result.set(name, index);
		return result;
	}
}
