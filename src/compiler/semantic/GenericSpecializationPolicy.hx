package compiler.semantic;

import compiler.ffi.NativeLayout;
import compiler.runtime.RuntimeShape.RuntimeShapes;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;

typedef SpecializationDecision = {
	final representation:CompilerType;
	final policy:String;
}

/** Chooses stable concrete or shape-shared representations for generic bodies. */
class GenericSpecializationPolicy {
	/** Select an owner parameter's representation for a value-specialized class. */
	public static function decideOwner(owner:AstClass, parameter:String, semantic:CompilerType,
			requiresLayoutSpecialization:CompilerType->Bool):SpecializationDecision {
		if (owner.typeConstraints != null)
			for (constraint in owner.typeConstraints)
				if (constraint.parameter == parameter)
					return {representation: semantic, policy: "constrained"};
		if (requiresLayoutSpecialization(semantic))
			return {representation: semantic, policy: "layout"};
		if (owner.base != null && containsNested(owner.base, parameter, false))
			return {representation: semantic, policy: "layout"};
		for (interfaceType in owner.interfaces)
			if (containsNested(interfaceType, parameter, false))
				return {representation: semantic, policy: "layout"};
		for (field in owner.fields)
			if (!field.isStatic && field.type != null && containsNested(field.type, parameter, false))
				return {representation: semantic, policy: "layout"};
		for (method in owner.methods) {
			if (method.isStatic || method.typeParameters != null && method.typeParameters.indexOf(parameter) >= 0)
				continue;
			for (argument in method.arguments)
				if (containsNested(argument.type, parameter, false))
					return {representation: semantic, policy: "layout"};
			if (containsNested(method.result, parameter, false))
				return {representation: semantic, policy: "layout"};
		}
		return {representation: RuntimeShapes.representative(semantic), policy: "shape"};
	}

	public static function decide(fn:AstFunction, parameter:String, semantic:CompilerType,
			requiresLayoutSpecialization:Null<CompilerType->Bool> = null):SpecializationDecision {
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints)
				if (constraint.parameter == parameter)
					return {representation: semantic, policy: "constrained"};
		// Native scalars and records have no runtime shape of their own: a shared body would read
		// `RawPtr<T>` or `sizeof<T>()` with another type's size, so they specialize exactly.
		if (requiresLayoutSpecialization == null ? NativeLayout.containsNativeLayoutType(semantic) : requiresLayoutSpecialization(semantic))
			return {representation: semantic, policy: "layout"};
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
