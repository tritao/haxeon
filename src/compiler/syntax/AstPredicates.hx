package compiler.syntax;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

/** Small shared predicates over source expressions. */
class AstPredicates {
	/** Inspect a statement's structure without discarding its typing-time metadata. */
	public static function unannotatedStatement(value:AstStatement):AstStatement
		return switch value {
			case AnnotatedStatement(_, inner, _): unannotatedStatement(inner);
			default: value;
		};

	/** Inspect an expression's structure without discarding its typing-time metadata. */
	public static function unannotatedExpression(value:AstExpression):AstExpression
		return switch value {
			case AnnotatedExpression(_, inner, _): unannotatedExpression(inner);
			default: value;
		};

	/**
	 * Whether a block ends in an expression statement, through metadata and each branch of a final `try`: the statement whose
	 * value an arrow function's block returns (`Parser.returnArrowValue`) and a `function` lambda's drops.
	 */
	public static function endsInExpression(statements:Array<AstStatement>):Bool {
		if (statements.length == 0)
			return false;
		switch unannotatedStatement(statements[statements.length - 1]) {
			case Expression(_, _):
				return true;
			case Try(body, catches, _):
				if (endsInExpression(body))
					return true;
				for (clause in catches)
					if (endsInExpression(clause.statements))
						return true;
				return false;
			default:
				return false;
		}
	}

	public static function isNullExpression(value:Null<AstExpression>):Bool
		return switch value == null ? null : unannotatedExpression(value) {
			case null, NullLiteral(_): true;
			default: false;
		};

	/** The written identifier of a potential capture, before module and import qualification. */
	public static function patternCaptureName(name:String, span:SourceSpan):Null<String> {
		var written = span.isBareReference ? span.referenceName ?? name : name;
		if (written == "_" || written.indexOf(".") >= 0)
			return null;
		var first = written.charCodeAt(0);
		return first >= "A".code && first <= "Z".code ? null : written;
	}

	/** Whether a call may omit `argument`: it is written `?x` or has a default value, as Haxe's optional flag. */
	public static function isOptionalArgument(argument:AstArgument):Bool
		return argument.optional == true || argument.defaultValue != null;

	/**
	 * Whether `argument`'s type is made nullable, by Haxe's rule: `?x:Int` and `?x:Int = 7` are `Null<Int>`, as is
	 * `x:Int = null`; `x:Int = 7` is `Int`.
	 */
	public static function isNullableArgument(argument:AstArgument):Bool
		return argument.optional == true || argument.defaultValue != null && isNullExpression(argument.defaultValue);
}
