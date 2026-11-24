package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.runtime.RuntimeType;
import compiler.semantic.SemanticSignature;
import compiler.types.Monomorphs;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;
import compiler.types.TypedAst.TypedExpression;

/** The value a `throw` throws. */
class ThrownValue {
	/**
	 * `value` as `throw` at `span` throws it: `throw null` throws a null Dynamic, as in Haxe, where a catch of Dynamic (or Any) binds
	 * null, a catch of haxe.Exception a ValueException of null, and a catch of any other type lets it through. A value whose static
	 * type is not haxe.Exception or a subclass of it is recorded in the unit's lint facts (`UnitRecords.nonExceptionThrows`), which
	 * `haxeon lint --only throw-non-exception` reports.
	 */
	public static function of(session:TypingSession, bodyTyper:BodyTyping, value:TypedExpression,
			span:SourceSpan):TypedExpression {
		session.nullSafety.checkThrow(value, span);
		if (!isException(session, value.type))
			session.output.records.nonExceptionThrows.push({
				span: span,
				thrown: SemanticSignature.display(Monomorphs.follow(value.type))
			});
		return TypeRelations.equals(value.type, TNull) ? bodyTyper.coerce(value, TDynamic, "thrown value",
			DiagnosticCode.COVERAGE_THROW_OR_EXTERN) : value;
	}

	/**
	 * Whether a value of `type` is statically haxe.Exception or a subclass of it, or never produced (a `throw` of a `throw`). A
	 * type variable nothing has filled yet is not: it settles to Dynamic or to what a later use gives it, which the throw does not see.
	 */
	static function isException(session:TypingSession, type:CompilerType):Bool
		return switch Monomorphs.follow(type) {
			case TNever: true;
			case TNullable(element): isException(session, element);
			case instance = TInstance(_, _, _): session.declarations.inheritance.project(instance,
				RuntimeType.EXCEPTION) != null;
			default: false;
		};
}
