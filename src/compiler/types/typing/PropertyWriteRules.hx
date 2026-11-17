package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Access to properties whose setter is `null` follows the declaring class's lexical access. */
class PropertyWriteRules {
	public static function rejectInstanceMutation(session:TypingSession, type:CompilerType, name:String,
			span:SourceSpan):Void {
		var owner = switch type {
			case TInstance(NominalKind.Class, className, _): className;
			default: null;
		};
		check(session, owner, name, false, span);
	}

	public static function rejectStaticMutation(session:TypingSession, owner:String, name:String, span:SourceSpan):Void
		check(session, owner, name, true, span);

	/** A write to the field `name` of `owner` or its base classes: the source reaches it, and its property may be written here. */
	static function check(session:TypingSession, owner:Null<String>, name:String, isStatic:Bool, span:SourceSpan):Void {
		var found = owner == null ? null : MemberAccess.classField(session, owner, name, isStatic);
		if (found == null)
			return;
		MemberAccess.requireField(session, found.declaration, found.field, span);
		if (!canWrite(session, found.declaration, found.field))
			throw new CompileError(new Diagnostic("E1024",
				'Property "${found.declaration.name}.$name" cannot be written here',
				span));
	}

	public static function canWrite(session:TypingSession, declaration:AstClass, field:AstField):Bool
		return field.writeAccess != NullAccess || canAccess(session, declaration, field);

	public static function canAccess(session:TypingSession, declaration:AstClass, field:AstField):Bool
		return MemberAccess.canAccess(session, declaration.name, declaration.metadata, field.name, field.metadata);
}
