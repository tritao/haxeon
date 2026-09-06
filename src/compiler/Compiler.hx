package compiler;

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
import compiler.ir.Ir.IrType;
import compiler.ir.IrGenerator;
import compiler.types.FieldInference;
import compiler.types.SignatureInference;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.types.SemanticSignature;
import compiler.types.GenericSpecializationRegistry;
import compiler.types.SemanticProgram;
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.HlCode;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.patch.HlPatchWriter;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlAssemblerStateCodec;
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
import compiler.abi.NativeRegistry;
import compiler.abi.NativeRegistry.NativeDefinition;
import compiler.CompilerPublication.CompilerSnapshot;
import compiler.CompilerPublication.PublicationStatus;
import compiler.CompilerPublication.ReconnectDecision;
import compiler.CompilerPublication.ReconnectReason;
import compiler.modules.ModuleGraph;
import compiler.modules.ModulePath;
import compiler.modules.ModuleReachability;
import compiler.modules.ModuleState;
import compiler.modules.ModuleState.SemanticDependency;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.ModuleChangeAnalyzer;
import compiler.semantic.DependencyScanner;
import compiler.semantic.LambdaCollector;
import compiler.semantic.SemanticDependencyCollector;
import compiler.semantic.SemanticWorkspace;

/** Public alias for a host-native declaration accepted by the compiler. */
typedef NativeFunction = NativeDefinition;

/** Artifacts, invalidation details, and publication metadata from a successful build. */
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

/** Work and output-size counters measured for one compilation. */
typedef CompileMetrics = {
	final elapsedMs:Float;
	final transactionSnapshotMs:Float;
	final frontendMs:Float;
	final typingLoweringMs:Float;
	final typerSetupMs:Float;
	final typerNoReturnMs:Float;
	final typerMetadataMs:Float;
	final typerBodiesMs:Float;
	final typerAssemblyMs:Float;
	final irAssemblyMs:Float;
	final abiPlanningMs:Float;
	final backendAssemblyMs:Float;
	final patchEncodingMs:Float;
	final finalizeMs:Float;
	final modules:Int;
	final retypedFunctions:Int;
	final regeneratedFunctions:Int;
	final changedFunctions:Int;
	final moduleFunctions:Int;
	final moduleNatives:Int;
	final patchBytes:Int;
}

/** Non-mutating validation outcome for a prospective source update. */
typedef ValidationResult = {
	final valid:Bool;
	final diagnostic:Null<Diagnostic>;
}

/**
 * Persistent incremental compiler and owner of all module and backend state.
 * Compilation is transactional: failed edits do not replace published artifacts.
 */
@:allow(compiler.CompilationTransaction)
@:allow(compiler.CompilationPipeline)
@:allow(compiler.BackendAssembly)
class Compiler {
	final genericSpecializations = new GenericSpecializationRegistry();

	public final modules:Map<String, ModuleState> = [];
	public final semanticWorkspace:SemanticWorkspace;

	/** Last successfully assembled typed program; failed edits never replace it. */
	public var lastTypedProgram:Null<TypedProgram> = null;

	final graph = new ModuleGraph();
	var assembler:HlModuleAssembler;
	final moduleId:Bytes;

	public var types(default, null):TypeRegistry;

	final natives:NativeRegistry;
	var objectCache:Map<String, IrObject> = [];
	var publishedAbi:Null<RuntimeAbiDescriptor>;
	var compiledOnce = false;
	final publication = new CompilerPublication();
	var rehydrationBaseline:Null<Map<String, Bytes>>;
	var sourceGeneration = 0;
	var cachedCompileGeneration = -1;
	var cachedCompileEntry:Null<String>;
	var cachedCompileResult:Null<CompileResult>;
	var cachedSemanticProgram:Null<SemanticProgram>;

	public function new(?identityState:Bytes, ?nativeConfiguration:Array<NativeFunction>) {
		semanticWorkspace = new SemanticWorkspace(modules);
		natives = new NativeRegistry(nativeConfiguration);
		if (identityState == null) {
			moduleId = HlRuntimeIdentity.createModuleId();
			assembler = new HlModuleAssembler();
			types = new TypeRegistry();
		} else {
			var identity = HlRuntimeIdentity.decodePersistent(identityState);
			moduleId = identity.moduleId;
			var assemblerState = identity.assemblerState;
			assembler = assemblerState == null ? new HlModuleAssembler(identity.stableIds) : HlAssemblerStateCodec.decode(assemblerState);
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
		var baseline:Map<String, Bytes> = [];
		rehydrationBaseline = baseline;
		for (name => fn in restored.cache.functions)
			baseline.set(name, compiler.ir.codec.IrFunctionStateCodec.encode(fn));
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
		natives.registerNative(name, library, symbol, arguments, result);
	}

	public function nativeConfiguration():Array<NativeFunction> {
		return natives.configuration();
	}

	public function compact(entryModule:String):CompileResult {
		var result = new CompilationTransaction(this, entryModule, null, new HlModuleAssembler(assembler.cache.stableIds)).run();
		rememberCompile(entryModule, result);
		return result;
	}

	public function update(path:String, source:String):ModuleState {
		var name = ModulePath.fromFile(path),
			file = new SourceFile(path, source);
		var state:ModuleState;
		if (modules.exists(name)) {
			state = modules.get(name);
			state.update(file);
		} else {
			state = new ModuleState(name, file);
			modules.set(name, state);
		}
		sourceGeneration++;
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
		var candidate = new Compiler(exportIdentityState(), nativeConfiguration());
		var moduleNames = [for (name in modules.keys()) name];
		moduleNames.sort(Reflect.compare);
		for (name in moduleNames) {
			var state = modules.get(name);
			candidate.update(state.source.path, state.source.text);
		}
		return candidate;
	}

	public function compile(entryModule:String, ?token:CancellationToken):CompileResult {
		var cached = cachedCompileResult, cachedEntry = cachedCompileEntry;
		if (!publication.status().tracking
			&& cached != null
			&& cachedCompileGeneration == sourceGeneration
			&& cachedEntry != null
			&& cachedEntry == entryModule) {
			if (token != null)
				token.check();
			return {
				ir: cached.ir,
				module: cached.module,
				retyped: [],
				regenerated: [],
				changedFunctions: [],
				requiresReload: false,
				reloadReasons: [],
				functionIndices: cached.functionIndices,
				functionIds: cached.functionIds,
				runtimeIdentity: cached.runtimeIdentity,
				revision: cached.revision,
				patchBytes: null,
				metrics: {
					elapsedMs: 0.0,
					transactionSnapshotMs: 0.0,
					frontendMs: 0.0,
					typingLoweringMs: 0.0,
					typerSetupMs: 0.0,
					typerNoReturnMs: 0.0,
					typerMetadataMs: 0.0,
					typerBodiesMs: 0.0,
					typerAssemblyMs: 0.0,
					irAssemblyMs: 0.0,
					abiPlanningMs: 0.0,
					backendAssemblyMs: 0.0,
					patchEncodingMs: 0.0,
					finalizeMs: 0.0,
					modules: cached.metrics.modules,
					retypedFunctions: 0,
					regeneratedFunctions: 0,
					changedFunctions: 0,
					moduleFunctions: cached.metrics.moduleFunctions,
					moduleNatives: cached.metrics.moduleNatives,
					patchBytes: 0
				}
			};
		}
		var result = new CompilationTransaction(this, entryModule, token, null).run();
		rememberCompile(entryModule, result);
		return result;
	}

	function rememberCompile(entryModule:String, result:CompileResult):Void {
		cachedCompileGeneration = sourceGeneration;
		cachedCompileEntry = entryModule;
		cachedCompileResult = result;
	}

	function executableEntryPoint(entryModule:String):String {
		var ast = modules.get(entryModule).parsedAst();
		for (fn in ast.functions)
			if (fn.name == "main")
				return "main";
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				if (method.name == "main" && method.isStatic)
					return ModuleCanonicalizer.qualifiedTypeName(ast.packageName, classDecl.name) + ".main";
		return "main";
	}

	function addTypeDependencies(state:ModuleState):Void {
		var dependencies:Map<String, Bool> = [];
		for (name in state.dependencies)
			dependencies.set(name, true);
		var ast = state.parsedAst();
		for (alias in ast.aliases)
			addModuleTypeDependency(alias.type, state, dependencies);
		for (enumDecl in ast.enums)
			for (caseDecl in enumDecl.cases)
				for (parameter in caseDecl.params)
					addModuleTypeDependency(parameter.type, state, dependencies);
		for (interfaceDecl in ast.interfaces)
			for (method in interfaceDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies);
		for (classDecl in ast.classes) {
			var base = classDecl.base;
			if (base != null) {
				var owner = sourceModuleForType(base, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
			}
			for (field in classDecl.fields)
				addModuleTypeDependency(FieldInference.parsedType(field), state, dependencies);
			for (method in classDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies);
		}
		for (fn in ast.functions)
			addFunctionTypeDependencies(fn, state, dependencies);
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
	}

	function addFunctionTypeDependencies(fn:AstFunction, state:ModuleState, dependencies:Map<String, Bool>):Void {
		for (argument in fn.arguments)
			addModuleTypeDependency(argument.type, state, dependencies);
		addModuleTypeDependency(fn.result, state, dependencies);
	}

	function addModuleTypeDependency(type:compiler.Ast.AstType, state:ModuleState, dependencies:Map<String, Bool>):Void
		switch type {
			case NamedType(name):
				var ast = state.parsedAst(),
					owner = sourceModuleForType(name, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
			case ArrayType(element), NullableType(element):
				addModuleTypeDependency(element, state, dependencies);
			case MapType(key, value):
				addModuleTypeDependency(key, state, dependencies);
				addModuleTypeDependency(value, state, dependencies);
			case FunctionType(arguments, result):
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies);
				addModuleTypeDependency(result, state, dependencies);
			case AnonymousType(fields):
				for (field in fields)
					addModuleTypeDependency(field.type, state, dependencies);
			default:
		}

	function sourceModuleForType(typeName:String, packageName:Null<String>):Null<String> {
		var qualified = typeName.indexOf(".") < 0 && packageName != null ? packageName + "." + typeName : typeName,
			module = sourceModuleForDependency(qualified);
		if (module != null)
			return module;
		for (name => state in modules) {
			var ast = state.ast;
			if (ast == null)
				continue;
			var declaredPackage = ast.packageName,
				prefix = declaredPackage == null ? "" : declaredPackage + ".";
			for (declaration in ast.aliases)
				if (prefix + declaration.name == qualified)
					return name;
			for (declaration in ast.enums)
				if (prefix + declaration.name == qualified)
					return name;
			for (declaration in ast.interfaces)
				if (prefix + declaration.name == qualified)
					return name;
			for (declaration in ast.classes)
				if (prefix + declaration.name == qualified)
					return name;
		}
		return null;
	}

	function rehydratedChanges(regenerated:Array<String>, program:IrProgram):Array<String> {
		var baseline = rehydrationBaseline;
		if (baseline == null)
			return regenerated;
		var current:Map<String, compiler.ir.IrFunction> = [], changed = [];
		for (fn in program.functions)
			current.set(fn.name, fn);
		for (name in regenerated) {
			if (!baseline.exists(name) || !current.exists(name)) {
				changed.push(name);
				continue;
			}
			var old = baseline.get(name), next = current.get(name);
			if (old.compare(compiler.ir.codec.IrFunctionStateCodec.encode(next)) != 0)
				changed.push(name);
		}
		return changed;
	}

	function snapshot():CompilerSnapshot {
		var moduleCopies:Map<String, ModuleState> = [],
			objectCopies:Map<String, IrObject> = [];
		for (name => state in modules)
			moduleCopies.set(name, state);
		for (name => object in objectCache)
			objectCopies.set(name, object);
		return {
			modules: moduleCopies,
			types: types.copy(),
			objectCache: objectCopies,
			lastTypedProgram: lastTypedProgram,
			publishedAbi: publishedAbi,
			compiledOnce: compiledOnce,
			rehydrationBaseline: rehydrationBaseline,
			semanticProgram: cachedSemanticProgram
		};
	}

	function writableState(name:String, rollbackModules:Map<String, ModuleState>):ModuleState {
		var state = modules.get(name);
		if (rollbackModules.get(name) == state) {
			state = state.copy();
			modules.set(name, state);
		}
		return state;
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
		cachedSemanticProgram = snapshot.semanticProgram;
	}

	static function explicitFunctionSignatures(functions:Array<AstFunction>):Bool {
		for (fn in functions) {
			if (fn.result == InferredType)
				return false;
			for (argument in fn.arguments)
				if (argument.type == InferredType)
					return false;
		}
		return true;
	}

	function nativeSignatures():Map<String, {arguments:Array<CompilerType>, result:CompilerType}> {
		return natives.signatures();
	}

	function irNatives():Array<IrNative>
		return natives.irNatives();

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
			state.semanticModel = new compiler.types.SemanticModel(state.parsedAst(), state.source, state.revision);
			state.parseVersion++;
		} catch (error:CompileError) {
			state.diagnostics.push(error.diagnostic);
			throw error;
		}
		var ast = state.parsedAst(), dependencies:Map<String, Bool> = [];
		for (dependency in ast.imports)
			dependencies.set(dependency, true);
		for (fn in ast.functions)
			for (statement in fn.statements)
				DependencyScanner.scanStatement(statement, dependencies);
		for (classDecl in ast.classes)
			for (field in classDecl.fields) {
				var initializer = field.initializer;
				if (initializer != null)
					DependencyScanner.scanExpression(initializer, dependencies);
			}
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies);
		for (abstractDecl in ast.abstracts)
			for (method in abstractDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies);
		for (abstractDecl in ast.enumAbstracts)
			for (value in abstractDecl.values)
				DependencyScanner.scanExpression(value.value, dependencies);
		for (classDecl in ast.classes) {
			dependencies.remove(classDecl.name);
			for (field in classDecl.fields)
				dependencies.remove(field.name);
		}
		for (enumDecl in ast.enums)
			dependencies.remove(enumDecl.name);
		for (abstractDecl in ast.enumAbstracts)
			dependencies.remove(abstractDecl.name);
		for (abstractDecl in ast.abstracts)
			dependencies.remove(abstractDecl.name);
		for (importPath in ast.imports) {
			var alias = lastPathSegment(importPath);
			if (alias != importPath)
				dependencies.remove(alias);
		}
		for (alias in ast.importAliases.keys())
			dependencies.remove(alias);
		// Dotted native names such as Sys.time look like module-qualified calls
		// to the dependency scanner.  Registered natives own those prefixes and
		// must not require a source module with the same name.
		for (dependency in [for (dependency in dependencies.keys()) dependency])
			if (nativePrefixExists(dependency))
				dependencies.remove(dependency);
		var packageName = ast.packageName;
		for (dependency in [for (dependency in dependencies.keys()) dependency]) {
			var sourceModule = sourceModuleForDependency(dependency);
			if (sourceModule == null && isPlatformDependency(dependency)) {
				dependencies.remove(dependency);
				continue;
			}
			if (dependency.indexOf(".") < 0 && packageName != null) {
				var packageCandidate = packageName + "." + dependency;
				if (modules.exists(packageCandidate)) {
					dependencies.remove(dependency);
					dependencies.set(packageCandidate, true);
					continue;
				}
			}
			if (sourceModule == null && dependency.indexOf(".") < 0 && hasSourceModuleImport(ast.imports)) {
				dependencies.remove(dependency);
				continue;
			}
			if (sourceModule == null && dependency.indexOf(".") < 0 && packageName != null) {
				var packageCandidate = packageName + "." + dependency;
				dependencies.remove(dependency);
				dependencies.set(packageCandidate, true);
				continue;
			}
			if (sourceModule != null && sourceModule != dependency) {
				dependencies.remove(dependency);
				dependencies.set(sourceModule, true);
			}
		}
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
		var typeAliases = importAliases(ast.imports, ast.importAliases);
		ModuleCanonicalizer.addDeclaredTypeAliases(typeAliases, ast, ast.packageName);
		state.semanticDependencies = SemanticDependencyCollector.collectSemanticDependencies(state, entry, typeAliases);
		var changes = ModuleChangeAnalyzer.analyze(state, entry, typeAliases, types, compiledOnce);
		mergeChanges(bodyChanged, changes.bodyChanged);
		mergeChanges(signatureChanged, changes.signatureChanged);
		mergeChanges(structuralChanged, changes.structuralChanged);
		state.signatureFingerprints = changes.signatureFingerprints;
		state.bodyFingerprints = changes.bodyFingerprints;
		state.interfaceFingerprints = changes.interfaceFingerprints;
		state.aliasFingerprints = changes.aliasFingerprints;
		state.enumFingerprints = changes.enumFingerprints;
		state.staticInitializerFingerprints = changes.staticInitializerFingerprints;
		state.instanceInitializerFingerprints = changes.instanceInitializerFingerprints;
		state.dirty = false;
	}

	function hasSourceModuleImport(imports:Array<String>):Bool {
		for (importPath in imports)
			if (sourceModuleForDependency(importPath) != null)
				return true;
		return false;
	}

	static function lastPathSegment(path:String):String {
		return compiler.QualifiedName.last(path);
	}

	static function firstPathSegment(path:String):String {
		return compiler.QualifiedName.first(path);
	}

	static function parentPath(path:String):String {
		return compiler.QualifiedName.parentOrEmpty(path);
	}

	static function mergeChanges(target:Map<String, Bool>, source:Map<String, Bool>):Void {
		for (name in source.keys())
			target.set(name, true);
	}

	static function mapIsEmpty(values:Map<String, Bool>):Bool {
		for (_ in values.keys())
			return false;
		return true;
	}

	function importAliases(imports:Array<String>, explicit:Map<String, String>):Map<String, String> {
		var aliases:Map<String, String> = [];
		for (path in imports) {
			var alias = lastPathSegment(path);
			aliases.set(alias, importedDeclarationName(path));
			aliases.set(path, importedDeclarationName(path));
		}
		for (alias => path in explicit) {
			aliases.set(alias, importedDeclarationName(path));
			aliases.set(path, importedDeclarationName(path));
		}
		return aliases;
	}

	function importedDeclarationName(path:String):String {
		var sourceModule = sourceModuleForDependency(path);
		if (sourceModule == null)
			return path;
		var moduleName:String = sourceModule;
		if (moduleName == path)
			return path;
		var packageName = parentPath(moduleName),
			nestedStart = moduleName.length + 1,
			nestedName = path.substring(nestedStart, path.length);
		return packageName.length == 0 ? nestedName : packageName + "." + nestedName;
	}

	function nativePrefixExists(prefix:String):Bool
		return natives.hasChild(prefix);

	function sourceModuleForDependency(path:String):Null<String> {
		var candidate = path;
		while (true) {
			if (modules.exists(candidate))
				return candidate;
			var parent = parentPath(candidate);
			if (parent.length == 0)
				return null;
			candidate = parent;
		}
	}

	static function isPlatformDependency(path:String):Bool {
		var root = firstPathSegment(path);
		return root == "haxe" || root == "sys" || root == "hl" || root == "Array" || root == "String" || root == "Math" || root == "Reflect"
			|| root == "Std" || root == "StringTools" || root == "Type";
	}

	static function signatureFingerprint(fn:AstFunction, aliases:Array<compiler.Ast.AstTypeAlias>):String
		return SemanticSignature.parsedFunction(fn, aliases);

	static function owner(name:String, entry:String):String {
		var first = firstPathSegment(name);
		return first == name ? entry : first;
	}

	static function copyIndices(source:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (name => index in source)
			result.set(name, index);
		return result;
	}
}
