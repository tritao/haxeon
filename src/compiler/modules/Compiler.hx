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
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.HlCode;
import compiler.hl.HlModuleAssembler;
import compiler.hl.HlPatchWriter;
import compiler.hl.HlRuntimeIdentity;
import haxe.io.Bytes;
import compiler.types.Type.CompilerType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;
import compiler.service.CancellationToken;

typedef NativeFunction = {final name:String; final library:String; final symbol:String; final arguments:Array<CompilerType>; final result:CompilerType;}

typedef CompileResult = {
	final ir:IrProgram;
	final module:HlCode;
	final retyped:Array<String>;
	final regenerated:Array<String>;
	final changedFunctions:Array<Int>;
	final requiresReload:Bool;
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

	public final types:TypeRegistry;

	final natives:Map<String, NativeFunction> = [];
	final objectCache:Map<String, IrObject> = [];
	var compiledOnce = false;

	public function new(?identityState:Bytes) {
		if (identityState == null) {
			moduleId = HlRuntimeIdentity.createModuleId();
			assembler = new HlModuleAssembler();
			types = new TypeRegistry();
		} else {
			var identity = HlRuntimeIdentity.decodePersistent(identityState);
			moduleId = identity.moduleId;
			assembler = new HlModuleAssembler(identity.stableIds);
			types = new TypeRegistry(identity.typeState);
		}
	}

	public function exportIdentityState():Bytes
		return HlRuntimeIdentity.encodePersistent(moduleId, assembler.cache.stableIds, types.exportState());

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
								isStatic: field.isStatic,
								isFinal: field.isFinal,
								span: field.span
							}
					],
					methods: classMethods,
					span: classDecl.span
				});
			}
		}
		for (module => lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				owners.set(lambdaName, module);
		var invalid:Map<String, Bool> = [], interfaceChanged = false;
		for (change in structuralChanged.keys())
			if (StringTools.startsWith(change, "interface:")
				|| StringTools.startsWith(change, "alias:")
				|| StringTools.startsWith(change, "enum:"))
				interfaceChanged = true;
		if (interfaceChanged)
			for (fn in functions)
				invalid.set(fn.name, true);
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
		for (fn in functions)
			if (invalid.exists(fn.name))
				selected.set(fn.name, true);
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
			for (cached in state.typedFunctions.keys())
				if (!valid.exists(cached)) {
					state.typedFunctions.remove(cached);
					state.irFunctions.remove(cached);
					state.irVersions.remove(cached);
				}
		}
		retyped.sort(Reflect.compare);
		regenerated.sort(Reflect.compare);
		var cachedNames = [for (fn in functions) fn.name];
		for (lambdaNames in generatedByModule)
			for (lambdaName in lambdaNames.keys())
				cachedNames.push(lambdaName);
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
			IrGenerator.enumsFrom(typedNew));
		var signatureChanges = [for (name in signatureChanged.keys()) name];
		signatureChanges.sort(Reflect.compare);
		var forceReload = compiledOnce && structuralChanged.keys().hasNext();
		if (forceReload)
			assembler = new HlModuleAssembler(copyIndices(assembler.cache.stableIds));
		var assembly = assembler.assemble(ir, regenerated, signatureChanges, forceReload);
		if (token != null)
			token.check();
		lastTypedProgram = typedNew;
		for (name in names) {
			var state = modules.get(name);
			state.lastGoodTokens = state.tokens;
			state.lastGoodAst = state.ast;
			state.lastGoodSource = state.source;
		}
		compiledOnce = true;
		var patchBytes = assembly.requiresReload
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, moduleId, assembly.changedSlots,
				stableIdsBySlot(assembly.functionIndices), assembly.revision - 1, assembly.revision, assembly.baseInts, assembly.baseFloats,
				assembly.baseStrings, assembly.baseTypes);
		return {
			ir: ir,
			module: assembly.module,
			retyped: retyped,
			regenerated: regenerated,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			functionIndices: copyIndices(assembly.functionIndices),
			functionIds: copyIndices(assembler.cache.stableIds),
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.functionIndices, assembler.cache.stableIds),
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

	function stableIdsBySlot(layout:Map<String, Int>):Map<Int, Int> {
		var result:Map<Int, Int> = [];
		for (name => id in assembler.cache.stableIds)
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
			dependencies.remove(classDecl.name);
		for (enumDecl in state.ast.enums)
			dependencies.remove(enumDecl.name);
		for (importPath in state.ast.imports) {
			var dot = importPath.lastIndexOf("."),
				alias = dot < 0 ? importPath : importPath.substr(dot + 1);
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
		var signatures:Map<String, String> = [],
			bodies:Map<String, String> = [];
		var interfaces:Map<String, String> = [];
		for (interfaceDecl in state.ast.interfaces) {
			var signature = interfaceDecl.name + " extends " + interfaceDecl.bases.join(",") + " {" + [
				for (method in interfaceDecl.methods)
					method.name + ":" + signatureFingerprint(method)
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
				signature = aliasName + "=" + astTypeName(canonicalType(alias.type, typeAliases));
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
						caseDecl.name + "(" + [for (param in caseDecl.params) astTypeName(canonicalType(param, typeAliases))].join(",") + ")"
				].join(";") + "}";
			enums.set(enumName, signature);
			if (state.enumFingerprints.get(enumName) != signature)
				structuralChanged.set('enum:$enumName', true);
		}
		for (old in state.enumFingerprints.keys())
			if (!enums.exists(old))
				structuralChanged.set('enum:$old', true);
		state.enumFingerprints = enums;
		for (fn in state.ast.functions) {
			var canonical = state.name == entry && fn.name == "main" ? "main" : state.name + "." + fn.name;
			var signature = signatureFingerprint(fn),
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
					{name: field.name, type: astTypeName(canonicalType(field.type, typeAliases))}
			], classMethods = [
				for (method in classDecl.methods)
					{name: method.name, signature: signatureFingerprint(method)}
				];
			var typeResult = types.declareClass(className, baseName, classFields, classMethods);
			if (compiledOnce && typeResult.compatibility != Compatible)
				structuralChanged.set(className, true);
			for (method in classDecl.methods) {
				var localName = className + "." + method.name,
					canonical = localName,
					signature = signatureFingerprint(method),
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

	static function scanStatement(s, dependencies):Void
		switch s {
			case VarDeclaration(_, _, e, _), Assignment(_, e, _), Return(e, _):
				scanExpression(e, dependencies);
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
			case New(_, args, _):
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
				case VarDeclaration(_, _, expression, _), Assignment(_, expression, _), Return(expression, _), Expression(expression, _):
					collectLambdaExpression(expression, functionName, module, generatedByModule);
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

	static function signatureFingerprint(fn:AstFunction):String
		return fn.name + "(" + [for (a in fn.arguments) Std.string(a.type)].join(",") + ")->" + Std.string(fn.result);

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
