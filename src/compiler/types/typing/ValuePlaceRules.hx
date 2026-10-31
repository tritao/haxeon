package compiler.types.typing;

import compiler.Source.SourceSpan;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.types.TypedAst.TypedExpression;

/** Writes to values must reach owned storage, rather than a discarded temporary copy. */
class ValuePlaceRules {
	public static function requireWritable(session:TypingSession, receiver:TypedExpression, span:SourceSpan):Void {
		if (!session.relations.isValueClass(receiver.type))
			return;
		checkPlace(session, receiver, span);
	}

	static function checkPlace(session:TypingSession, receiver:TypedExpression, span:SourceSpan):Void {
		switch receiver.expression {
			case TLocal(_), TCellLocal(_, _), TCaptured(_), TCellCaptured(_, _), TStaticField(_, _), TIndex(_, _):
			case TField(parent, name):
				if (session.relations.isValueClass(parent.type))
					FinalFieldRules.rejectInstanceMutation(session, parent, name, span);
				requireWritable(session, parent, span);
			case TCast(value), TAbiCast(value):
				if (session.relations.isValueClass(value.type) || session.relations.isNullableValueClass(value.type))
					checkPlace(session, value, span);
				else
					rejectTemporary(receiver, span);
			case TCall("$rawptr.ref.flat", _):
			default:
				rejectTemporary(receiver, span);
		}
	}

	static function rejectTemporary(receiver:TypedExpression, span:SourceSpan):Void {
		var origin = receiver.span;
		var expression = origin.file.slice(origin.start, origin.end);
		throw new CompileError(new Diagnostic("E1027", 'Cannot mutate temporary struct copy produced by "$expression"; bind it to a local first', span));
	}
}
