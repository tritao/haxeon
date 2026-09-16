package compiler.syntax;

import compiler.syntax.Ast;

/** Immediate expression operands; lexical statement bodies are visited by their owner. */
class AstChildren {
	/**
	 * Immediate source-type operands. Type names themselves are leaves, but
	 * every compound type can contain more declaration-bearing type syntax.
	 * Keep this switch exhaustive so a new AstType constructor cannot silently
	 * disappear from recovery indexing.
	 */
	public static function types(type:AstType):Array<AstType>
		return switch type {
			case IntType, BoolType, FloatType, StringType, VoidType, InferredType, ErrorType(_), NativeAbstractType(_, _), NamedType(_): [];
			case AppliedType(_, arguments): arguments;
			case ArrayType(element), NullableType(element): [element];
			case MapType(key, value): [key, value];
			case FunctionType(arguments, result): arguments.concat([result]);
			case AnonymousType(fields): [for (field in fields) field.type];
		};

	/** Visit a complete source type tree, including its root node. */
	public static function walkType(type:AstType, visit:AstType->Void):Void {
		visit(type);
		for (child in types(type))
			walkType(child, visit);
	}

	public static function expressions(expression:AstExpression):Array<AstExpression>
		return switch expression {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_), EmptyExpression(_),
				ErrorExpression(_), Variable(_, _), NativeLayoutQuery(_, _, _, _), NewMap(_, _, _), Lambda(_, _, _): [];
			case Member(value, _, _), Negate(value, _), Not(value, _), ThrowExpression(value, _), Cast(value, _, _), NewArray(_, value, _),
				PostfixIncrement(value, _, _), BlockExpression(_, value, _): [value];
			case Add(a, b, _), Sub(a, b, _), Mul(a, b, _), Div(a, b, _), Mod(a, b, _), BitAnd(a, b, _), BitXor(a, b, _), BitOr(a, b, _), ShiftLeft(a, b, _),
				ShiftRight(a, b, _), UnsignedShiftRight(a, b, _), Less(a, b, _), LessEqual(a, b, _), Greater(a, b, _), GreaterEqual(a, b, _), Equal(a, b, _),
				NotEqual(a, b, _), And(a, b, _), Or(a, b, _), Range(a, b, _), Index(a, b, _): [a, b];
			case Conditional(predicate, yes, no, _): [predicate, yes, no];
			case Call(_, arguments, _), New(_, arguments, _), NewGeneric(_, _, arguments, _), ArrayLiteral(arguments, _): arguments;
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
			case ArrayComprehension(_, _, iterable, predicate, value, _):
				predicate == null ? [iterable, value] : [iterable, predicate, value];
			case MapComprehension(_, _, iterable, predicate, key, value, _):
				predicate == null ? [iterable, key, value] : [iterable, predicate, key, value];
		};

	public static function statementExpressions(statement:AstStatement):Array<AstExpression>
		return switch statement {
			case VarDeclaration(_, _, value, _), Assignment(_, value, _), Return(value, _), Throw(value, _), Expression(value, _), If(value, _, _, _),
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
			case ErrorStatement(_), UninitializedDeclaration(_, _, _), ReturnVoid(_), Try(_, _, _), Break(_), Continue(_), Increment(_, _, _): [];
		};
}
