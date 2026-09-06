package compiler.semantic;

import compiler.runtime.RuntimeShape.RuntimeShapes;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;

typedef SpecializationDecision = {
	final representation:CompilerType;
	final policy:String;
}

/** Chooses stable concrete or shape-shared representations for generic bodies. */
class GenericSpecializationPolicy {
	public static function decide(fn:AstFunction, parameter:String, semantic:CompilerType):SpecializationDecision {
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints)
				if (constraint.parameter == parameter)
					return {representation: semantic, policy: "constrained"};
		for (argument in fn.arguments)
			if (containsNested(argument.type, parameter, false))
				return {representation: semantic, policy: "layout"};
		if (containsNested(fn.result, parameter, false))
			return {representation: semantic, policy: "layout"};
		return {representation: RuntimeShapes.representative(semantic), policy: "shape"};
	}

	static function containsNested(type:AstType, parameter:String, nested:Bool):Bool
		return switch type {
			case NamedType(name): nested && name == parameter;
			case AppliedType(_, arguments): containsAny(arguments, parameter);
			case ArrayType(element), NullableType(element): containsNested(element, parameter, true);
			case MapType(key, value): containsNested(key, parameter, true) || containsNested(value, parameter, true);
			case FunctionType(arguments, result): containsAny(arguments, parameter) || containsNested(result, parameter, true);
			case AnonymousType(fields):
				var found = false;
				for (field in fields)
					if (containsNested(field.type, parameter, true))
						found = true;
				found;
			default: false;
		};

	static function containsAny(types:Array<AstType>, parameter:String):Bool {
		for (type in types)
			if (containsNested(type, parameter, true))
				return true;
		return false;
	}
}
