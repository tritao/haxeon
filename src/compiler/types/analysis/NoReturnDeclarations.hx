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

	/**
	 * The first method that overrides or implements a `@:noReturn` method without being declared `@:noReturn` itself, as
	 * the method and the declaring base's key. The declarations looked at are the class's ancestors and every interface it
	 * or an ancestor implements, with the interfaces those extend.
	 */
	public static function undeclaredOverride(classes:Map<String, AstClass>,
			interfaces:Map<String, AstInterface>):Null<{
				method:AstFunction,
				base:String
			}> {
		for (className => classDecl in classes) {
			var bases = declaringBases(classes, interfaces, classDecl);
			if (bases.length == 0)
				continue;
			for (method in classDecl.methods) {
				if (method.isStatic || method.name == "new" || has(method))
					continue;
				var base = declaredIn(bases, method.name);
				if (base != null)
					return {method: method, base: base};
			}
		}
		return null;
	}

	/** The `@:noReturn` methods of what `classDecl` inherits from or implements, as their keys by method name. */
	static function declaringBases(classes:Map<String, AstClass>, interfaces:Map<String, AstInterface>,
			classDecl:AstClass):Array<{
				name:String,
				key:String
			}> {
		var found:Array<{name:String, key:String}> = [],
			seen:Map<String, Bool> = [];
		function visitInterface(name:String):Void {
			if (seen.exists(name))
				return;
			seen.set(name, true);
			var declaration = interfaces.get(name);
			if (declaration == null)
				return;
			for (method in declaration.methods)
				if (has(method))
					found.push({name: method.name, key: name + "." + method.name});
			for (base in declaration.bases) {
				var baseName = typeName(base);
				if (baseName != null)
					visitInterface(baseName);
			}
		}
		var current:Null<AstClass> = classDecl, first = true;
		while (current != null) {
			if (!first) {
				var currentName = current.name;
				for (method in current.methods)
					if (!method.isStatic && has(method))
						found.push({name: method.name, key: currentName + "." + method.name});
			}
			for (implemented in current.interfaces) {
				var implementedName = typeName(implemented);
				if (implementedName != null)
					visitInterface(implementedName);
			}
			first = false;
			var base = current.base,
				baseName = base == null ? null : typeName(base);
			if (baseName == null || seen.exists("class:" + baseName))
				break;
			seen.set("class:" + baseName, true);
			current = classes.get(baseName);
		}
		return found;
	}

	static function declaredIn(bases:Array<{name:String, key:String}>, method:String):Null<String> {
		for (base in bases)
			if (base.name == method)
				return base.key;
		return null;
	}

	static function typeName(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};
}
