package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;

/**
 * `final` on a class field. An instance field can be assigned only through `this`, inside the constructor of the class that declares
 * it (or at its declaration); a static one only at its declaration. Anything else, including a write through another object, a
 * compound assignment or an increment, is an error: code (and the optimiser, which shares objects whose fields are all final)
 * relies on the field not changing.
 */
class FinalFieldRules {
	/** The class declaring instance field `name` as final, or null when the field is not final or not a class field. */
	public static function finalInstanceFieldOwner(session:TypingSession, type:CompilerType, name:String):Null<String> {
		var className:Null<String> = switch type {
			case TInstance(NominalKind.Class, declared, _): declared;
			default: null;
		};
		var guard = 0;
		while (className != null && guard++ < 64) {
			var declaration = session.classDecls.get(className);
			if (declaration == null)
				return null;
			for (field in declaration.fields)
				if (field.name == name && !field.isStatic)
					return field.isFinal ? className : null;
			className = declaration.base == null ? null : baseName(declaration.base);
		}
		return null;
	}

	/** Rejects a write to `object.name` unless it is `this.name` in the declaring class's constructor. */
	public static function rejectInstanceMutation(session:TypingSession, object:TypedExpression, name:String, span:SourceSpan):Void {
		var owner = finalInstanceFieldOwner(session, object.type, name);
		if (owner == null)
			return;
		var viaThis = switch object.expression {
			case TLocal("this"): true;
			default: false;
		};
		if (viaThis && session.currentContext.name == owner + ".new")
			return;
		fail("E1026", 'Final field "$owner.$name" can only be assigned through this in the constructor of "$owner"', span);
	}

	/** Rejects a write to a static final field: it is given its value where it is declared. */
	public static function rejectStaticMutation(session:TypingSession, owner:String, name:String, span:SourceSpan):Void {
		var declaration = session.classDecls.get(owner);
		if (declaration == null)
			return;
		for (field in declaration.fields)
			if (field.name == name && field.isStatic && field.isFinal)
				fail("E1026", 'Final static field "$owner.$name" cannot be assigned', span);
	}

	static function baseName(type:AstType):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
