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
	final declarationOwners:Map<String, String> = [];

	public function new(modules:Map<String, ModuleState>, types:TypeRegistry, natives:NativeRegistry, compiledOnce:Bool, defines:Map<String, String>,
			sourceLoader:ModuleSourceLoader, ?buildSemanticModels = true) {
		this.modules = modules;
		this.types = types;
		this.natives = natives;
		this.compiledOnce = compiledOnce;
		this.buildSemanticModels = buildSemanticModels;
		this.defines = defines;
		this.sourceLoader = sourceLoader;
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
			indexDeclarations(state.name, state.parsedAst());
			if (buildSemanticModels)
				state.semanticModel = new compiler.semantic.SemanticModel(state.parsedAst(), state.source, state.revision, state.tokens);
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
				DependencyScanner.scanStatement(statement, dependencies, fn.typeParameters == null ? [] : fn.typeParameters);
		for (classDecl in ast.classes)
			for (field in classDecl.fields) {
				var initializer = field.initializer;
				if (initializer != null)
					DependencyScanner.scanExpression(initializer, dependencies, classDecl.typeParameters);
			}
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies,
						classDecl.typeParameters.concat(method.typeParameters == null ? [] : method.typeParameters));
		for (abstractDecl in ast.abstracts)
			for (method in abstractDecl.methods)
				for (statement in method.statements)
					DependencyScanner.scanStatement(statement, dependencies,
						abstractDecl.typeParameters.concat(method.typeParameters == null ? [] : method.typeParameters));
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
			var alias = QualifiedName.last(importPath);
			if (alias != importPath)
				dependencies.remove(alias);
		}
		for (alias in ast.importAliases.keys())
			dependencies.remove(alias);
		for (dependency in [for (dependency in dependencies.keys()) dependency])
			if (natives.hasChild(dependency) && sourceModuleForDependency(dependency) == null)
				dependencies.remove(dependency);
		var packageName = ast.packageName;
		for (dependency in [for (dependency in dependencies.keys()) dependency]) {
			var sourceModule = sourceModuleForType(dependency, packageName);
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
					addModuleTypeDependency(parameter.type, state, dependencies, enumDecl.typeParameters);
		for (interfaceDecl in ast.interfaces)
			for (method in interfaceDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies, interfaceDecl.typeParameters);
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
				addModuleTypeDependency(FieldInference.parsedType(field), state, dependencies, classDecl.typeParameters);
			for (method in classDecl.methods)
				addFunctionTypeDependencies(method, state, dependencies,
					classDecl.typeParameters.concat(method.typeParameters == null ? [] : method.typeParameters));
		}
		for (fn in ast.functions)
			addFunctionTypeDependencies(fn, state, dependencies, fn.typeParameters == null ? [] : fn.typeParameters);
		state.dependencies = [for (name in dependencies.keys()) name];
		state.dependencies.sort(Reflect.compare);
	}

	public function importAliases(imports:Array<String>, explicit:Map<String, String>):Map<String, String> {
		var aliases:Map<String, String> = [];
		for (path in imports) {
			var alias = QualifiedName.last(path);
			aliases.set(alias, importedDeclarationName(path));
			aliases.set(path, importedDeclarationName(path));
		}
		for (alias => path in explicit) {
			aliases.set(alias, importedDeclarationName(path));
			aliases.set(path, importedDeclarationName(path));
		}
		return aliases;
	}

	function addFunctionTypeDependencies(fn:AstFunction, state:ModuleState, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void {
		for (argument in fn.arguments)
			addModuleTypeDependency(argument.type, state, dependencies, typeParameters);
		addModuleTypeDependency(fn.result, state, dependencies, typeParameters);
	}

	function addModuleTypeDependency(type:compiler.syntax.Ast.AstType, state:ModuleState, dependencies:Map<String, Bool>, ?typeParameters:Array<String>):Void
		switch type {
			case NamedType(name):
				if (typeParameters != null && typeParameters.indexOf(name) >= 0)
					return;
				var ast = state.parsedAst(),
					owner = sourceModuleForType(name, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
			case AppliedType(name, arguments):
				if (typeParameters != null && typeParameters.indexOf(name) >= 0)
					return;
				var ast = state.parsedAst(),
					owner = sourceModuleForType(name, ast.packageName);
				if (owner != null && owner != state.name)
					dependencies.set(owner, true);
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies, typeParameters);
			case ArrayType(element), NullableType(element):
				addModuleTypeDependency(element, state, dependencies, typeParameters);
			case MapType(key, value):
				addModuleTypeDependency(key, state, dependencies, typeParameters);
				addModuleTypeDependency(value, state, dependencies, typeParameters);
			case FunctionType(arguments, result):
				for (argument in arguments)
					addModuleTypeDependency(argument, state, dependencies, typeParameters);
				addModuleTypeDependency(result, state, dependencies, typeParameters);
			case AnonymousType(fields):
				for (field in fields)
					addModuleTypeDependency(field.type, state, dependencies, typeParameters);
			default:
		}

	function sourceModuleForType(typeName:String, packageName:Null<String>):Null<String> {
		var qualified = typeName.indexOf(".") < 0 && packageName != null ? packageName + "." + typeName : typeName,
			module = sourceModuleForDependency(qualified);
		if (module != null)
			return module;
		if (qualified != typeName) {
			module = sourceModuleForDependency(typeName);
			if (module != null)
				return module;
		}
		var owner = declarationOwners.get(qualified);
		return owner != null ? owner : declarationOwners.get(typeName);
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
			if (sourceModuleForDependency(importPath) != null)
				return true;
		return false;
	}

	function importedDeclarationName(path:String):String {
		var sourceModule = sourceModuleForDependency(path);
		if (sourceModule == null || sourceModule == path)
			return path;
		var packageName = QualifiedName.parentOrEmpty(sourceModule),
			nestedName = path.substring(sourceModule.length + 1, path.length);
		return packageName.length == 0 ? nestedName : packageName + "." + nestedName;
	}

	function sourceModuleForDependency(path:String):Null<String> {
		var candidate = path;
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

	public function loadSourceModuleDependency(path:String):Null<String>
		return sourceModuleForDependency(path);

	static function isPlatformDependency(path:String):Bool {
		var root = QualifiedName.first(path);
		return root == "haxe" || root == "sys" || root == "hl" || root == "Array" || root == "String" || root == "Math" || root == "Reflect"
			|| root == "Std" || root == "StringTools" || root == "Type" || root == "Dynamic" || root == "Any" || root == "Int" || root == "Float"
			|| root == "Bool" || root == "Void" || root == "UInt" || root == "Int8" || root == "UInt8" || root == "Int16" || root == "UInt16"
			|| root == "Int32" || root == "UInt32" || root == "Int64" || root == "Float32" || root == "Float64";
	}

	static function mergeChanges(target:Map<String, Bool>, source:Map<String, Bool>):Void
		for (name in source.keys())
			target.set(name, true);
}
