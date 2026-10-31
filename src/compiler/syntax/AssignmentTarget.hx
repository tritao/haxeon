package compiler.syntax;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;

typedef StabilizedAssignmentTarget = {
	final target:AstExpression;
	final bindings:Array<AstStatement>;
}

/** Normalizes writable expressions while preserving source evaluation order. */
class AssignmentTarget {
	public static function stabilize(target:AstExpression, span:compiler.Source.SourceSpan,
			spanOf:AstExpression->compiler.Source.SourceSpan):StabilizedAssignmentTarget {
		var bindings:Array<AstStatement> = [];
		var stable = switch target {
			case Index(array, offset, targetSpan):
				var receiverName = temporary("receiver", span), indexName = temporary("index", span);
				bindings.push(VarDeclaration(receiverName, null, array, spanOf(array)));
				bindings.push(VarDeclaration(indexName, null, offset, spanOf(offset)));
				Index(Variable(receiverName, spanOf(array)), Variable(indexName, spanOf(offset)), targetSpan);
			case Member(object, field, targetSpan):
				var receiverName = temporary("receiver", span);
				// Keep a value receiver as a place, rather than binding an ordinary value copy.
				// The typer checks its original expression before the generated local hides it.
				bindings.push(VarDeclaration(receiverName, null, Call("$value.place", [object], spanOf(object)), spanOf(object)));
				Member(Variable(receiverName, spanOf(object)), field, targetSpan);
			case Variable(_, _): target;
			default: target;
		};
		return {target: stable, bindings: bindings};
	}

	static function temporary(kind:String, span:compiler.Source.SourceSpan):String
		return '$' + 'compound:$kind:${span.start}';
}
