package compiler.semantic;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.modules.ModuleState;
import compiler.syntax.Ast;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.AstFunctions;

/** A type name as a module's source spells it, and the canonical name it declares. */
typedef SourceAlias = {
	final sourceName:String;
	final declarationName:String;
}

/** A module-level variable: its path as a module member, where it is stored, and how other modules name it. */
private typedef ModuleField = {
	final path:String;
	final storage:String;
	final isInline:Bool;

	/** Whether the module's own class declares a static of the same name, which the variable then is through the class. */
	final typeStatic:Bool;
}

/**
 * What one module's parse gives the names every module sees (`ProgramNames`): the type names it declares, its enums' cases, its
 * module-level members, its inferred declarations, its classes' `@:discoverMethods` prefixes and its `using`s. Made from the
 * parse whenever needed (`ModuleNames.parts`); only a digest of it is kept.
 */
class ModuleNameParts {
	public final aliases:Array<SourceAlias> = [];
	public final enumCases:Array<{type:String, cases:Array<String>}> = [];

	/** The canonical names of the declarations whose type is inferred from their own body or initializer. */
	public final inferred:Array<String> = [];

	/** The class statics declared inline, by path: pattern constants. */
	public final inlineStatics:Array<String> = [];

	/** The module's functions and variables by their paths as module members. */
	public final members:Array<String> = [];

	final fields:Array<ModuleField> = [];
	final discovery:Array<{type:String, prefixes:Array<String>}> = [];

	/** The module's `using`s and its types' `@:using` paths (`StaticExtensionTable.usingsKey`). */
	final usings:String;

	public function new(moduleName:String, ast:AstProgram, entryModule:String) {
		var packageName = ast.packageName;
		for (declaration in ast.aliases)
			addAlias(moduleName, declaration.name, packageName);
		for (declaration in ast.enums) {
			addAlias(moduleName, declaration.name, packageName);
			enumCases.push({
				type: ModuleCanonicalizer.qualifiedTypeName(packageName, declaration.name),
				cases: [for (enumCase in declaration.cases) enumCase.name]
			});
		}
		for (declaration in ast.abstracts) {
			addAlias(moduleName, declaration.name, packageName);
			if (declaration.values != null)
				enumCases.push({
					type: ModuleCanonicalizer.qualifiedTypeName(packageName, declaration.name),
					cases: [for (value in declaration.values) value.name]
				});
		}
		for (declaration in ast.interfaces)
			addAlias(moduleName, declaration.name, packageName);
		for (declaration in ast.classes)
			addAlias(moduleName, declaration.name, packageName);
		for (fn in ast.functions)
			if (AstFunctions.leavesSignatureToInference(fn))
				inferred.push(moduleName == entryModule && fn.name == "main" ? "main" : moduleName + "." + fn.name);
		for (classDecl in ast.classes) {
			var className = ModuleCanonicalizer.qualifiedTypeName(packageName, classDecl.name);
			for (field in classDecl.fields) {
				if (field.type == null)
					inferred.push(className + "." + field.name);
				if (field.isStatic && field.isInline)
					inlineStatics.push(className + "." + field.name);
			}
			for (method in classDecl.methods)
				if (AstFunctions.leavesSignatureToInference(method))
					inferred.push(className + "." + method.name);
			var prefixes = declaredDiscoveryPrefixes(classDecl);
			if (prefixes != null)
				discovery.push({type: className, prefixes: prefixes});
		}
		for (abstractDecl in ast.abstracts) {
			var abstractName = ModuleCanonicalizer.qualifiedTypeName(packageName, abstractDecl.name);
			for (method in abstractDecl.methods)
				if (AstFunctions.leavesSignatureToInference(method))
					inferred.push(abstractName + "." + method.name);
		}
		for (fn in ast.functions)
			members.push(moduleName + "." + fn.name);
		if (ast.fields != null) {
			var ownClass = null;
			for (decl in ast.classes)
				if (ModuleCanonicalizer.qualifiedTypeName(packageName, decl.name) == moduleName)
					ownClass = decl;
			for (field in ast.fields) {
				var path = moduleName + "." + field.name;
				members.push(path);
				fields.push({
					path: path,
					storage: ModuleFields.storageName(moduleName) + "." + field.name,
					isInline: field.isInline,
					typeStatic: ownClass != null && declaresStatic(ownClass, field.name)
				});
			}
		}
		usings = StaticExtensionTable.usingsKey(ast);
	}

	/** Feeds these names to `digest`, in order. */
	public function feed(digest:compiler.query.Digest):Void {
		digest.string(usings);
		for (list in [inferred, inlineStatics, members]) {
			digest.int(list.length);
			for (name in list)
				digest.string(name);
		}
		digest.int(aliases.length);
		for (alias in aliases)
			digest.string(alias.sourceName).string(alias.declarationName);
		digest.int(enumCases.length);
		for (entry in enumCases) {
			digest.string(entry.type).int(entry.cases.length);
			for (name in entry.cases)
				digest.string(name);
		}
		digest.int(fields.length);
		for (field in fields)
			digest.string(field.path).string(field.storage).bool(field.isInline).bool(field.typeStatic);
		digest.int(discovery.length);
		for (entry in discovery) {
			digest.string(entry.type).int(entry.prefixes.length);
			for (prefix in entry.prefixes)
				digest.string(prefix);
		}
	}

	function addAlias(moduleName:String, declarationName:String, packageName:Null<String>):Void {
		var canonicalName = ModuleCanonicalizer.qualifiedTypeName(packageName, declarationName);
		aliases.push({
			sourceName: ModuleCanonicalizer.sourceDeclarationPath(moduleName, declarationName),
			declarationName: canonicalName
		});
		// Haxe also permits spelling a module's primary declaration as Module.Module.
		// Keep the source spelling distinct from its canonical package-level type name.
		if (compiler.core.QualifiedName.last(moduleName) == declarationName)
			aliases.push({sourceName: moduleName + "." + declarationName, declarationName: canonicalName});
	}

	/** Adds this module's parts to `names`, which is made from the modules in order. */
	public function addTo(names:ProgramNames, moduleName:String):Void {
		var moduleAliases:Array<SourceAlias> = [];
		names.aliasesByModule.set(moduleName, moduleAliases);
		for (alias in aliases) {
			names.sourceTypeAliases.set(alias.sourceName, alias.declarationName);
			moduleAliases.push(alias);
		}
		for (entry in enumCases)
			names.enumCasesByType.set(entry.type, entry.cases);
		for (name in inferred)
			names.inferredDeclarations.set(name, true);
		for (path in inlineStatics)
			names.patternConstants.set(path, true);
		for (path in members)
			names.moduleMembers.set(path, true);
		for (field in fields) {
			names.moduleFieldStorage.set(field.path, field.storage);
			if (field.isInline)
				names.patternConstants.set(field.storage, true);
			if (field.typeStatic)
				names.moduleTypeStatics.set(field.path, true);
		}
		for (entry in discovery)
			names.discoveryPrefixes.set(entry.type, entry.prefixes);
	}

	/** This module's part of the alias universe (`ProgramNames.universe`) that the program-wide maps do not give. */
	public function addUniverse(universe:Array<String>):Void {
		for (path in inlineStatics)
			universe.push("inline " + path);
		for (field in fields) {
			if (field.isInline)
				universe.push("inline " + field.path);
			universe.push("field " + field.path);
			if (field.typeStatic)
				universe.push("static " + field.path);
		}
	}

	static function declaredDiscoveryPrefixes(classDecl:AstClass):Null<Array<String>> {
		for (metadata in classDecl.metadata)
			if (metadata.name == "discoverMethods") {
				if (metadata.arguments.length == 0)
					throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
						"@:discoverMethods requires at least one prefix",
						metadata.span));
				var prefixes:Array<String> = [];
				for (argument in metadata.arguments)
					switch argument {
						case AstExpression.StringLiteral(value, _):
							prefixes.push(value);
						default:
							throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
								"@:discoverMethods prefixes must be string literals", metadata.span));
					}
				return prefixes;
			}
		return null;
	}

	/** Whether class `decl` declares a static field or method `name`. */
	static function declaresStatic(decl:AstClass, name:String):Bool {
		for (field in decl.fields)
			if (field.isStatic && field.name == name)
				return true;
		for (method in decl.methods)
			if (method.isStatic && method.name == name)
				return true;
		return false;
	}
}

/**
 * What one module's parse gives the names every module sees, as a digest of its parts (`ModuleNameParts`), which are made again from
 * the parse when the names are made. Made once per parse of the module (and entry module) and kept in the session's database
 * (`SessionState.moduleNames`); a parse of the same declarations gives the same digest (`same`). What a `using` of the module reads
 * of it is digested apart, the first time it is compared (`sameOffered`).
 */
class ModuleNames {
	final moduleName:String;
	final ast:AstProgram;
	final entryModule:String;

	final first:Int;
	final second:Int;

	var offeredFirst = 0;
	var offeredSecond = 0;
	var offeredKnown = false;

	public function new(moduleName:String, ast:AstProgram, entryModule:String) {
		this.moduleName = moduleName;
		this.ast = ast;
		this.entryModule = entryModule;
		var digest = new compiler.query.Digest();
		parts().feed(digest);
		first = digest.first;
		second = digest.second;
	}

	/** The names, made from the parse. */
	public function parts():ModuleNameParts
		return new ModuleNameParts(moduleName, ast, entryModule);

	/** Whether this was made from the parse `ast` for a program whose entry is `entryModule`. */
	public function madeFrom(ast:AstProgram, entryModule:String):Bool
		return this.ast == ast && this.entryModule == entryModule;

	/** Whether two modules give the same names, whatever parses they come from. */
	public static function same(left:ModuleNames, right:ModuleNames):Bool
		return left == right || left.first == right.first && left.second == right.second;

	/** Whether a `using` reads the same of the two modules: their declarations and static functions as written. */
	public static function sameOffered(left:ModuleNames, right:ModuleNames):Bool {
		left.digestOffered();
		right.digestOffered();
		return left.offeredFirst == right.offeredFirst && left.offeredSecond == right.offeredSecond;
	}

	function digestOffered():Void
		if (!offeredKnown) {
			var digest = new compiler.query.Digest().string(StaticExtensionTable.offeredKey(moduleName, ast));
			offeredFirst = digest.first;
			offeredSecond = digest.second;
			offeredKnown = true;
		}
}

/**
 * The names every module of a program sees, made from each module's `ModuleNames` in the program's order: the type names by
 * source spelling, by module and by package, the enums' cases, the module-level members, the pattern constants, the inferred
 * declarations, the `@:discoverMethods` prefixes and the static extensions. Kept in the session's database
 * (`SessionState.programNames`) and made again only when a module's names change: a build whose modules give the same names (a body
 * edit, a no-op) takes the kept one.
 *
 * The alias universe is every name a canonicalization can resolve differently; a module canonicalized against another one is
 * canonicalized again (`SessionState.aliasUniverseRevision`, `ModuleState.canonicalAliasRevision`).
 */
class ProgramNames {
	public final sourceTypeAliases:Map<String, String>;
	public final aliasesByModule:Map<String, Array<SourceAlias>>;
	public final enumCasesByType:Map<String, Array<String>>;
	public final inferredDeclarations:Map<String, Bool>;
	public final patternConstants:Map<String, Bool>;

	/** Where each module-level variable is stored (`ModuleFields`), by its path as a module member. */
	public final moduleFieldStorage:Map<String, String>;

	/** The module-level variables that are also a static of their module's own class. */
	public final moduleTypeStatics:Map<String, Bool>;

	public final moduleMembers:Map<String, Bool>;

	/** The `@:discoverMethods` prefixes the classes declare, by class; a subclass takes its base's as the build meets it. */
	public final discoveryPrefixes:Map<String, Array<String>>;

	/** Where each module's `using` and each type's `@:using` find static extensions. */
	public final staticExtensions:StaticExtensionTable;

	/** The alias universe: every name a canonicalization can resolve differently, sorted and joined. */
	public final universe:String;


	/** What this was made from: the program's modules, in order, and their names. */
	final moduleOrder:Array<String>;

	final contributions:Array<ModuleNames>;

	/**
	 * The names of the modules `moduleOrder` (each module's `contributions` at the same place), whose states `states` holds; or,
	 * given `same`, made from modules that give the same names (`madeFrom`), `same`'s tables made from these contributions, so that
	 * the parses `same` was made from are not kept.
	 */
	public function new(moduleOrder:Array<String>, contributions:Array<ModuleNames>, states:Map<String, ModuleState>,
			?same:ProgramNames) {
		this.moduleOrder = moduleOrder;
		this.contributions = contributions;
		if (same != null) {
			sourceTypeAliases = same.sourceTypeAliases;
			aliasesByModule = same.aliasesByModule;
			enumCasesByType = same.enumCasesByType;
			inferredDeclarations = same.inferredDeclarations;
			patternConstants = same.patternConstants;
			moduleFieldStorage = same.moduleFieldStorage;
			moduleTypeStatics = same.moduleTypeStatics;
			moduleMembers = same.moduleMembers;
			discoveryPrefixes = same.discoveryPrefixes;
			universe = same.universe;
			staticExtensions = same.staticExtensions;
			return;
		}
		sourceTypeAliases = [];
		aliasesByModule = [];
		enumCasesByType = [];
		inferredDeclarations = [];
		patternConstants = [];
		moduleFieldStorage = [];
		moduleTypeStatics = [];
		moduleMembers = [];
		discoveryPrefixes = [];
		var parts = [for (contribution in contributions) contribution.parts()];
		for (index in 0...moduleOrder.length)
			parts[index].addTo(this, moduleOrder[index]);
		var names = [
			for (sourceName => declarationName in sourceTypeAliases)
				sourceName + "=" + declarationName
		];
		for (typeName => caseNames in enumCasesByType)
			for (caseName in caseNames) {
				names.push(typeName + "#" + caseName);
				patternConstants.set(typeName + "." + caseName, true);
			}
		for (part in parts)
			part.addUniverse(names);
		names.sort(Reflect.compare);
		universe = names.join(";");
		staticExtensions = StaticExtensionTable.build(states, moduleOrder);
	}

	/**
	 * Whether these modules, in this order, give the names this was made from: each module's part is the same object, or one made
	 * from another parse with the same names (a body edit), and of a module a `using` resolves to, the same statics.
	 */
	public function madeFrom(moduleOrder:Array<String>, contributions:Array<ModuleNames>):Bool {
		if (moduleOrder.length != this.moduleOrder.length)
			return false;
		var resolved = staticExtensions.resolvedModules;
		for (index in 0...moduleOrder.length) {
			var name = moduleOrder[index], now = contributions[index], before = this.contributions[index];
			if (name != this.moduleOrder[index])
				return false;
			if (now != before
				&& (!ModuleNames.same(now, before) || resolved.exists(name) && !ModuleNames.sameOffered(now, before)))
				return false;
		}
		return true;
	}

	/** Whether this was made from these very contributions, not only ones that give the same names. */
	public function madeFromThese(contributions:Array<ModuleNames>):Bool {
		for (index in 0...contributions.length)
			if (contributions[index] != this.contributions[index])
				return false;
		return true;
	}

	/** `--check-reuse`: the first difference between these names and `fresh`, made from the same modules afresh, or null. */
	public function difference(fresh:ProgramNames):Null<String> {
		if (universe != fresh.universe)
			return "the alias universe";
		for (pair in [
			{name: "source type aliases", left: sourceTypeAliases, right: fresh.sourceTypeAliases},
			{name: "module field storage", left: moduleFieldStorage, right: fresh.moduleFieldStorage}
		])
			if (!sameMaps(pair.left, pair.right, (a, b) -> a == b))
				return "the " + pair.name;
		for (pair in [
			{name: "inferred declarations", left: inferredDeclarations, right: fresh.inferredDeclarations},
			{name: "pattern constants", left: patternConstants, right: fresh.patternConstants},
			{name: "module type statics", left: moduleTypeStatics, right: fresh.moduleTypeStatics},
			{name: "module members", left: moduleMembers, right: fresh.moduleMembers}
		])
			if (!sameMaps(pair.left, pair.right, (a, b) -> a == b))
				return "the " + pair.name;
		if (!sameMaps(enumCasesByType, fresh.enumCasesByType, sameList)
			|| !sameMaps(discoveryPrefixes, fresh.discoveryPrefixes, sameList))
			return "the enum cases or discovery prefixes";
		if (!sameMaps(aliasesByModule, fresh.aliasesByModule, (a, b) -> sameList([
			for (alias in a)
				alias.sourceName + "=" + alias.declarationName
		], [for (alias in b) alias.sourceName + "=" + alias.declarationName])))
			return "the aliases by module";
		if (staticExtensions.digest(moduleOrder) != fresh.staticExtensions.digest(moduleOrder))
			return "the static extensions";
		return null;
	}

	static function sameMaps<T>(left:Map<String, T>, right:Map<String, T>, same:(T, T) -> Bool):Bool {
		var count = 0;
		for (key => value in left) {
			count++;
			if (!right.exists(key) || !same(value, right.get(key)))
				return false;
		}
		for (_ in right.keys())
			count--;
		return count == 0;
	}

	static function sameList(left:Array<String>, right:Array<String>):Bool
		return left.join("\n") == right.join("\n");
}

/**
 * What canonicalizing a module reads of `ProgramNames` besides its maps, indexed for one build: made the first time a build
 * canonicalizes a module again, which a no-op build does not.
 */
class ProgramNameIndex {
	/** Type names that every module sees: dotted ones ("pkg.Type") and plain ones ("Type"), attached to each module's table. */
	public final dottedSourceAliases:Map<String, String> = [];

	public final plainSourceAliases:Map<String, String> = [];

	final aliasesByPackage:Map<String, Array<{source:String, declaration:String}>>;
	final visibleByPackage:Map<String, Map<String, String>> = [];

	public function new(names:ProgramNames) {
		var sourceTypeAliases = names.sourceTypeAliases;
		aliasesByPackage = indexAliasesByPackage(sourceTypeAliases);
		for (sourceName => declarationName in sourceTypeAliases)
			if (sourceName.indexOf(".") >= 0)
				dottedSourceAliases.set(sourceName, declarationName);
			else
				plainSourceAliases.set(sourceName, declarationName);
	}

	/**
	 * The type names visible from package `packageName` without an import: its own types and its enclosing packages', each by its
	 * name relative to the package and by its simple name, the nearest package first.
	 */
	public function visibleTypes(packageName:String):Map<String, String> {
		var known = visibleByPackage.get(packageName);
		if (known != null)
			return known;
		var result:Map<String, String> = [],
			visiblePackage:Null<String> = packageName;
		while (visiblePackage != null) {
			var currentPackage:String = visiblePackage,
				prefixLength = currentPackage.length == 0 ? 0 : currentPackage.length + 1,
				group = aliasesByPackage.get(currentPackage);
			if (group != null)
				for (alias in group) {
					var relativeSourceName = alias.source.substring(prefixLength, alias.source.length),
						simpleName = alias.declaration.substring(prefixLength, alias.declaration.length);
					if (!result.exists(relativeSourceName))
						result.set(relativeSourceName, alias.declaration);
					if (simpleName.indexOf(".") < 0 && !result.exists(simpleName))
						result.set(simpleName, alias.declaration);
				}
			var separator = currentPackage.lastIndexOf(".");
			visiblePackage = separator < 0 ? null : currentPackage.substring(0, separator);
		}
		visibleByPackage.set(packageName, result);
		return result;
	}

	/**
	 * The source aliases grouped by the packages they are visible from: an alias is listed under every package `P` that both its source
	 * name and its declaration name start with (`P.`), and under the root package (""). Each group keeps the aliases in the order of
	 * `sourceTypeAliases`, so what a package sees is built exactly as walking all of them would build it.
	 */
	static function indexAliasesByPackage(sourceTypeAliases:Map<String, String>):Map<String, Array<{
		source:String,
		declaration:String
	}>> {
		var index:Map<String, Array<{source:String, declaration:String}>> = [];
		function add(packageName:String, source:String, declaration:String):Void {
			var group = index.get(packageName);
			if (group == null) {
				group = [];
				index.set(packageName, group);
			}
			group.push({source: source, declaration: declaration});
		}
		for (sourceName => declarationName in sourceTypeAliases) {
			add("", sourceName, declarationName);
			var dot = sourceName.indexOf(".");
			while (dot >= 0) {
				if (declarationName.length > dot
					&& declarationName.charCodeAt(dot) == ".".code
					&& StringTools.startsWith(declarationName, sourceName.substr(0, dot)))
					add(sourceName.substr(0, dot), sourceName, declarationName);
				dot = sourceName.indexOf(".", dot + 1);
			}
		}
		return index;
	}

}
