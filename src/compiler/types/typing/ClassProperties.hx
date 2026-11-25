package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.types.typing.NullSafety.NullSafetyUse;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.TypeStatics;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.types.StructProperties;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.analysis.Scope;
import compiler.types.typing.MemberAccess.DeclaredField;

/**
 * Properties of a class, static (`static var count(get, set):Int`, of a class or of an abstract, whose statics its storage class
 * keeps, `TypeStatics`) or instance (`var label(get, set):String`). As in Haxe (field access in its typer, typeloadFields):
 *
 * - a `get`, `set` or `dynamic` side is a call of its accessor, `get_x` or `set_x`, wherever source names the property (`c.x`,
 *   `Counter.count`, a bare name in its class, `x += 1`, `x++`); an instance accessor is a method, so an override is called;
 * - inside the accessor of that side, the property of `this` (a static's, in its own type) is the variable itself (Haxe's
 *   `@:isVar` storage), so a read in `set_x` still calls `get_x`;
 * - a `never` side cannot be accessed, and a `null` side only where its class's private members can be (the class, its
 *   subclasses, `@:allow`, `@:access`): "This expression cannot be accessed for reading" (or "writing"), at the name;
 * - an accessor a `get` or `set` side names must be declared ("Method get_x required by property x is missing"); a `dynamic`
 *   side's need not, but one an access reaches must exist ("Could not resolve accessor").
 *
 * `default` sides, and `null` ones where allowed, read and write the variable.
 */
class ClassProperties {
	/** Whether a side of this access calls an accessor. */
	static inline function callsAccessor(access:Null<AstFieldAccess>):Bool
		return access == GetAccess || access == SetAccess || access == DynamicAccess;

	static inline function accessOf(field:AstField, read:Bool):Null<AstFieldAccess>
		return read ? field.readAccess : field.writeAccess;

	static inline function accessorName(name:String, read:Bool):String
		return (read ? "get_" : "set_") + name;

	/**
	 * The function a read (`get_x`) or write (`set_x`) of the static `name` of `owner` calls, or null when that side reads or
	 * writes the variable. An abstract's accessors are the abstract's static methods.
	 */
	public static function staticAccessor(session:TypingSession, owner:String, name:String, read:Bool):Null<String> {
		var field = staticField(session, owner, name);
		if (field == null || !callsAccessor(accessOf(field, read)))
			return null;
		var accessor = (TypeStatics.ownerOf(owner) ?? owner) + "." + accessorName(name, read);
		return accessor == session.currentContext.functionName ? null : accessor;
	}

	/**
	 * Requires that the static `name` of `owner` may be read (`read`) or written: a `never` side may not, outside the property's
	 * own accessors, and a `null` side only where its class's private members can be.
	 */
	public static function requireStaticAccess(session:TypingSession, owner:String, name:String, read:Bool,
			span:SourceSpan):Void {
		var found = MemberAccess.classField(session, owner, name, true);
		if (found == null)
			return;
		var access = accessOf(found.field, read);
		if (access == NeverAccess) {
			var accessorOwner = (TypeStatics.ownerOf(found.declaration.name) ?? found.declaration.name) + ".",
				functionName = session.currentContext.functionName;
			if (functionName != accessorOwner + "get_" + name && functionName != accessorOwner + "set_" + name)
				inaccessible(read, name, span);
		} else if (access == NullAccess)
			requireNullSide(session, found, read, span);
	}

	/** The instance property `name` of a value of `type`, a class instance: the field of its class or nearest base declaring it. */
	public static function instanceField(session:TypingSession, type:CompilerType, name:String):Null<DeclaredField>
		return switch type {
			case TInstance(NominalKind.Class, className, _): MemberAccess.classField(session, className, name, false);
			default: null;
		};

	/**
	 * The method a read (`get_x`) or write (`set_x`) of the instance property `name` of `receiver` (of `type`) calls, or null when
	 * that side reads or writes the variable: a side that is not an accessor, or the property of `this` inside that side's own
	 * accessor. Errors are at the property's name in `span`.
	 */
	public static function instanceAccessor(session:TypingSession, type:CompilerType, name:String, read:Bool,
			receiver:TypedExpression, span:SourceSpan):Null<String> {
		var found = instanceField(session, type, name);
		if (found == null || !callsAccessor(accessOf(found.field, read)))
			return null;
		var simple = accessorName(name, read), context = session.currentContext;
		if (isThis(receiver) && context.functionName == context.lexicalOwner + "." + simple) {
			requireStorage(found.field, read, span);
			return null;
		}
		var method = MemberAccess.methodInfo(session, found.declaration.name, simple);
		if (method == null || method.isStatic)
			throw new CompileError(new Diagnostic(DiagnosticCode.NAME_OR_MEMBER, "Could not resolve accessor", span));
		return method.owner + "." + simple;
	}

	/** Whether the instance property `name` of a value of `type` reads or writes through an accessor. */
	public static function hasInstanceAccessor(session:TypingSession, type:CompilerType, name:String):Bool {
		var found = instanceField(session, type, name);
		return found != null && (callsAccessor(found.field.readAccess) || callsAccessor(found.field.writeAccess));
	}

	/** Requires that the instance property `name` of a value of `type` may be read (`read`) or written here. */
	public static function requireInstanceAccess(session:TypingSession, type:CompilerType, name:String, read:Bool,
			span:SourceSpan):Void {
		var found = instanceField(session, type, name);
		if (found == null)
			return;
		var access = accessOf(found.field, read);
		if (access == NeverAccess)
			inaccessible(read, name, span);
		else if (access == NullAccess)
			requireNullSide(session, found, read, span);
	}

	static function requireNullSide(session:TypingSession, found:DeclaredField, read:Bool, span:SourceSpan):Void {
		if (!MemberAccess.canAccess(session, found.declaration.name, found.declaration.metadata, found.field.name,
			found.field.metadata))
			inaccessible(read, found.field.name, span);
	}

	/** Inside its own accessor a property is its variable, which only a stored one has (`@:isVar`, or a `default` or `null` side). */
	static function requireStorage(field:AstField, read:Bool, span:SourceSpan):Void
		if (!StructProperties.hasStorage(field))
			throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
				"This field cannot be accessed because it is not a real variable",
				AbstractProperties.nameSpan(span, field.name, read)));

	static function inaccessible(read:Bool, name:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(DiagnosticCode.ANNOTATION_OR_SCHEMA,
			'This expression cannot be accessed for ${read ? "reading" : "writing"}',
			AbstractProperties.nameSpan(span, name, read)));

	static function isThis(receiver:TypedExpression):Bool
		return switch receiver.expression {
			case TLocal("this"): true;
			case TCast(inner): isThis(inner);
			default: false;
		};

	/**
	 * Haxe's check of a class's properties (typeloadFields): each accessor a `get` or `set` side names is declared, a static's as a
	 * static method of its type, an instance property's as a method of its class or a base class.
	 */
	public static function validate(session:TypingSession, declaration:AstClass):Void {
		var abstractName = TypeStatics.ownerOf(declaration.name),
			abstractDeclaration = abstractName == null ? null : session.declarations.abstracts.get(abstractName),
			staticMethods = abstractDeclaration != null ? abstractDeclaration.methods : declaration.methods;
		for (field in declaration.fields)
			for (read in [true, false])
				if (accessOf(field, read) == (read ? GetAccess : SetAccess)) {
					var name = accessorName(field.name, read), declared = false;
					if (field.isStatic) {
						for (method in staticMethods)
							if (method.name == name && method.isStatic)
								declared = true;
					} else
						declared = declaresInstanceMethod(session, declaration, name);
					if (!declared)
						throw new CompileError(new Diagnostic(DiagnosticCode.ASSIGNMENT_OR_BINDING,
							'Method $name required by property ${field.name} is missing',
							field.declarationSpan ?? field.span));
				}
	}

	/** Whether `declaration` or a base class declares the instance method `name`. */
	static function declaresInstanceMethod(session:TypingSession, declaration:Null<AstClass>, name:String):Bool {
		var seen:Map<String, Bool> = [];
		while (declaration != null && !seen.exists(declaration.name)) {
			seen.set(declaration.name, true);
			for (method in declaration.methods)
				if (method.name == name && !method.isStatic)
					return true;
			declaration = declaration.base == null
				? null : session.classDecls.get(BodyTyper.inheritanceName(declaration.base));
		}
		return false;
	}

	/** A static property named inside its own accessor is its variable, which must be stored. */
	static function requireStaticStorage(session:TypingSession, owner:String, name:String, read:Bool,
			span:SourceSpan):Void {
		var field = staticField(session, owner, name);
		if (field != null && callsAccessor(accessOf(field, read)))
			requireStorage(field, read, span);
	}

	static function staticField(session:TypingSession, owner:String, name:String):Null<AstField> {
		var declaration = session.classDecls.get(owner);
		if (declaration != null)
			for (field in declaration.fields)
				if (field.isStatic && field.name == name)
					return field;
		return null;
	}

	/** A read of the static `name` of `owner` that calls its getter, or null when it reads the variable. */
	public static function readStatic(session:TypingSession, bodyTyper:BodyTyping, owner:String, name:String,
			type:CompilerType, span:SourceSpan, scope:Null<Scope>):Null<TypedExpression> {
		requireStaticAccess(session, owner, name, true, span);
		var getter = staticAccessor(session, owner, name, true);
		if (getter == null) {
			requireStaticStorage(session, owner, name, true, span);
			return null;
		}
		var method = session.signatures.get(getter);
		if (method == null)
			throw new CompileError(new Diagnostic(DiagnosticCode.NAME_OR_MEMBER, "Could not resolve accessor", span));
		if (scope != null)
			session.invalidateCallEffects(getter, scope);
		var call = new TypedExpression(TCall(getter, []), bodyTyper.functionResultType(method, method.span), span);
		return bodyTyper.coerce(call, type, 'property "$name"', DiagnosticCode.ASSIGNMENT_OR_BINDING);
	}

	/** A write of `value` (of the property's type) to the static `name` of `owner` that calls its setter, or null. */
	public static function writeStatic(session:TypingSession, bodyTyper:BodyTyping, owner:String, name:String,
			value:TypedExpression, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		var setter = staticAccessor(session, owner, name, false);
		if (setter == null) {
			requireStaticStorage(session, owner, name, false, span);
			return null;
		}
		var method = session.signatures.get(setter);
		if (method == null)
			throw new CompileError(new Diagnostic(DiagnosticCode.NAME_OR_MEMBER, "Could not resolve accessor", span));
		var argumentTypes = bodyTyper.argumentTypesOf(method);
		if (argumentTypes.length != 1)
			return null;
		session.invalidateCallEffects(setter, scope);
		scope.invalidateExpression('static:$owner.$name');
		return new TypedExpression(TCall(setter,
			[bodyTyper.coerce(value, argumentTypes[0], 'property "$name"', DiagnosticCode.ASSIGNMENT_OR_BINDING,
			Assignment(value.span))]),
			bodyTyper.functionResultType(method, method.span), span);
	}
}
