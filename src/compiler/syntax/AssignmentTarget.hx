package compiler.syntax;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.TemporaryLocal;

typedef StabilizedAssignmentTarget = {
	final target:AstExpression;
	final bindings:Array<AstStatement>;
}

/** Normalizes writable expressions while preserving source evaluation order. */
class AssignmentTarget {
	public static function stabilize(target:AstExpression, span:compiler.core.Source.SourceSpan,
			spanOf:AstExpression->compiler.core.Source.SourceSpan):StabilizedAssignmentTarget {
		var bindings:Array<AstStatement> = [];
		var stable = switch target {
			case Index(array, offset, targetSpan):
				var receiver = temporary("receiver", span), index = temporary("index", span);
				bindings.push(TemporaryDeclaration(receiver, null, array, spanOf(array)));
				bindings.push(TemporaryDeclaration(index, null, offset, spanOf(offset)));
				Index(TemporaryVariable(receiver, spanOf(array)), TemporaryVariable(index, spanOf(offset)), targetSpan);
			case Member(object, field, targetSpan):
				var receiver = temporary("receiver", span);
				// Keep a value receiver as a place, rather than binding an ordinary value copy.
				// The typer checks its original expression before the generated local hides it.
				bindings.push(TemporaryDeclaration(receiver, null, Call("$value.place", [object], spanOf(object)),
					spanOf(object)));
				Member(TemporaryVariable(receiver, spanOf(object)), field, targetSpan);
			case Variable(_, _): target;
			default: target;
		};
		return {target: stable, bindings: bindings};
	}

	static function temporary(kind:String, span:compiler.core.Source.SourceSpan):TemporaryLocal
		return new TemporaryLocal('$' + 'compound:$kind:${span.start}');
}
