package compiler.syntax;

import compiler.syntax.Ast;

/** Receives the children `AstChildren.visit` finds. */
interface AstChildVisitor {
	function visitChild(child:AstExpression):Void;
}

/** Immediate expression operands; lexical statement bodies are visited by their owner. */
class AstChildren {
	/** Hands each of `expressions(expression)` to `visitor`, in the same order, without building the array. */
	public static function visit(expression:AstExpression, visitor:AstChildVisitor):Void
		switch expression {
			case PrivateAccessExpression(inner, _):
				visitor.visitChild(inner);
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_),
				Unreachable(_), EmptyExpression(_),
				ErrorExpression(_), Variable(_, _), NativeLayoutQuery(_, _, _, _), KeyPathLiteral(_, _, _),
				NewMap(_, _, _), Lambda(_, _, _, _):
			case Member(value, _, _), Negate(value, _), Not(value, _), ThrowExpression(value, _), Cast(value, _, _),
				CheckType(value, _, _), NewArray(_, value, _),
				PostfixIncrement(value, _, _), BlockExpression(_, value, _), Capture(_, value, _):
				visitor.visitChild(value);
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), BitAnd(a, b, _), BitXor(a, b, _),
				BitOr(a, b, _), ShiftLeft(a, b, _),
				ShiftRight(a, b, _), UnsignedShiftRight(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _),
				GreaterEqual(a, b, _), Equal(a, b, _),
				NotEqual(a, b, _), And(a, b, _), Or(a, b, _), Range(a, b, _), Index(a, b, _):
				visitor.visitChild(a);
				visitor.visitChild(b);
			case Conditional(predicate, yes, no, _):
				visitor.visitChild(predicate);
				visitor.visitChild(yes);
				visitor.visitChild(no);
			case Call(_, arguments, _), New(_, arguments, _), NewGeneric(_, _, arguments, _),
				ArrayLiteral(arguments, _):
				for (argument in arguments)
					visitor.visitChild(argument);
			case ClosureCall(first, arguments, _), MethodCall(first, _, arguments, _):
				visitor.visitChild(first);
				for (argument in arguments)
					visitor.visitChild(argument);
			case ObjectLiteral(fields, _):
				for (field in fields)
					visitor.visitChild(field.value);
			case MapLiteral(entries, _):
				for (entry in entries) {
					visitor.visitChild(entry.key);
					visitor.visitChild(entry.value);
				}
			case SwitchExpression(subject, cases, fallback, _):
				visitor.visitChild(subject);
				for (arm in cases) {
					visitor.visitChild(arm.value);
					if (arm.guard != null)
						visitor.visitChild(arm.guard);
					visitor.visitChild(arm.result);
				}
				if (fallback != null)
					visitor.visitChild(fallback);
			case ArrayComprehension(_, _, iterable, predicate, value, _, _):
				visitor.visitChild(iterable);
				if (predicate != null)
					visitor.visitChild(predicate);
				visitor.visitChild(value);
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				visitor.visitChild(iterable);
				if (predicate != null)
					visitor.visitChild(predicate);
				visitor.visitChild(key);
				visitor.visitChild(value);
		}

	/** Hands each of `statementExpressions(statement)` to `visitor`, in the same order, without building the array. */
	public static function visitStatement(statement:AstStatement, visitor:AstChildVisitor):Void
		switch statement {
			case PrivateAccessStatement(inner, _):
				visitStatement(inner, visitor);
			case VarDeclaration(_, _, value, _), ScopedDeclaration(_, _, value, _), Assignment(_, value, _),
				Return(value, _), Throw(value, _), Expression(value, _), If(value, _, _, _),
				While(value, _, _), DoWhile(_, value, _), ForIn(_, _, value, _, _):
				visitor.visitChild(value);
			case IndexAssignment(array, offset, value, _):
				visitor.visitChild(array);
				visitor.visitChild(offset);
				visitor.visitChild(value);
			case FieldAssignment(receiver, _, value, _):
				visitor.visitChild(receiver);
				visitor.visitChild(value);
			case Switch(subject, cases, _, _, _):
				visitor.visitChild(subject);
				for (arm in cases) {
					visitor.visitChild(arm.value);
					if (arm.guard != null)
						visitor.visitChild(arm.guard);
				}
			case ErrorStatement(_), UninitializedDeclaration(_, _, _), ReturnVoid(_), Defer(_, _), Try(_, _, _),
				Break(_), Continue(_), Increment(_, _, _):
		}

	public static function expressions(expression:AstExpression):Array<AstExpression>
		return switch expression {
			case PrivateAccessExpression(inner, _): [inner];
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_),
				Unreachable(_), EmptyExpression(_),
				ErrorExpression(_), Variable(_, _), NativeLayoutQuery(_, _, _, _), KeyPathLiteral(_, _, _),
				NewMap(_, _, _), Lambda(_, _, _, _): [];
			case Member(value, _, _), Negate(value, _), Not(value, _), ThrowExpression(value, _), Cast(value, _, _),
				CheckType(value, _, _), NewArray(_, value, _),
				PostfixIncrement(value, _, _), BlockExpression(_, value, _), Capture(_, value, _): [value];
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), BitAnd(a, b, _), BitXor(a, b, _),
				BitOr(a, b, _), ShiftLeft(a, b, _),
				ShiftRight(a, b, _), UnsignedShiftRight(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _),
				GreaterEqual(a, b, _), Equal(a, b, _),
				NotEqual(a, b, _), And(a, b, _), Or(a, b, _), Range(a, b, _), Index(a, b, _): [a, b];
			case Conditional(predicate, yes, no, _): [predicate, yes, no];
			case Call(_, arguments, _), New(_, arguments, _), NewGeneric(_, _, arguments, _),
				ArrayLiteral(arguments, _): arguments;
			case ClosureCall(callee, arguments, _): [callee].concat(arguments);
			case MethodCall(receiver, _, arguments, _): [receiver].concat(arguments);
			case ObjectLiteral(fields, _): [for (field in fields) field.value];
			case MapLiteral(entries, _):
				var result:Array<AstExpression> = [];
				for (entry in entries) {
					result.push(entry.key);
					result.push(entry.value);
				}
				result;
			case SwitchExpression(subject, cases, fallback, _):
				var result = [subject];
				for (arm in cases) {
					result.push(arm.value);
					if (arm.guard != null)
						result.push(arm.guard);
					result.push(arm.result);
				}
				if (fallback != null)
					result.push(fallback);
				result;
			case ArrayComprehension(_, _, iterable, predicate, value, _, _):
				predicate == null ? [iterable, value] : [iterable, predicate, value];
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				predicate == null ? [iterable, key, value] : [iterable, predicate, key, value];
		};

	public static function statementExpressions(statement:AstStatement):Array<AstExpression>
		return switch statement {
			case PrivateAccessStatement(inner, _): statementExpressions(inner);
			case VarDeclaration(_, _, value, _), ScopedDeclaration(_, _, value, _), Assignment(_, value, _),
				Return(value, _), Throw(value, _), Expression(value, _), If(value, _, _, _),
				While(value, _, _), DoWhile(_, value, _), ForIn(_, _, value, _, _): [value];
			case IndexAssignment(array, offset, value, _): [array, offset, value];
			case FieldAssignment(receiver, _, value, _): [receiver, value];
			case Switch(subject, cases, _, _, _):
				var result = [subject];
				for (arm in cases) {
					result.push(arm.value);
					if (arm.guard != null)
						result.push(arm.guard);
				}
				result;
			case ErrorStatement(_), UninitializedDeclaration(_, _, _), ReturnVoid(_), Defer(_, _), Try(_, _, _),
				Break(_), Continue(_), Increment(_, _, _): [];
		};
}
