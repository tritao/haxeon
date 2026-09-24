package compiler.semantic;

import compiler.syntax.Ast.AstFunction;
import compiler.Diagnostic.CompileError;
import compiler.syntax.Lexer;
import compiler.syntax.ConditionalCompilation;
import compiler.syntax.Parser;
import compiler.QualifiedName;
import compiler.runtime.NativeRegistry;
import compiler.runtime.PlatformAbi;
import compiler.modules.ModuleState;
import compiler.modules.ModuleSourceLoader;
import compiler.types.FieldInference;
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
	final declarationOwners:Map<String, String>;

	public function new(modules:Map<String, ModuleState>, types:TypeRegistry, natives:NativeRegistry, compiledOnce:Bool, defines:Map<String, String>,
			sourceLoader:ModuleSourceLoader, ?buildSemanticModels = true, ?declarationOwners:Map<String, String>) {
		this.modules = modules;
		this.types = types;
		this.natives = natives;
		this.compiledOnce = compiledOnce;
		this.buildSemanticModels = buildSemanticModels;
		this.defines = defines;
		this.sourceLoader = sourceLoader;
		this.declarationOwners = declarationOwners == null ? [] : declarationOwners;
		if (declarationOwners == null)
			for (name => state in modules)
				if (state.ast != null)
					indexDeclarations(name, state.parsedAst());
	}

	public function parse(state:ModuleState, entry:String, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>,
			structuralChanged:Map<String, Bool>):Void {
		if (state.ast != null) {
			if (buildSemanticModels && state.semanticModel == null)
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source, state.revision, state.tokens);
			return;
		}
		try {
			var conditional = ConditionalCompilation.process(state.source, defines);
			state.conditionalDefines = conditional.defines;
			state.tokens = new Lexer(state.source, conditional.text).tokenize();
			state.ast = new Parser(state.tokens).parseProgram();
			for (declaration => owner in [for (declaration => owner in declarationOwners) declaration => owner])
				if (owner == state.name)
					declarationOwners.remove(declaration);
			indexDeclarations(state.name, state.parsedAst());
			if (buildSemanticModels)
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source, state.revision, state.tokens);
			state.parseVersion++;
		} catch (error:CompileError) {
			state.diagnostics.push(error.diagnostic);
			throw error;
		}
		var ast = state.parsedAst(), dependencies:Map<String, Bool> = [];
		for (importPath in ast.imports) {
			var importedModules = importedSourceModules(importPath);
			if (importedModules.length == 0)
				dependencies.set(importModulePath(importPath), true);
			else
				for (importedModule in importedModules)
					dependencies.set(importedModule, true);
		}
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
			var modulePath = importModulePath(importPath),
				alias = QualifiedName.last(modulePath);
			if (alias != modulePath)
				dependencies.remove(alias);
			if (isWildcardImport(importPath) && !modules.exists(modulePath))
				dependencies.remove(modulePath);
		}
		for (alias in ast.importAliases.keys())
			dependencies.remove(alias);
		for (dependency in [for (dependency in dependencies.keys()) dependency])
			if (natives.hasChild(dependency) && sourceModuleForDependency(dependency) == null)
				dependencies.remove(dependency);
		var packageName = ast.packageName;
		for (dependency in [for (dependency in dependencies.keys()) dependency]) {
			var sourceModule = sourceModuleForDependency(dependency);
			if (sourceModule == null
				&& (PlatformAbi.isType(dependency) || isPlatformDependency(dependency) && ast.imports.indexOf(dependency) < 0)) {
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
		state.wireFieldFingerprints = changes.wireFieldFingerprints;
		state.staticInitializerFingerprints = changes.staticInitializerFingerprints;
		state.instanceInitializerFingerprints = changes.instanceInitializerFingerprints;
		state.dirty = false;
	}

	public function addTypeDependencies(state:ModuleState):Void {
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
				var owner = sourceModuleForType(ModuleCanonicalizer.astTypeName(base), ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
			}
			for (interfaceType in classDecl.interfaces) {
				var owner = sourceModuleForType(ModuleCanonicalizer.astTypeName(interfaceType), ast.packageName);
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

	public function importAliases(imports:Array<String>, explicit:Map<String, String>):Map<String, String> {
		var aliases:Map<String, String> = [];
		for (path in imports) {
			var modulePath = importModulePath(path);
			if (isWildcardImport(path)) {
				for (sourceModule in importedSourceModules(path))
					addModuleAliases(sourceModule, aliases, true, QualifiedName.last(sourceModule));
				continue;
			}
			var alias = QualifiedName.last(path),
				importedName = importedDeclarationName(path);
			for (explicitAlias => explicitPath in explicit)
				if (explicitPath == path) {
					alias = explicitAlias;
					break;
				}
			aliases.set(alias, importedName);
			aliases.set(path, importedName);
			if (modules.exists(modulePath))
				addModuleAliases(modulePath, aliases, false, alias);
		}
		for (alias => path in explicit) {
			aliases.set(alias, importedDeclarationName(path));
			aliases.set(path, importedDeclarationName(path));
		}
		return aliases;
	}

	/** True for the Haxe package/module wildcard form, such as `foo.bar.*`. */
	public static inline function isWildcardImport(path:String):Bool
		return StringTools.endsWith(path, ".*");

	/** Return the module/package portion of an import path. */
	public static inline function importModulePath(path:String):String
		return isWildcardImport(path) ? path.substring(0, path.length - 2) : path;

	function addModuleAliases(moduleName:String, aliases:Map<String, String>, includeFunctions:Bool, moduleAlias:String):Void {
		var ast = moduleAst(moduleName);
		if (ast == null)
			return;
		for (declaration in ast.aliases)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias);
		for (declaration in ast.enums)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias);
		for (declaration in ast.enumAbstracts)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias);
		for (declaration in ast.abstracts)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias);
		for (declaration in ast.interfaces)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias);
		for (declaration in ast.classes)
			addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias);
		if (includeFunctions)
			for (declaration in ast.functions)
				addDeclarationAlias(moduleName, declaration.name, aliases, moduleAlias);
	}

	function addDeclarationAlias(moduleName:String, declarationName:String, aliases:Map<String, String>, moduleAlias:String):Void {
		var sourceName = ModuleCanonicalizer.sourceDeclarationPath(moduleName, declarationName),
			importedName = importedDeclarationName(sourceName);
		if (!aliases.exists(declarationName))
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
		var conditional = ConditionalCompilation.process(state.source, defines),
			tokens = new Lexer(state.source, conditional.text).tokenize();
		return new Parser(tokens).parseProgram();
	}

	function addFunctionTypeDependencies(fn:AstFunction, state:ModuleState, dependencies:Map<String, Bool>):Void {
		for (argument in fn.arguments)
			addModuleTypeDependency(argument.type, state, dependencies);
		addModuleTypeDependency(fn.result, state, dependencies);
	}

	function addModuleTypeDependency(type:compiler.syntax.Ast.AstType, state:ModuleState, dependencies:Map<String, Bool>):Void
		switch type {
			case NamedType(name):
				var ast = state.parsedAst(),
					owner = sourceModuleForType(name, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
			case AppliedType(name, arguments):
				var ast = state.parsedAst(),
					owner = sourceModuleForType(name, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies);
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
		return declarationOwners.get(qualified);
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
		if (!declarationOwners.exists(name))
			declarationOwners.set(name, moduleName);
	}

	function hasSourceModuleImport(imports:Array<String>):Bool {
		for (importPath in imports)
			if (importedSourceModules(importPath).length > 0)
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
		return packageName.length == 0 ? nestedName : packageName + "." + nestedName;
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

	static function isPlatformDependency(path:String):Bool {
		var root = QualifiedName.first(path);
		return root == "haxe" || root == "sys" || root == "hl" || root == "Array" || root == "String" || root == "Math" || root == "Reflect"
			|| root == "Std" || root == "StringTools" || root == "Type";
	}

	static function mergeChanges(target:Map<String, Bool>, source:Map<String, Bool>):Void
		for (name in source.keys())
			target.set(name, true);
}
