package compiler.types.typing;

import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.StaticExtensionTable.StaticExtensionOwner;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Monomorphs;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;

/** A static function found as an extension of a value: `key` is its canonical name, `owner` what declares it. */
typedef StaticExtension = {
	final owner:StaticExtensionOwner;
	final key:String;
	final fn:AstFunction;
}

/**
 * Haxe's static extensions (`using pack.Tools;`, `@:using(pack.Tools)`): `value.name(arguments)`, where the value's type has no
 * member `name`, calls a static function `name` whose first argument accepts the value, as `Tools.name(value, arguments)`.
 *
 * The order is Haxe 4.3.7's (`type_field` in `typing/fields.ml`): the value's own members first (the caller tries them, and asks
 * here only once none is found), then the `@:using` extensions of the value's type (a class's own, then its base class's and
 * interfaces'), then the `using` extensions of the module whose code makes the call, its last `using` first. Within each owner a
 * function is passed over when it is not static, is marked `@:noUsing`, may not be reached from the calling code, or takes no
 * argument whose type accepts the value, and the next owner is tried.
 *
 * A value of an unfixed type takes no extension, as in Haxe (where it could fix the type as a side effect). A `Dynamic` value
 * takes only a function whose first argument is `Dynamic`. Haxe's global extensions (`haxe.EnumTools`) are not modelled:
 * Haxeon gives an enum value's `getIndex()` itself.
 */
class StaticExtensions {
	final session:TypingSession;
	final genericInstantiation:GenericInstantiation;

	public function new(session:TypingSession, genericInstantiation:GenericInstantiation) {
		this.session = session;
		this.genericInstantiation = genericInstantiation;
	}

	/** The extension `name` of a value of `receiver`, for a call at `span`, or null when none applies. */
	public function find(receiver:CompilerType, name:String, span:SourceSpan):Null<StaticExtension> {
		receiver = Monomorphs.follow(receiver);
		if (Monomorphs.isUnbound(receiver))
			return null;
		var seen:Map<String, Bool> = [];
		for (typeName in typeNames(receiver))
			for (owner in session.staticExtensions.ofType(typeName)) {
				var found = applicable(owner, receiver, name, span, seen);
				if (found != null)
					return found;
			}
		for (owner in session.staticExtensions.ofModule(span.file.path)) {
			var found = applicable(owner, receiver, name, span, seen);
			if (found != null)
				return found;
		}
		return null;
	}

	/**
	 * The types whose `@:using` applies to a value of `type`, in Haxe's order: the type itself, then for a class its base classes
	 * and interfaces, each after its own (Haxe appends a base's and an interface's list to the class's).
	 */
	function typeNames(type:CompilerType):Array<String> {
		var names:Array<String> = [];
		switch type {
			case TInstance(_, name, _), TAbstract(name, _, _): addTypeName(name, names);
			case TNullable(element): return typeNames(element);
			default:
		}
		return names;
	}

	function addTypeName(name:String, names:Array<String>):Void {
		if (names.indexOf(name) >= 0)
			return;
		names.push(name);
		var classDecl = session.classDecls.get(name);
		if (classDecl != null) {
			if (classDecl.base != null)
				addSupertype(classDecl.base, names);
			for (implemented in classDecl.interfaces)
				addSupertype(implemented, names);
			return;
		}
		var interfaceDecl = session.interfaceDecls.get(name);
		if (interfaceDecl != null)
			for (base in interfaceDecl.bases)
				addSupertype(base, names);
	}

	function addSupertype(type:AstType, names:Array<String>):Void
		switch type {
			case NamedType(name), AppliedType(name, _): addTypeName(name, names);
			default:
		}

	function applicable(owner:StaticExtensionOwner, receiver:CompilerType, name:String, span:SourceSpan,
			seen:Map<String, Bool>):Null<StaticExtension> {
		var key = owner.name + "." + name, seenKey = kindName(owner.kind) + " " + key;
		if (seen.exists(seenKey))
			return null;
		seen.set(seenKey, true);
		var fn = session.signatures.get(key);
		if (fn == null || fn.arguments.length == 0 || !isStatic(owner, key, fn) || hasMetadata(fn, "noUsing")
			|| hasMetadata(fn, "impl"))
			return null;
		if (owner.kind != ModuleFunctions && !MemberAccess.mayReachMethod(session, owner.name, name, span))
			return null;
		return accepts(fn, receiver, span) ? {owner: owner, key: key, fn: fn} : null;
	}

	function isStatic(owner:StaticExtensionOwner, key:String, fn:AstFunction):Bool {
		var info = session.methodInfo.get(key);
		return switch owner.kind {
			case ClassStatics: info != null && info.isStatic && info.owner == owner.name;
			case AbstractStatics: fn.isStatic && fn.name != "new";
			// A module-level function has no method info; a static of a class named like the module, which would share the key,
			// has.
			case ModuleFunctions: info == null;
		};
	}

	/**
	 * Whether `fn`'s first argument takes a value of `receiver`, as Haxe unifies the two (`unify_static_extension`): an implicit
	 * conversion of an abstract counts, a `Dynamic` value only meets `Dynamic`. A generic function's type parameters are inferred
	 * from the value first, as the call infers them.
	 */
	function accepts(fn:AstFunction, receiver:CompilerType, span:SourceSpan):Bool {
		var parameters = BodyTyper.functionTypeParameters(fn),
			expected:CompilerType;
		if (parameters.length == 0)
			expected = session.declarations.types.argumentTypes(fn, [])[0];
		else {
			var substitutions:Map<String, CompilerType> = [];
			try
				genericInstantiation.inferArgumentTypeParameters(fn, 0, fn.arguments[0], receiver, parameters,
					substitutions, span)
			catch (_:CompileError)
				return false;
			expected = genericInstantiation.expectedArgumentType(fn, 0, fn.arguments[0], substitutions);
		}
		expected = Monomorphs.follow(expected);
		if (isDynamic(receiver))
			return isDynamic(expected);
		if (isDynamic(expected) || containsTypeParameter(expected))
			return true;
		return session.relations.isAssignable(receiver, expected)
			|| session.declarations.conversions.allows(receiver, expected) || widensToFloat(receiver, expected);
	}

	/** Haxe unifies an Int with a Float (`var f:Float = 1`), nullable or not. */
	static function widensToFloat(receiver:CompilerType, expected:CompilerType):Bool
		return switch [receiver, expected] {
			case [TInt, TFloat | TNullable(TFloat)], [TNullable(TInt), TNullable(TFloat)]: true;
			default: false;
		};

	static function kindName(kind:compiler.semantic.StaticExtensionTable.StaticExtensionOwnerKind):String
		return switch kind {
			case ClassStatics: "class";
			case AbstractStatics: "abstract";
			case ModuleFunctions: "module";
		};

	static function isDynamic(type:CompilerType):Bool
		return switch type {
			case TDynamic: true;
			default: false;
		};

	/** A type parameter the receiver left unbound: what the call's other arguments fix, which the call itself checks. */
	static function containsTypeParameter(type:CompilerType):Bool
		return switch type {
			case TTypeParameter(_, _): true;
			case TNullable(element), TArray(element), TIterator(element): containsTypeParameter(element);
			case TMap(key, value): containsTypeParameter(key) || containsTypeParameter(value);
			case TInstance(_, _, arguments), TAbstract(_, arguments, _):
				for (argument in arguments)
					if (containsTypeParameter(argument))
						return true;
				false;
			default: false;
		};

	static function hasMetadata(fn:AstFunction, name:String):Bool {
		if (fn.metadata != null)
			for (entry in fn.metadata)
				if (entry.name == name)
					return true;
		return false;
	}
}
