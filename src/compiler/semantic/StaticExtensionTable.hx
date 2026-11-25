package compiler.semantic;

import compiler.syntax.Ast.AstVisibility;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.modules.ModuleState;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstMetadata;
import compiler.syntax.Ast.AstProgram;

/** What holds the static functions a `using` makes extensions: a class, an abstract, or a module's own functions. */
enum StaticExtensionOwnerKind {
	ClassStatics;
	TypeStatics;
	ModuleFunctions;
}

/** One holder of extensions: `name` is the qualified class or abstract, or the module for its module-level functions. */
typedef StaticExtensionOwner = {
	final name:String;
	final kind:StaticExtensionOwnerKind;
}

/** A declaration of a module that `using` or `@:using` reads: its name, visibility, metadata, position and static functions. */
private typedef ModuleDeclaration = {
	final name:String;
	final isPrivate:Bool;
	final metadata:Array<AstMetadata>;
	final start:Int;
	final kind:Null<StaticExtensionOwnerKind>;
	final statics:Array<AstFunction>;
	final ?isAlias:Bool;
}

/** An owner a `using` resolved to, with the key of the static functions it declares (`keyOfModule`). */
private typedef ResolvedOwner = {
	final owner:StaticExtensionOwner;
	final key:String;
}

/**
 * Where each module's `using` and each type's `@:using` find static extensions, in the order Haxe 4.3.7 tries them
 * (`typing/fields.ml`, `context/display/importHandling.ml`):
 *
 * - A module's list starts with its last `using`: each `using` is put in front of the ones before it. Within one `using` of a
 *   module that declares several types, the last type comes first, and the module's own functions come after all of them.
 *   Private types are left out, as Haxe's `handle_using` leaves them out.
 * - A type's `@:using(A, B)` list is kept the same way, B before A. A class's base class and interfaces add theirs after its own;
 *   the typer follows them (`StaticExtensions`), so this table holds a type's own list only.
 *
 * Modules are keyed by their source file's path, which is what a call's span names: the typer finds the list of the module whose
 * code it types from the call itself, also inside a generic function's specialization, whose code is its declaring module's.
 */
class StaticExtensionTable {
	/** Each module's extensions, by the path of its source file. */
	final modules:Map<String, Array<StaticExtensionOwner>>;

	/** The typedefs that declare `@:using`, by qualified name, sorted: their extensions apply to values of the types they name. */
	public final aliases:Array<String>;

	/** Each type's own `@:using` extensions, by its qualified name. */
	final types:Map<String, Array<StaticExtensionOwner>>;

	public function new(modules:Map<String, Array<StaticExtensionOwner>>,
			types:Map<String, Array<StaticExtensionOwner>>, moduleKeys:Map<String, String>, typeKey:String,
			?aliases:Array<String>) {
		this.aliases = aliases == null ? [] : aliases;
		this.modules = modules;
		this.types = types;
		this.moduleKeys = moduleKeys;
		this.typeKey = typeKey;
	}

	public static function empty():StaticExtensionTable
		return new StaticExtensionTable([], [], [], "");

	/** The extensions of the module whose source file is `path`, first tried first. */
	public function ofModule(path:String):Array<StaticExtensionOwner> {
		var owners = modules.get(path);
		return owners == null ? [] : owners;
	}

	/** The extensions `@:using` declares on the type `name` itself, first tried first. */
	public function ofType(name:String):Array<StaticExtensionOwner> {
		var owners = types.get(name);
		return owners == null ? [] : owners;
	}

	/**
	 * A key of everything a call in module `name` may resolve to through extensions: its `using` list, every type's `@:using`
	 * list, and the static functions each of those owners declares, with their signatures as written. When it changes, the
	 * module's bodies are typed again (SemanticAssembly): a `using` added or removed, or a static function an owner gains, can
	 * change what a call that is still written the same resolves to.
	 */
	public function keyOfModule(name:String):String {
		var key = moduleKeys.get(name);
		return key == null ? typeKey : key + "|" + typeKey;
	}

	/** Each module's part of `keyOfModule`, by module name. */
	final moduleKeys:Map<String, String>;

	/** The part of every module's key that the types' `@:using` lists give. */
	final typeKey:String;

	/**
	 * Resolves the `using` declarations and `@:using` metadata of the modules `names`. A path that names no module or type of
	 * the program is an error at the `using`, as in Haxe.
	 */
	public static function build(states:Map<String, ModuleState>, names:Array<String>):StaticExtensionTable {
		var modules:Map<String, Array<StaticExtensionOwner>> = [],
			types:Map<String, Array<StaticExtensionOwner>> = [],
			moduleKeys:Map<String, String> = [],
			typeKeys:Array<String> = [],
			aliases:Array<String> = [];
		for (name in names) {
			var state = states.get(name);
			if (state == null || state.ast == null)
				continue;
			var ast = state.parsedAst();
			if (ast.usings != null && ast.usings.length > 0) {
				var owners:Array<ResolvedOwner> = [];
				for (used in ast.usings)
					owners = resolve(states, used.path, ast.packageName, used.span).concat(owners);
				modules.set(state.source.path, [for (owner in owners) owner.owner]);
				moduleKeys.set(name, [for (owner in owners) owner.key].join(";"));
			}
			for (declaration in declarationsOf(ast)) {
				var owners:Array<ResolvedOwner> = [];
				for (entry in declaration.metadata)
					if (entry.name == "using")
						for (argument in entry.arguments) {
							var path = expressionPath(argument);
							if (path == null)
								throw new CompileError(new Diagnostic(DiagnosticCode.LOOKUP_OR_DECLARATION,
									"dot path expected", entry.span));
							owners = resolve(states, path, ast.packageName, entry.span).concat(owners);
						}
				if (owners.length > 0) {
					var typeName = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, declaration.name);
					types.set(typeName, [for (owner in owners) owner.owner]);
					if (declaration.isAlias)
						aliases.push(typeName);
					typeKeys.push(typeName + "=" + [for (owner in owners) owner.key].join(";"));
				}
			}
		}
		typeKeys.sort(Reflect.compare);
		aliases.sort(Reflect.compare);
		return new StaticExtensionTable(modules, types, moduleKeys, typeKeys.join(";"), aliases);
	}

	/**
	 * What `using path` brings, first tried first. As in Haxe, `pack.Module` names a module, and `pack.Module.Type` (a dotted path
	 * whose next-to-last part starts upper case) one type of it. An unqualified path is looked for in the using module's package
	 * first, then at the top level.
	 */
	static function resolve(states:Map<String, ModuleState>, path:String, packageName:Null<String>,
			span:SourceSpan):Array<ResolvedOwner> {
		var parts = path.split("."),
			subType:Null<String> = null,
			modulePath = path;
		if (parts.length >= 2 && isUpperCase(parts[parts.length - 2])) {
			subType = parts.pop();
			modulePath = parts.join(".");
		}
		var module:Null<ModuleState> = null;
		if (packageName != null && modulePath.indexOf(".") < 0)
			module = states.get(packageName + "." + modulePath);
		if (module == null)
			module = states.get(modulePath);
		if (module == null || module.ast == null)
			throw new CompileError(new Diagnostic(DiagnosticCode.MISSING_MODULE, 'Type not found : $path', span));
		var ast = module.parsedAst(), owners:Array<ResolvedOwner> = [];
		for (declaration in declarationsOf(ast))
			if (subType == null ? !declaration.isPrivate : declaration.name == subType) {
				var kind = declaration.kind;
				if (kind != null) {
					var name = ModuleCanonicalizer.qualifiedTypeName(ast.packageName, declaration.name);
					owners.unshift({owner: {name: name, kind: kind}, key: ownerKey(name, declaration.statics, ast)});
				}
			}
		if (subType != null && owners.length == 0 && !declares(ast, subType))
			throw new CompileError(new Diagnostic(DiagnosticCode.MISSING_MODULE,
				'Module $modulePath does not define type $subType', span));
		if (subType == null && ast.functions.length > 0)
			owners.push({
				owner: {name: module.name, kind: ModuleFunctions},
				key: ownerKey(module.name, ast.functions, ast)
			});
		return owners;
	}

	/** The paths the `@:using` metadata of a module's types name, as written. */
	public static function metadataPaths(ast:AstProgram):Array<String> {
		var paths:Array<String> = [];
		for (declaration in declarationsOf(ast))
			for (entry in declaration.metadata)
				if (entry.name == "using")
					for (argument in entry.arguments) {
						var path = expressionPath(argument);
						if (path != null)
							paths.push(path);
					}
		return paths;
	}

	static function ownerKey(name:String, statics:Array<AstFunction>, ast:AstProgram):String
		return name + "{" + [
			for (fn in statics)
				(fn.visibility == AstVisibility.Unwritten ? "" : fn.visibility.modifier() + " ")
				+ SemanticSignature.parsedFunction(fn, ast.aliases)
				+ (fn.metadata == null ? "" : [for (entry in fn.metadata) "@" + entry.name].join(""))
		].join(",") + "}";

	/**
	 * A module's declarations in source order (the parser groups them by kind), each with the kind of extensions it holds and its
	 * static functions: a class's or an abstract's, or none for an enum, enum abstract or interface, whose `@:using` this table
	 * still reads.
	 */
	static function declarationsOf(ast:AstProgram):Array<ModuleDeclaration> {
		var result:Array<ModuleDeclaration> = [];
		for (declaration in ast.classes)
			// The classes ModuleFields and TypeStatics generate (`Mod$fields`, `A$statics`) hold variables, not extensions.
			if (declaration.name.indexOf("$") < 0)
				result.push({
					name: declaration.name,
					isPrivate: declaration.visibility == AstVisibility.Private,
					metadata: declaration.metadata,
					start: declaration.span.start,
					kind: ClassStatics,
					statics: [for (method in declaration.methods) if (method.isStatic) method]
				});
		for (declaration in ast.abstracts)
			result.push({
				name: declaration.name,
				isPrivate: false,
				metadata: declaration.metadata == null ? [] : declaration.metadata,
				start: declaration.span.start,
				kind: TypeStatics,
				statics: [for (method in declaration.methods) if (method.isStatic) method]
			});
		for (declaration in ast.enums)
			result.push({
				name: declaration.name,
				isPrivate: false,
				metadata: declaration.metadata,
				start: declaration.span.start,
				kind: null,
				statics: []
			});
		// A typedef's `@:using` applies to the values of the type it names (`StaticExtensions`).
		for (declaration in ast.aliases)
			result.push({
				name: declaration.name,
				isPrivate: declaration.visibility == AstVisibility.Private,
				metadata: declaration.metadata,
				start: declaration.span.start,
				kind: null,
				statics: [],
				isAlias: true
			});
		for (declaration in ast.interfaces)
			result.push({
				name: declaration.name,
				isPrivate: false,
				metadata: [],
				start: declaration.span.start,
				kind: null,
				statics: []
			});
		result.sort((left, right) -> left.start - right.start);
		return result;
	}

	static function declares(ast:AstProgram, name:String):Bool {
		for (alias in ast.aliases)
			if (alias.name == name)
				return true;
		for (declaration in declarationsOf(ast))
			if (declaration.name == name)
				return true;
		return false;
	}

	static function isUpperCase(part:String):Bool {
		var code = part.charCodeAt(0);
		return code != null && code >= "A".code && code <= "Z".code;
	}

	static function expressionPath(expression:AstExpression):Null<String>
		return switch expression {
			case Variable(name, _): name;
			case Member(object, name, _):
				var prefix = expressionPath(object);
				prefix == null ? null : prefix + "." + name;
			default: null;
		};
}
