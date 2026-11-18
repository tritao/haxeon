package compiler.semantic;

import compiler.core.Diagnostic.CompileError;
import compiler.core.QualifiedName;
import compiler.modules.ModulePath;
import compiler.modules.ModuleSourceLoader;
import compiler.modules.ModuleState;
import compiler.runtime.NativeRegistry;
import compiler.runtime.PlatformAbi;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.TypeRegistry;

/** Parses modules and derives their normalized source, type, and semantic dependencies. */
class ModuleAnalyzer {
	final modules:Map<String, ModuleState>;
	final types:TypeRegistry;
	final natives:NativeRegistry;
	final compiledOnce:Bool;
	final buildSemanticModels:Bool;
	final defines:Map<String, String>;
	final sourceLoader:ModuleSourceLoader;
	final declarationOwners:DeclarationOwners;
	// Import resolution reads the declarations of modules that are not parsed yet, once per imported declaration. Each such
	// parse is kept here until the module's own parse adopts it.
	final lookupParses:Map<String, LookupParse> = [];
	final importedMembers:Map<String, {ast:compiler.syntax.Ast.AstProgram, members:Map<String, Bool>}> = [];

	public function new(modules:Map<String, ModuleState>, types:TypeRegistry, natives:NativeRegistry, compiledOnce:Bool,
			defines:Map<String, String>,
			sourceLoader:ModuleSourceLoader, ?buildSemanticModels = true, ?declarationOwners:DeclarationOwners) {
		this.modules = modules;
		this.types = types;
		this.natives = natives;
		this.compiledOnce = compiledOnce;
		this.buildSemanticModels = buildSemanticModels;
		this.defines = defines;
		this.sourceLoader = sourceLoader;
		this.declarationOwners = declarationOwners == null ? new DeclarationOwners() : declarationOwners;
		if (declarationOwners == null)
			for (name => state in modules)
				if (state.ast != null)
					indexDeclarations(name, state.parsedAst());
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
			state.tokens = parsed.tokens;
			state.ast = parsed.ast;
			declarationOwners.release(state.name);
			indexDeclarations(state.name, state.parsedAst());
			if (buildSemanticModels)
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source,
					state.revision, state.tokens);
			state.parseVersion++;
		} catch (error:CompileError) {
			state.diagnostics.push(error.diagnostic);
			throw error;
		}
		var ast = state.parsedAst(), dependencies:Map<String, Bool> = [];
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
		for (fn in ast.functions)
			for (statement in fn.statements)
				DependencyScanner.scanStatement(statement, dependencies, fn.typeParameters);
		for (classDecl in ast.classes)
			for (field in classDecl.fields) {
				var initializer = field.initializer;
				if (initializer != null)
					DependencyScanner.scanExpression(initializer, dependencies, classDecl.typeParameters);
			}
		for (classDecl in ast.classes) {
			var ownerTypeParameters = classDecl.typeParameters;
			for (method in classDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies,
						ownerTypeParameters.concat(method.typeParameters == null ? [] : method.typeParameters));
		}
		for (abstractDecl in ast.abstracts) {
			var ownerTypeParameters = abstractDecl.typeParameters;
			for (method in abstractDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies,
						ownerTypeParameters.concat(method.typeParameters == null ? [] : method.typeParameters));
		}
		for (abstractDecl in ast.enumAbstracts)
			for (value in abstractDecl.values)
				DependencyScanner.scanExpression(value.value, dependencies);
		// A type named only in an annotation, cast or catch clause is a dependency when a source module has that name.
		// The dependency is the module that resolved: for `Types.Kind` in package `pk` that is `pk.Types`, while the
		// dotted type name itself names no module and the later passes do not qualify dotted names.
		for (key in [for (key in dependencies.keys()) key])
			if (StringTools.startsWith(key, DependencyScanner.OPTIONAL_PREFIX)) {
				dependencies.remove(key);
				var typeName = key.substr(DependencyScanner.OPTIONAL_PREFIX.length);
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
		for (abstractDecl in ast.enumAbstracts)
			dependencies.remove(abstractDecl.name);
		for (abstractDecl in ast.abstracts)
			dependencies.remove(abstractDecl.name);
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
			// An optional dependency is kept only as the module it names, if any.
			if (dependencies.get(dependency) == false) {
				dependencies.remove(dependency);
				var optional = packageName != null
					&& dependency.indexOf(".") < 0 ? sourceModuleForDependency(packageName + "." + dependency) : null;
				if (optional == null)
					optional = sourceModuleForDependency(dependency);
				if (optional != null && optional != state.name)
					dependencies.set(optional, true);
				continue;
			}
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
		var previousDependencies = state.semanticDependencies;
		state.semanticDependencies = SemanticDependencyCollector.collectSemanticDependencies(state, entry, typeAliases);
		// What typing read stays until the reader is typed again: the edges walked to find the readers of a changed inferred type
		// must include those of a module edited in the same build.
		for (owner => dependencies in previousDependencies)
			for (dependency in dependencies)
				if (dependency.kind == compiler.modules.ModuleState.SemanticDependencyKind.DeclarationType)
					SemanticDependencyCollector.addDependency(state.semanticDependencies, owner, dependency.kind,
						dependency.target, dependency.targetId);
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
		}
		for (abstractDecl in ast.enumAbstracts) {
			if (abstractDecl.conformances != null)
				for (type in abstractDecl.conformances) addModuleTypeDependency(type, state, dependencies);
			addModuleTypeDependency(abstractDecl.underlying, state, dependencies);
			for (type in abstractDecl.fromTypes.concat(abstractDecl.toTypes))
				addModuleTypeDependency(type, state, dependencies);
		}
		for (fn in ast.functions)
			addFunctionTypeDependencies(fn, state, dependencies);
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
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
		for (declaration in ast.enumAbstracts)
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

	/** Parses the module's current source, or returns the lookup parse of that same source. */
	function sourceParse(state:ModuleState):LookupParse {
		var cached = lookupParses.get(state.name);
		if (cached != null && cached.source == state.source)
			return cached;
		return parseText(state);
	}

	/**
	 * Parses every module of `states` that has neither a syntax tree nor a parse of its current source, on `threads` threads, into
	 * the cache `parse` reads first. Parsing a module reads only its own source and the defines, and the results are kept in the
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

	/** The parse of `state`'s current source, which reads nothing but the source and the defines. */
	function parseText(state:ModuleState):LookupParse {
		var conditional = ConditionalCompilation.process(state.source, defines),
			tokens = new Lexer(state.source, conditional.text).tokenize(),
			program = new Parser(tokens).parseProgram();
		if (program.packageName == null) {
			var packageName = ModulePath.packageName(state.name);
			if (packageName != null)
				program = {
					packageName: packageName,
					imports: program.imports,
					usings: program.usings,
					aliases: program.aliases,
					enums: program.enums,
					enumAbstracts: program.enumAbstracts,
					abstracts: program.abstracts,
					interfaces: program.interfaces,
					classes: program.classes,
					functions: program.functions,
					fields: program.fields
				};
		}
		program = ModuleFields.fold(AbstractStatics.fold(program), state.name);
		return new LookupParse(state.source, conditional.defines, tokens, program);
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
				addModuleTypeDependency(key, state, dependencies, parameters);
				addModuleTypeDependency(value, state, dependencies, parameters);
			case FunctionType(arguments, result, _):
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies, parameters);
				addModuleTypeDependency(result, state, dependencies, parameters);
			case AnonymousType(fields):
				for (field in fields)
					addModuleTypeDependency(field.type, state, dependencies, parameters);
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

	function indexDeclarations(moduleName:String, ast:compiler.syntax.Ast.AstProgram):Void {
		var prefix = ast.packageName == null ? "" : Std.string(ast.packageName) + ".";
		for (declaration in ast.aliases)
			indexDeclaration(prefix + declaration.name, moduleName);
		for (declaration in ast.enums)
			indexDeclaration(prefix + declaration.name, moduleName);
		for (declaration in ast.enumAbstracts)
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
		for (declaration in ast.enumAbstracts)
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
	public final tokens:Array<compiler.syntax.Token>;
	public final ast:compiler.syntax.Ast.AstProgram;

	public function new(source, defines, tokens, ast) {
		this.source = source;
		this.defines = defines;
		this.tokens = tokens;
		this.ast = ast;
	}
}
