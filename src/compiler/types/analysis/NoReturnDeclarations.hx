package compiler.types.analysis;

import compiler.syntax.Ast;

/**
 * The functions declared `@:noReturn`: every path throws or calls another such function, so a call to one never returns and
 * the code after it is unreachable (a null check that calls one narrows what follows). Declared, not inferred, so whether a
 * caller type-checks depends on the callee's signature, never on its body, and Haxe, which ignores the metadata, compiles
 * the same source. The typer checks each declaration against its body, and that every override of a declared method is
 * declared too, so a call through the base method stays a call that never returns.
 */
class NoReturnDeclarations {
	/** The metadata name, as `@:noReturn` is parsed. */
	public static inline final METADATA = "noReturn";

	public static function declared(signatures:Map<String, AstFunction>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (name => fn in signatures)
			if (has(fn))
				result.set(name, true);
		return result;
	}

	public static function has(fn:AstFunction):Bool {
		if (fn.metadata != null)
			for (entry in fn.metadata)
				if (entry.name == METADATA)
					return true;
		return false;
	}

	/** The first override of a `@:noReturn` method that is not declared `@:noReturn` itself, as its method and the base method's key. */
	public static function undeclaredOverride(classes:Map<String, AstClass>):Null<{method:AstFunction, base:String}> {
		for (className => classDecl in classes) {
			if (classDecl.base == null)
				continue;
			for (method in classDecl.methods) {
				if (method.isStatic || method.name == "new" || has(method))
					continue;
				var base = declaringAncestor(classes, classDecl, method.name);
				if (base != null)
					return {method: method, base: base};
			}
		}
		return null;
	}

	/** The nearest ancestor's `@:noReturn` declaration of `name`, as its key. */
	static function declaringAncestor(classes:Map<String, AstClass>, classDecl:AstClass, name:String):Null<String> {
		var seen:Map<String, Bool> = [], current = classDecl;
		while (current.base != null) {
			var baseName = switch current.base {
				case NamedType(baseName), AppliedType(baseName, _): baseName;
				default: null;
			};
			if (baseName == null || seen.exists(baseName))
				return null;
			seen.set(baseName, true);
			var ancestor = classes.get(baseName);
			if (ancestor == null)
				return null;
			for (method in ancestor.methods)
				if (!method.isStatic && method.name == name)
					return has(method) ? baseName + "." + name : null;
			current = ancestor;
		}
		return null;
	}
}
