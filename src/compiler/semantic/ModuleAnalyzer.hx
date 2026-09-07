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
	final defines:Map<String, String>;
	final sourceLoader:ModuleSourceLoader;

	public function new(modules:Map<String, ModuleState>, types:TypeRegistry, natives:NativeRegistry, compiledOnce:Bool, defines:Map<String, String>,
			sourceLoader:ModuleSourceLoader) {
		this.modules = modules;
		this.types = types;
		this.natives = natives;
		this.compiledOnce = compiledOnce;
		this.defines = defines;
		this.sourceLoader = sourceLoader;
	}

	public function parse(state:ModuleState, entry:String, bodyChanged:Map<String, Bool>, signatureChanged:Map<String, Bool>,
			structuralChanged:Map<String, Bool>):Void {
		if (state.ast != null)
			return;
		try {
			var conditional = ConditionalCompilation.process(state.source, defines);
			state.conditionalDefines = conditional.defines;
			state.tokens = new Lexer(state.source, conditional.text).tokenize();
			state.ast = new Parser(state.tokens).parseProgram();
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
			var alias = QualifiedName.last(importPath);
			if (alias != importPath)
				dependencies.remove(alias);
		}
		for (alias in ast.importAliases.keys())
			dependencies.remove(alias);
		for (dependency in [for (dependency in dependencies.keys()) dependency])
			if (natives.hasChild(dependency))
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
			var prefix = ast.packageName == null ? "" : Std.string(ast.packageName) + ".";
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

	static function isPlatformDependency(path:String):Bool {
		var root = QualifiedName.first(path);
		return root == "haxe" || root == "sys" || root == "hl" || root == "Array" || root == "String" || root == "Math" || root == "Reflect"
			|| root == "Std" || root == "StringTools" || root == "Type";
	}

	static function mergeChanges(target:Map<String, Bool>, source:Map<String, Bool>):Void
		for (name in source.keys())
			target.set(name, true);
}
