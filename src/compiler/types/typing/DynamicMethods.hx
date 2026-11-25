package compiler.types.typing;

import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.InterfaceFieldAccessors;
import compiler.semantic.TypeStatics;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstFunction;
import compiler.types.FunctionTypes;
import compiler.types.NominalInheritance;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedField;

/** A dynamic method has a virtual implementation for initial binding and a field for its current value. */
class DynamicMethods {
	public static function declaration(session:TypingSession, owner:String, name:String,
			isStatic:Bool):Null<AstFunction> {
		var method = MemberAccess.methodInfo(session, isStatic ? TypeStatics.displayOwner(owner) : owner, name);
		return method == null || method.isStatic != isStatic || method.isConstructor
			? null : session.signatures.get(method.owner + "." + name);
	}

	public static function isDynamic(session:TypingSession, method:AstFunction, owner:String):Bool {
		if (method.isDynamic == true)
			return true;
		var cls = session.classDecls.get(owner);
		return !method.isStatic && method.isOverride == true && cls != null
			&& inherited(session, cls, compiler.core.QualifiedName.last(method.name));
	}

	public static function inherited(session:TypingSession, cls:AstClass, name:String):Bool {
		var base = cls.base == null ? null : BodyTyper.inheritanceName(cls.base);
		if (base == null)
			return false;
		var info = MemberAccess.methodInfo(session, base, name);
		if (info == null || info.isStatic)
			return false;
		var inherited = session.signatures.get(info.owner + "." + name);
		return inherited != null && isDynamic(session, inherited, info.owner);
	}

	// Every instantiation of a generic dynamic method shares one callback slot.
	public static function eraseParameters(method:AstFunction,
			substitutions:Map<String, CompilerType>):Map<String, CompilerType> {
		var parameters = BodyTyper.functionTypeParameters(method);
		if (parameters.length == 0)
			return substitutions;
		var erased = [for (name => type in substitutions) name => type];
		for (parameter in parameters)
			erased.set(parameter, TDynamic);
		return erased;
	}

	public static function functionType(session:TypingSession, method:AstFunction,
			substitutions:Map<String, CompilerType>):CompilerType {
		var arguments = session.declarations.types.argumentTypes(method, substitutions);
		return TFunction([
			for (index in 0...arguments.length)
				DefaultArguments.dispatchType(method.arguments[index], arguments[index], session.relations)
		], session.declarations.types.resultType(method, substitutions), FunctionTypes.ofArguments(method.arguments));
	}

	public static function field(session:TypingSession, owner:String, method:AstFunction,
			substitutions:Map<String, CompilerType>, ?implementationOwner:String):TypedField {
		substitutions = eraseParameters(method, substitutions);
		var type = functionType(session, method, substitutions),
			key = (implementationOwner ?? owner) + "." + method.name,
			arguments = session.declarations.types.argumentTypes(method, substitutions),
			target = DefaultArguments.hasDispatchEntry(method.arguments, arguments, session.relations)
				? DefaultArguments.dispatchName(key) : key,
			receiver = new TypedExpression(TLocal("this"),
				session.representation.receiverType(owner, substitutions), method.span);
		return {
			name: method.name,
			metadata: method.metadata ?? [],
			type: type,
			initializer: new TypedExpression(method.isExtern == true ? TNullLiteral
				: method.isStatic ? TFunctionRef(target) : TMethodRef(receiver, target, true), type, method.span),
			inlineValue: null,
			isDynamicMethod: true,
			readAccess: null,
			writeAccess: null,
			isStatic: method.isStatic,
			isInline: false,
			isFinal: false,
			span: method.span
		};
	}

	public static function read(session:TypingSession, receiver:TypedExpression, name:String,
			span:SourceSpan):Null<TypedExpression> {
		var field = resolve(session, receiver, name, span);
		if (field == null)
			return null;
		var value = session.representation.boundaryCast(field.storage, field.type, receiver.type);
		return methodValue(session, value, field.method, field.substitutions);
	}

	public static function methodValue(session:TypingSession, value:TypedExpression, method:AstFunction,
			ownerSubstitutions:Map<String, CompilerType>):TypedExpression {
		var parameters = BodyTyper.functionTypeParameters(method);
		if (parameters.length == 0)
			return value;
		var substitutions = [for (name => type in ownerSubstitutions) name => type];
		for (parameter in parameters)
			substitutions.set(parameter,
				session.monomorphs.create('type parameter "$parameter" of a method value', value.span) ?? TDynamic);
		return session.representation.boundaryCast(value, functionType(session, method, substitutions));
	}

	public static function resolve(session:TypingSession, receiver:TypedExpression, name:String,
			span:SourceSpan):Null<{
				storage:TypedExpression,
				type:CompilerType,
				method:AstFunction,
				substitutions:Map<String, CompilerType>,
				?setter:String
			}> {
		var owner = NominalInheritance.name(receiver.type);
		if (owner == null)
			return null;
		var isStatic = receiver.expression.match(TClassRef(_)),
			info = MemberAccess.methodInfo(session, isStatic ? TypeStatics.displayOwner(owner) : owner, name);
		if (info == null || info.isStatic != isStatic || info.isConstructor)
			return null;
		var method = session.signatures.required(info.owner + "." + name);
		if (!isDynamic(session, method, info.owner))
			return null;
		MemberAccess.method(session, info.owner, name, span);
		if (isStatic) {
			var type = functionType(session, method, eraseParameters(method, []));
			return {
				storage: new TypedExpression(TStaticField(staticOwner(session, info.owner), name), type, span),
				type: type,
				method: method,
				substitutions: []
			};
		}
		var semantic:Map<String, CompilerType> = BodyTyper.functionTypeParameters(method).length == 0 ? []
			: session.representation.nominalSubstitutions(session.declarations.inheritance.project(receiver.type,
			info.owner) ?? receiver.type);
		if (session.interfaceDecls.exists(info.owner)) {
			var getter = info.owner + "." + InterfaceFieldAccessors.dynamicAccessorName(name, true),
				setter = info.owner + "." + InterfaceFieldAccessors.dynamicAccessorName(name, false),
				result = session.representation.resolveMethodResult(receiver.type, info.owner,
					session.signatures.required(getter));
			return {
				storage: new TypedExpression(TMethodCall(receiver, getter, []), result.physical, span),
				type: result.semantic,
				method: method,
				substitutions: semantic,
				setter: setter
			};
		}
		// The original declaration owns the field, even when the method was overridden in a different generic owner.
		var storageOwner = info.owner, storageMethod = method, cls = session.classDecls.get(storageOwner);
		while (cls != null && inherited(session, cls, name)) {
			var parent = MemberAccess.methodInfo(session, BodyTyper.inheritanceName(cls.base), name);
			if (parent == null)
				throw new InternalError('Missing dynamic method "$name" in base of "$storageOwner"');
			storageOwner = parent.owner;
			storageMethod = session.signatures.required(storageOwner + "." + name);
			cls = session.classDecls.get(storageOwner);
		}
		var substitutions = session.representation.methodSubstitutions(receiver.type, storageOwner),
			storageType = functionType(session, storageMethod, eraseParameters(storageMethod, substitutions.physical));
		return {
			storage: new TypedExpression(TField(receiver, name), storageType, span),
			type: functionType(session, storageMethod, eraseParameters(storageMethod, substitutions.semantic)),
			method: method,
			substitutions: semantic
		};
	}

	public static function staticOwner(session:TypingSession, owner:String):String
		return session.declarations.abstracts.exists(owner) ? TypeStatics.storageName(owner) : owner;
}
