package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast;
import compiler.types.Type.CompilerType;

/** Writes to a class's fields: the source reaches the field, and its property's write side allows the write (`ClassProperties`). */
class PropertyWriteRules {
	public static function rejectInstanceMutation(session:TypingSession, type:CompilerType, name:String,
			span:SourceSpan):Void {
		var found = ClassProperties.instanceField(session, type, name);
		if (found == null)
			return;
		MemberAccess.requireField(session, found.declaration, found.field, span);
		ClassProperties.requireInstanceAccess(session, type, name, false, span);
	}

	public static function rejectStaticMutation(session:TypingSession, owner:String, name:String,
			span:SourceSpan):Void {
		var found = MemberAccess.classField(session, owner, name, true);
		if (found == null)
			return;
		MemberAccess.requireField(session, found.declaration, found.field, span);
		ClassProperties.requireStaticAccess(session, owner, name, false, span);
	}

	public static function canWrite(session:TypingSession, declaration:AstClass, field:AstField):Bool
		return field.writeAccess != NullAccess || canAccess(session, declaration, field);

	public static function canAccess(session:TypingSession, declaration:AstClass, field:AstField):Bool
		return MemberAccess.canAccess(session, declaration.name, declaration.metadata, field.name, field.metadata);
}
