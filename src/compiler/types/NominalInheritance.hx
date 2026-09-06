package compiler.types;

import compiler.types.Type.CompilerType;

/** Resolves instantiated class and interface inheritance through one canonical traversal. */
class NominalInheritance {
	final declarations:DeclarationIndex;

	public function new(declarations:DeclarationIndex)
		this.declarations = declarations;

	public function substitutions(type:CompilerType):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		switch type {
			case TInstance(Class, name, arguments) if (declarations.classes.exists(name)):
				bind(declarations.classes.get(name).typeParameters, arguments, result);
			case TInstance(Interface, name, arguments) if (declarations.interfaces.exists(name)):
				bind(declarations.interfaces.get(name).typeParameters, arguments, result);
			default:
		}
		return result;
	}

	public function parents(type:CompilerType):Array<CompilerType> {
		var result:Array<CompilerType> = [],
			substitutions = substitutions(type);
		switch type {
			case TInstance(Class, name, _) if (declarations.classes.exists(name)):
				var decl = declarations.classes.get(name);
				var base = decl.base;
				if (base != null)
					result.push(declarations.resolve(base, decl.span, substitutions));
				for (implemented in decl.interfaces)
					result.push(declarations.resolve(implemented, decl.span, substitutions));
			case TInstance(Interface, name, _) if (declarations.interfaces.exists(name)):
				var decl = declarations.interfaces.get(name);
				for (base in decl.bases)
					result.push(declarations.resolve(base, decl.span, substitutions));
			default:
		}
		return result;
	}

	public function project(type:CompilerType, target:String):Null<CompilerType> {
		var typeName = name(type);
		if (typeName != null && typeName == target)
			return type;
		for (parent in parents(type)) {
			var projected = project(parent, target);
			if (projected != null)
				return projected;
		}
		return null;
	}

	public function reaches(actual:CompilerType, expected:CompilerType):Bool {
		if (TypeRelations.equals(actual, expected))
			return true;
		for (parent in parents(actual))
			if (reaches(parent, expected))
				return true;
		return false;
	}

	public function inheritedInterfaces(type:CompilerType):Array<CompilerType> {
		var result:Array<CompilerType> = [];
		collectInterfaces(type, result);
		return result;
	}

	function collectInterfaces(type:CompilerType, result:Array<CompilerType>):Void {
		switch type {
			case TInstance(Interface, _, _):
				result.push(type);
			default:
		}
		for (parent in parents(type))
			collectInterfaces(parent, result);
	}

	public static function name(type:CompilerType):Null<String>
		return switch type {
			case TInstance(_, name, _): name;
			default: null;
		};

	static function bind(parameters:Array<String>, arguments:Array<CompilerType>, result:Map<String, CompilerType>):Void {
		if (parameters.length != arguments.length)
			throw "Nominal type argument arity mismatch";
		for (index in 0...arguments.length)
			result.set(parameters[index], arguments[index]);
	}
}
