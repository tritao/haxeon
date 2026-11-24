package compiler.semantic;

import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.QualifiedName;
import compiler.core.UnresolvedNameKind;
import compiler.modules.ModulePath;
import compiler.modules.ModuleSourceLoader;
import compiler.modules.ModuleState;
import compiler.runtime.NativeRegistry;
import compiler.runtime.PlatformAbi;
import compiler.runtime.RuntimeType;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.TokenTable;
import compiler.types.TypeRegistry;

/** Parses modules and derives their normalized source, type, and semantic dependencies. */
class ModuleAnalyzer {
	final modules:Map<String, ModuleState>;
	final types:TypeRegistry;
	final natives:NativeRegistry;
	final compiledOnce:Bool;
	final buildSemanticModels:Bool;
	/** Whether a module keeps its tokens after its parse: a kept session reads them again (`lastGoodTokens`, semantic models). */
	final keepsTokens:Bool;
	final defines:Map<String, String>;
	final sourceLoader:ModuleSourceLoader;
	final declarationOwners:DeclarationOwners;
	// Import resolution reads the declarations of modules that are not parsed yet, once per imported declaration. Each such
	// parse is kept here until the module's own parse adopts it.
	final lookupParses:Map<String, LookupParse> = [];
	final importedMembers:Map<String, {ast:compiler.syntax.Ast.AstProgram, members:Map<String, Bool>}> = [];

	final scriptModule:Null<String>;

	public function new(modules:Map<String, ModuleState>, types:TypeRegistry, natives:NativeRegistry, compiledOnce:Bool,
			defines:Map<String, String>,
			sourceLoader:ModuleSourceLoader, ?buildSemanticModels = true, ?declarationOwners:DeclarationOwners,
			?keepsTokens = true, ?scriptModule:String) {
		this.scriptModule = scriptModule;
		this.modules = modules;
		this.types = types;
		this.natives = natives;
		this.compiledOnce = compiledOnce;
		this.buildSemanticModels = buildSemanticModels;
		this.keepsTokens = keepsTokens || buildSemanticModels;
		this.defines = defines;
		this.sourceLoader = sourceLoader;
		this.declarationOwners = declarationOwners == null ? new DeclarationOwners() : declarationOwners;
		if (declarationOwners == null)
			for (name => state in modules)
				if (state.ast != null)
					indexDeclarations(name, state.parsedAst());
	}

	/** Suggests import paths for unresolved bare names, including declarations in modules the build never opened. */
	public function suggestImports(diagnostics:Array<compiler.core.Diagnostic>):Void {
		var pending = [];
		for (diagnostic in diagnostics) {
			var unresolved = diagnostic.unresolvedName;
			if (unresolved == null)
				continue;
			var kind = unresolved.kind, name = unresolved.name;
			var namespace = ModulePath.packageName(name);
			if (namespace != null) {
				// The dependency graph prefixes an unresolved bare name with the source module's package.
				if (kind != UnresolvedNameKind.WantedModule
					|| !Lambda.exists(modules, state -> state.source.path == diagnostic.span.file.path
					&& ModulePath.packageName(state.name) == namespace))
					continue;
				name = QualifiedName.last(name);
			}
			pending.push({diagnostic: diagnostic, kind: kind, name: name, paths: []});
		}
		if (pending.length == 0)
			return;

		function inspect(state:ModuleState):Void {
			var ast = state.ast == null ? parseText(state).ast : state.parsedAst();
			for (item in pending) {
				if (state.source.path == item.diagnostic.span.file.path)
					continue;
				var name = item.name;
				var isClass = Lambda.exists(ast.classes, decl -> decl.name == name && !decl.isPrivate);
				var isInterface = Lambda.exists(ast.interfaces, decl -> decl.name == name);
				var isAbstract = Lambda.exists(ast.abstracts, decl -> decl.name == name);
				var type = switch item.kind {
					case WantedFunction: false;
					case WantedClass: isClass || isAbstract;
					case WantedInterface: isInterface;
					case WantedBaseClass: isClass;
					case WantedType, WantedVariable, WantedModule: isClass || isInterface || isAbstract
						|| Lambda.exists(ast.aliases, decl -> decl.name == name && !decl.isPrivate)
						|| Lambda.exists(ast.enums, decl -> decl.name == name);
				};
				if (type || ((item.kind == UnresolvedNameKind.WantedVariable
					|| item.kind == UnresolvedNameKind.WantedFunction)
					&& Lambda.exists(ast.functions, decl -> decl.name == name && decl.isPublic != false))) {
					var path = ModuleCanonicalizer.sourceDeclarationPath(state.name, name);
					if (path != name && item.paths.indexOf(path) < 0)
						item.paths.push(path);
				}
			}
		}

		function matches(text:String):Bool {
			for (item in pending)
				if (text.indexOf(item.name) >= 0)
					return true;
			return false;
		}

		for (state in modules)
			if (matches(state.source.text))
				try inspect(state) catch (_:CompileError) {}
		sourceLoader.visitSources(matches, state -> {
			if (!modules.exists(state.name))
				inspect(state);
		});
		for (item in pending) {
			item.paths.sort(Reflect.compare);
			for (path in item.paths)
				item.diagnostic.notes.push('import $path;');
		}
	}

	public function parse(state:ModuleState, entry:String, bodyChanged:Map<String, Bool>,
			signatureChanged:Map<String, Bool>,
			structuralChanged:Map<String, Bool>):Void {
		if (state.ast != null) {
			if (buildSemanticModels && state.semanticModel == null)
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source,
					state.revision, state.tokens);
			return;
		}
		try {
			var parsed = sourceParse(state);
			lookupParses.remove(state.name);
			state.conditionalDefines = parsed.defines;
			state.embeddedInputs = parsed.embeddedInputs;
			state.tokens = keepsTokens ? parsed.tokens : TokenTable.empty;
			state.ast = parsed.ast;
			declarationOwners.release(state.name);
			if (!state.source.isStandardLibrarySource)
				checkStandardTypeNames(state.name, state.parsedAst());
			indexDeclarations(state.name, state.parsedAst());
			if (buildSemanticModels)
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source,
					state.revision, state.tokens);
			state.parseVersion++;
		} catch (error:CompileError) {
			state.diagnostics.push(error.diagnostic);
			throw error;
		}
		var ast = state.parsedAst(), scanned = new ScannedDependencies(), dependencies = scanned.required;
		for (imported in ast.imports) {
			var importPath = imported.path;
			var importedModules = importedSourceModules(importPath);
			if (importedModules.length == 0)
				dependencies.set(importModulePath(importPath), true);
			else
				for (importedModule in importedModules)
					dependencies.set(importedModule, true);
		}
		// A type's `@:using(pack.Tools)` names a module as a `using` does: its extensions are resolved from its declarations.
		for (path in StaticExtensionTable.metadataPaths(ast)) {
			var importedModules = importedSourceModules(path);
			if (importedModules.length == 0)
				dependencies.set(importModulePath(path), true);
			else
				for (importedModule in importedModules)
					dependencies.set(importedModule, true);
		}
		scanFunctionBodies(ast.functions, [], scanned);
		for (classDecl in ast.classes) {
			for (field in classDecl.fields) {
				var initializer = field.initializer;
				if (initializer != null)
					DependencyScanner.scanExpression(initializer, scanned, classDecl.typeParameters);
			}
			scanFunctionBodies(classDecl.methods, classDecl.typeParameters, scanned);
		}
		for (enumDecl in ast.enums)
			scanFunctionBodies(enumDecl.methods ?? [], enumDecl.typeParameters, scanned);
		for (abstractDecl in ast.abstracts)
			scanFunctionBodies(abstractDecl.methods, abstractDecl.typeParameters, scanned);
		for (abstractDecl in ast.abstracts)
			if (abstractDecl.values != null)
				for (value in abstractDecl.values)
					DependencyScanner.scanExpression(value.value, scanned);
		// A type named only in an annotation, cast or catch clause is a dependency when a source module has that name.
		// The dependency is the module that resolved: for `Types.Kind` in package `pk` that is `pk.Types`, while the
		// dotted type name itself names no module and the later passes do not qualify dotted names.
		for (owner in scanned.companionOwners.keys())
			addCompanionDependencies(owner, dependencies);
		for (typeName in scanned.optional.keys()) {
			var module = sourceModuleForDependency(typeName);
			if (module == null && ast.packageName != null)
				module = sourceModuleForDependency(ast.packageName + "." + typeName);
			if (module != null)
				dependencies.set(module, true);
		}
		for (classDecl in ast.classes) {
			dependencies.remove(classDecl.name);
			for (field in classDecl.fields)
				dependencies.remove(field.name);
		}
		// A constructor of this module's enums is a value here too: `Red.getIndex()` names no module.
		for (enumDecl in ast.enums) {
			dependencies.remove(enumDecl.name);
			for (constructor in enumDecl.cases)
				dependencies.remove(constructor.name);
		}
		// So is a value of its enum abstracts: `Beta.upper()`.
		for (abstractDecl in ast.abstracts) {
			dependencies.remove(abstractDecl.name);
			for (value in abstractDecl.values ?? [])
				dependencies.remove(value.name);
		}
		// A typedef this module declares is local too: `Code.High` through `typedef Code = ...` names no module.
		for (alias in ast.aliases)
			dependencies.remove(alias.name);
		for (imported in ast.imports) {
			var importPath = imported.path;
			var modulePath = importModulePath(importPath),
				alias = imported.alias == null ? QualifiedName.last(modulePath) : imported.alias;
			if (alias != modulePath)
				dependencies.remove(alias);
			if (isWildcardImport(importPath) && !modules.exists(modulePath))
				dependencies.remove(modulePath);
		}
		for (dependency in [for (dependency in dependencies.keys()) dependency])
			if (natives.hasChild(dependency) && sourceModuleForDependency(dependency) == null)
				dependencies.remove(dependency);
		var packageName = ast.packageName;
		for (dependency in [for (dependency in dependencies.keys()) dependency]) {
			// `Module.SubType` names a module of this package, as a bare type name does.
			if (packageName != null && isModuleRelativePath(dependency)) {
				var relativeModule = sourceModuleForDependency(packageName + "." + dependency);
				if (relativeModule != null) {
					dependencies.remove(dependency);
					dependencies.set(relativeModule, true);
					continue;
				}
			}
			var sourceModule = sourceModuleForDependency(dependency);
			if (sourceModule == null
				&& (PlatformAbi.isType(dependency) || isPlatformDependency(dependency)
				&& [for (entry in ast.imports) entry.path].indexOf(dependency) < 0)) {
				dependencies.remove(dependency);
				continue;
			}
			if (dependency.indexOf(".") < 0 && packageName != null) {
				var packageCandidate = packageName + "." + dependency;
				if (sourceModuleForDependency(packageCandidate) != null) {
					dependencies.remove(dependency);
					dependencies.set(packageCandidate, true);
					continue;
				}
			}
			// `Module.Type` written inside a package names a module of that package, as in Haxe.
			if (sourceModule == null && dependency.indexOf(".") >= 0 && packageName != null) {
				var packageModule = sourceModuleForDependency(packageName + "." + dependency);
				if (packageModule != null) {
					dependencies.remove(dependency);
					dependencies.set(packageModule, true);
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
		var typeAliases = AliasTable.of(importAliases(ast.imports));
		ModuleCanonicalizer.addDeclaredTypeAliases(typeAliases, ast, ast.packageName);
		var changes = ModuleChangeAnalyzer.analyze(state, entry, typeAliases, types, compiledOnce);
		mergeChanges(bodyChanged, changes.bodyChanged);
		mergeChanges(signatureChanged, changes.signatureChanged);
		mergeChanges(structuralChanged, changes.structuralChanged);
		ModuleChangeAnalyzer.publish(state, changes);
		state.dirty = false;
	}

	/**
	 * Adds the modules owning every type a declaration names outside a body: supertypes (with their type arguments),
	 * abstract underlying and conversion types, field types and signatures. A module reached only through one of these, such
	 * as a same-package interface that another extends without an import, is otherwise never loaded, and resolving the
	 * declaration fails with an unknown type whenever no other reachable module happens to name it.
	 */
	public function addTypeDependencies(state:ModuleState):Void {
		var dependencies:Map<String, Bool> = [];
		for (name in state.dependencies)
			dependencies.set(name, true);
		var ast = state.parsedAst();
		for (alias in ast.aliases)
			addModuleTypeDependency(alias.type, state, dependencies);
		for (enumDecl in ast.enums) {
			if (enumDecl.conformances != null)
				for (conformance in enumDecl.conformances) addModuleTypeDependency(conformance, state, dependencies);
			for (caseDecl in enumDecl.cases)
				for (parameter in caseDecl.params)
					addModuleTypeDependency(parameter.type, state, dependencies);
			if (enumDecl.methods != null)
				for (method in enumDecl.methods)
					addFunctionTypeDependencies(method, state, dependencies, enumDecl.typeParameters);
		}
		for (interfaceDecl in ast.interfaces) {
			for (base in interfaceDecl.bases)
				addModuleTypeDependency(base, state, dependencies);
			for (method in interfaceDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies, interfaceDecl.typeParameters);
		}
		for (classDecl in ast.classes) {
			var base = classDecl.base;
			if (base != null)
				addModuleTypeDependency(base, state, dependencies);
			for (interfaceType in classDecl.interfaces)
				addModuleTypeDependency(interfaceType, state, dependencies);
			// An unannotated field names only what its initializer names, which the module's expressions are scanned for.
			for (field in classDecl.fields) {
				var type = field.type;
				if (type != null)
					addModuleTypeDependency(type, state, dependencies);
			}
			for (method in classDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies, classDecl.typeParameters);
		}
		// Extern abstracts can name sibling modules only in their signatures (BytesInput -> Bytes).
		// Those references must participate in reachability just as class signatures do.
		for (abstractDecl in ast.abstracts) {
			addModuleTypeDependency(abstractDecl.underlying, state, dependencies, abstractDecl.typeParameters);
			for (type in abstractDecl.fromTypes.concat(abstractDecl.toTypes))
				addModuleTypeDependency(type, state, dependencies, abstractDecl.typeParameters);
			for (constraint in abstractDecl.typeConstraints ?? [])
				addModuleTypeDependency(constraint.type, state, dependencies, abstractDecl.typeParameters);
			for (field in abstractDecl.fields)
				if (field.type != null)
					addModuleTypeDependency(field.type, state, dependencies, abstractDecl.typeParameters);
			for (method in abstractDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies, abstractDecl.typeParameters);
			for (type in abstractDecl.conformances ?? [])
				addModuleTypeDependency(type, state, dependencies, abstractDecl.typeParameters);
		}
		for (fn in ast.functions)
			addFunctionTypeDependencies(fn, state, dependencies);
		// What typing a use of this module's declarations calls comes with it (`RuntimeType.companionModules`).
		addCompanionDependencies(state.name, dependencies);
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
	}

	function addCompanionDependencies(owner:String, dependencies:Map<String, Bool>):Void {
		for (companion in RuntimeType.companionModules(owner)) {
			if (!RuntimeType.hasCompanion(companion, natives.has))
				continue;
			var module = sourceModuleForDependency(companion);
			if (module != null)
				dependencies.set(module, true);
		}
	}

	public function importAliases(imports:Array<compiler.syntax.Ast.AstImport>):Map<String, String> {
		var aliases:Map<String, String> = [];
		for (entry in imports) {
			var path = entry.path;
			var modulePath = importModulePath(path);
			if (isWildcardImport(path)) {
				for (sourceModule in importedSourceModules(path))
					addModuleAliases(sourceModule, aliases, true, QualifiedName.last(sourceModule), true);
				continue;
			}
			var alias = entry.alias == null ? QualifiedName.last(path) : entry.alias,
				importedName = importedDeclarationName(path);
			aliases.set(alias, importedName);
			aliases.set(path, importedName);
			// `import pack.Module;` brings in each type of the module by name, as in Haxe. `import pack.Module as M;` is a
			// namespace: its types are reached only as `M.Type`, so they cannot shadow anything.
			if (modules.exists(modulePath))
				addModuleAliases(modulePath, aliases, false, alias, alias == QualifiedName.last(path));
		}
		// Explicit aliases keep their existing precedence over imported bare names.
		for (entry in imports)
			if (entry.alias != null)
				aliases.set(entry.alias, importedDeclarationName(entry.path));
		return aliases;
	}

	/** True for the Haxe package/module wildcard form, such as `foo.bar.*`. */
	public static inline function isWildcardImport(path:String):Bool
		return StringTools.endsWith(path, ".*");

	/** Return the module/package portion of an import path. */
	public static inline function importModulePath(path:String):String
		return isWildcardImport(path) ? path.substring(0, path.length - 2) : path;

	function addModuleAliases(moduleName:String, aliases:Map<String, String>, includeFunctions:Bool, moduleAlias:String,
			bare:Bool):Void {
		var ast = moduleAst(moduleName);
		if (ast == null)
			return;
		for (declaration in ast.aliases)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias, bare);
		for (declaration in ast.enums)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias, bare);
		for (declaration in ast.abstracts)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias, bare);
		for (declaration in ast.interfaces)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias, bare);
		for (declaration in ast.classes)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias, bare);
		if (includeFunctions)
			for (declaration in ast.functions)
				addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias, bare);
	}

	function addDeclarationAlias(moduleName:String, declarationName:String, aliases:Map<String, String>,
			moduleAlias:String, bare:Bool):Void {
		var sourceName = ModuleCanonicalizer.sourceDeclarationPath(moduleName, declarationName),
			importedName = importedDeclarationName(sourceName);
		if (bare && !aliases.exists(declarationName))
			aliases.set(declarationName, importedName);
		aliases.set(sourceName, importedName);
		aliases.set(moduleAlias + "." + declarationName, importedName);
	}

	function moduleAst(moduleName:String):Null<compiler.syntax.Ast.AstProgram> {
		var state = modules.get(moduleName);
		if (state == null)
			return null;
		if (state.ast != null)
			return state.parsedAst();
		var parsed = sourceParse(state);
		lookupParses.set(moduleName, parsed);
		return parsed.ast;
	}

	/**
	 * Drops the parses kept for lookups into modules this build does not compile, and the imported members worked out from syntax
	 * trees; a later lookup parses again.
	 */
	public function releaseLookupParses():Void {
		lookupParses.clear();
		importedMembers.clear();
	}

	/** Parses the module's current source, or returns the lookup parse of that same source. */
	function sourceParse(state:ModuleState):LookupParse {
		var cached = lookupParses.get(state.name);
		if (cached != null && cached.source == state.source)
			return cached;
		return parseText(state);
	}

	/**
	 * Parses every module of `states` that has neither a syntax tree nor a parse of its current source, on `threads` threads, into
	 * the cache `parse` reads first. Parses read their own source and embedded assets, and the results are kept in the
	 * modules' order, so the program is the same whatever the scheduling. A module whose parse fails is left to `parse`, which
	 * parses it again and reports the error as it always does.
	 */
	public function prefetchParses(states:Array<ModuleState>, threads:Int):Void {
		var pending = [
			for (state in states)
				if (state.ast == null
				&& !(lookupParses.exists(state.name) && lookupParses.get(state.name).source == state.source)) state
		];
		var parsed:Array<Null<LookupParse>> = [];
		parsed.resize(pending.length);
		for (index in 0...pending.length)
			parsed[index] = null;
		compiler.core.Parallel.forEach(pending.length, threads, function(index) {
			try
				parsed[index] = parseText(pending[index])
			catch (_:haxe.Exception) {}
		});
		for (index in 0...pending.length) {
			var result = parsed[index];
			if (result != null)
				lookupParses.set(pending[index].name, result);
		}
	}

	/** The parse of `state`'s current source, including any declared embedded inputs. */
	function parseText(state:ModuleState):LookupParse {
		var conditional = ConditionalCompilation.process(state.source, defines),
			tokens = new Lexer(state.source, conditional.text).tokenizeTable(),
			embedded = new compiler.core.EmbeddedText(),
			program = state.name == scriptModule ? Parser.parseScript(tokens, embedded) : new Parser(tokens,
				embedded).parseProgram();
		if (program.packageName == null) {
			var packageName = ModulePath.packageName(state.name);
			if (packageName != null)
				program = {
					packageName: packageName,
					imports: program.imports,
					usings: program.usings,
					aliases: program.aliases,
					enums: program.enums,
					abstracts: program.abstracts,
					interfaces: program.interfaces,
					classes: program.classes,
					functions: program.functions,
					fields: program.fields
				};
		}
		program = ModuleFields.fold(AbstractStatics.fold(program), state.name);
		return new LookupParse(state.source, conditional.defines, tokens, program, embedded.inputs());
	}

	static function scanFunctionBodies(functions:Array<AstFunction>, ownerParameters:Array<String>,
			dependencies:ScannedDependencies):Void {
		for (fn in functions) {
			var parameters = ownerParameters.length == 0 ? fn.typeParameters
				: ownerParameters.concat(fn.typeParameters ?? []);
			for (statement in fn.statements)
				DependencyScanner.scanStatement(statement, dependencies, parameters);
		}
	}

	function addFunctionTypeDependencies(fn:AstFunction, state:ModuleState, dependencies:Map<String, Bool>,
			?ownerParameters:Array<String>):Void {
		var parameters = (ownerParameters == null ? [] : ownerParameters).concat(fn.typeParameters == null
			? [] : fn.typeParameters);
		for (argument in fn.arguments)
			addModuleTypeDependency(argument.type, state, dependencies, parameters);
		addModuleTypeDependency(fn.result, state, dependencies, parameters);
		for (constraint in fn.typeConstraints ?? [])
			addModuleTypeDependency(constraint.type, state, dependencies, parameters);
	}

	function addModuleTypeDependency(type:compiler.syntax.Ast.AstType, state:ModuleState,
			dependencies:Map<String, Bool>, ?parameters:Array<String>):Void
		switch type {
			case NamedType(name):
				if (parameters == null || parameters.indexOf(name) < 0) {
					var ast = state.parsedAst(),
						owner = sourceModuleForType(name, ast.packageName);
					if (owner != null && owner != state.name)
						dependencies.set(owner, true);
				}
			case AppliedType(name, arguments):
				if (name == "KeyValueIterable")
					addCompanionDependencies(name, dependencies);
				if (parameters == null || parameters.indexOf(name) < 0) {
					var ast = state.parsedAst(),
						owner = sourceModuleForType(name, ast.packageName);
					if (owner != null && owner != state.name)
						dependencies.set(owner, true);
				}
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies, parameters);
			case ArrayType(element), NullableType(element):
				addModuleTypeDependency(element, state, dependencies, parameters);
			case MapType(key, value):
				if (DependencyScanner.mayUseObjectMap(key, parameters))
					addCompanionDependencies("Map", dependencies);
				addModuleTypeDependency(key, state, dependencies, parameters);
				addModuleTypeDependency(value, state, dependencies, parameters);
			case FunctionType(arguments, result, _):
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies, parameters);
				addModuleTypeDependency(result, state, dependencies, parameters);
			case AnonymousType(fields):
				for (field in fields) {
					if (field.name == "keyValueIterator")
						addCompanionDependencies("KeyValueIterable", dependencies);
					addModuleTypeDependency(field.type, state, dependencies, parameters);
				}
			default:
		}

	function sourceModuleForType(typeName:String, packageName:Null<String>):Null<String> {
		// `Module.SubType` resolves through this package first, then as an absolute path.
		if (packageName != null && isModuleRelativePath(typeName)) {
			var relative = sourceModuleForDependency(packageName + "." + typeName);
			if (relative != null)
				return relative;
		}
		var qualified = typeName.indexOf(".") < 0 && packageName != null ? packageName + "." + typeName : typeName,
			module = sourceModuleForDependency(qualified);
		if (module != null)
			return module;
		var declared = declarationOwners.get(qualified);
		if (declared != null) return declared;
		// A package-local lookup can fall back to a root declaration such as Equatable.
		return qualified != typeName ? sourceModuleForDependency(typeName) : null;
	}

	/**
	 * A type's path is its package and name, not its module: a type a module declares beside its main type, at the path of a
	 * standard library type, redefines that type, which Haxe rejects. It is rejected here whether or not the build loads the
	 * standard type, so every target reports it alike. A module at the standard module's own path replaces that module
	 * instead, as an earlier class path does in Haxe.
	 */
	function checkStandardTypeNames(moduleName:String, ast:compiler.syntax.Ast.AstProgram):Void {
		var prefix = ast.packageName == null ? "" : Std.string(ast.packageName) + ".";
		function check(name:String, isPrivate:Bool, span:compiler.core.Source.SourceSpan):Void {
			var path = prefix + name;
			if (!isPrivate && path != moduleName && sourceLoader.isStandardModule(path))
				throw new CompileError(new compiler.core.Diagnostic(DiagnosticCode.LOOKUP_OR_DECLARATION,
					'Type name $path is redefined from module $moduleName', span));
		}
		for (declaration in ast.aliases)
			check(declaration.name, declaration.isPrivate, declaration.span);
		for (declaration in ast.enums)
			check(declaration.name, false, declaration.span);
		for (declaration in ast.abstracts)
			check(declaration.name, false, declaration.span);
		for (declaration in ast.interfaces)
			check(declaration.name, false, declaration.span);
		for (declaration in ast.classes)
			check(declaration.name, declaration.isPrivate, declaration.span);
	}

	function indexDeclarations(moduleName:String, ast:compiler.syntax.Ast.AstProgram):Void {
		var prefix = ast.packageName == null ? "" : Std.string(ast.packageName) + ".";
		for (declaration in ast.aliases)
			indexDeclaration(prefix + declaration.name, moduleName);
		for (declaration in ast.enums)
			indexDeclaration(prefix + declaration.name, moduleName);
		for (declaration in ast.abstracts)
			indexDeclaration(prefix + declaration.name, moduleName);
		for (declaration in ast.interfaces)
			indexDeclaration(prefix + declaration.name, moduleName);
		for (declaration in ast.classes)
			indexDeclaration(prefix + declaration.name, moduleName);
	}

	inline function indexDeclaration(name:String, moduleName:String):Void {
		declarationOwners.claim(name, moduleName);
	}

	function hasSourceModuleImport(imports:Array<compiler.syntax.Ast.AstImport>):Bool {
		for (entry in imports)
			if (importedSourceModules(entry.path).length > 0)
				return true;
		return false;
	}

	function importedDeclarationName(path:String):String {
		var modulePath = importModulePath(path),
			sourceModule = sourceModuleForDependency(modulePath);
		if (sourceModule == null || sourceModule == modulePath)
			return path;
		var packageName = QualifiedName.parentOrEmpty(sourceModule),
			nestedName = modulePath.substring(sourceModule.length + 1, modulePath.length);
		// `import pkg.Module.member` names a function declared in the module or a static member of its main class (as in
		// Haxe), which keeps its module qualifier so that a bare use resolves to it. Types are named by package instead.
		if (nestedName.indexOf(".") < 0 && isImportedMember(sourceModule, nestedName))
			return sourceModule + "." + nestedName;
		return packageName.length == 0 ? nestedName : packageName + "." + nestedName;
	}

	/**
	 * Whether `name` is a function declared at the top of the module, or else a static function or field of the class that
	 * shares the module's name with no type of that name declared in the module.
	 */
	function isImportedMember(moduleName:String, name:String):Bool {
		var ast = moduleAst(moduleName);
		if (ast == null)
			return false;
		var entry = importedMembers.get(moduleName);
		if (entry == null || entry.ast != ast) {
			entry = {ast: ast, members: importedMembersOf(moduleName, ast)};
			importedMembers.set(moduleName, entry);
		}
		return entry.members.exists(name);
	}

	/** The names `import module.name` takes as members of `moduleName`, worked out once per parsed module (see `isImportedMember`). */
	static function importedMembersOf(moduleName:String, ast:compiler.syntax.Ast.AstProgram):Map<String, Bool> {
		var members:Map<String, Bool> = [], typeNames:Map<String, Bool> = [];
		for (declaration in ast.functions)
			members.set(declaration.name, true);
		for (declaration in ast.classes)
			typeNames.set(declaration.name, true);
		for (declaration in ast.enums)
			typeNames.set(declaration.name, true);
		for (declaration in ast.abstracts)
			typeNames.set(declaration.name, true);
		for (declaration in ast.interfaces)
			typeNames.set(declaration.name, true);
		for (declaration in ast.aliases)
			typeNames.set(declaration.name, true);
		// Module-level variables are members of the module, as its functions are (ModuleFields).
		if (ast.fields != null)
			for (field in ast.fields)
				members.set(field.name, true);
		var mainName = QualifiedName.last(moduleName);
		for (declaration in ast.classes)
			if (declaration.name == mainName) {
				for (method in declaration.methods)
					if (method.isStatic && !typeNames.exists(method.name))
						members.set(method.name, true);
				for (field in declaration.fields)
					if (field.isStatic && !typeNames.exists(field.name))
						members.set(field.name, true);
			}
		return members;
	}

	function sourceModuleForDependency(path:String):Null<String> {
		var candidate = importModulePath(path);
		while (true) {
			sourceLoader.load(candidate, modules);
			if (modules.exists(candidate))
				return candidate;
			var parent = QualifiedName.parentOrEmpty(candidate);
			if (parent.length == 0)
				return null;
			candidate = parent;
		}
	}

	function importedSourceModules(path:String):Array<String> {
		var modulePath = importModulePath(path);
		if (!isWildcardImport(path)) {
			var sourceModule = sourceModuleForDependency(modulePath);
			return sourceModule == null ? [] : [sourceModule];
		}
		// A wildcard can target either a module (`Module.*`) or a package
		// (`package.*`). Prefer the exact module when one exists.
		sourceLoader.load(modulePath, modules);
		if (modules.exists(modulePath))
			return [modulePath];
		return sourceLoader.loadPackage(modulePath, modules);
	}

	public function loadSourceModuleDependency(path:String):Null<String>
		return sourceModuleForDependency(path);

	/** A dotted type path that starts with a module or type name (capitalised), not a package. */
	static function isModuleRelativePath(path:String):Bool {
		if (path.indexOf(".") < 0)
			return false;
		var first = StringTools.fastCodeAt(path, 0);
		return first >= "A".code && first <= "Z".code;
	}

	static function isPlatformDependency(path:String):Bool {
		var root = QualifiedName.first(path);
		return root == "haxe" || root == "sys" || root == "hl" || root == "Array" || root == "String" || root == "Math"
			|| root == "Reflect"
			|| root == "Std" || root == "StringTools" || root == "Type";
	}

	static function mergeChanges(target:Map<String, Bool>, source:Map<String, Bool>):Void
		for (name in source.keys())
			target.set(name, true);
}

/** A module's source parsed ahead of its own parse, for an import lookup. */
private class LookupParse {
	public final source:compiler.core.Source.SourceFile;
	public final defines:Array<String>;
	public final tokens:TokenTable;
	public final ast:compiler.syntax.Ast.AstProgram;

	public final embeddedInputs:Array<compiler.core.EmbeddedText.EmbeddedInput>;

	public function new(source, defines, tokens, ast, embeddedInputs) {
		this.source = source;
		this.defines = defines;
		this.tokens = tokens;
		this.ast = ast;
		this.embeddedInputs = embeddedInputs;
	}
}
