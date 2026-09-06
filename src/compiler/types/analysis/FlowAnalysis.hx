package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;

/** Applies branch-local type facts without owning declaration or body typing. */
class FlowAnalysis {
	public static function narrowedScope(scope:Scope, condition:TypedExpression, truthy:Bool):Scope {
		var result = new Scope(scope);
		applyConditionNarrowing(result, condition, truthy);
		return result;
	}

	public static function refineAfterGuard(scope:Scope, condition:TypedExpression):Void
		applyConditionNarrowing(scope, condition, false);

	static function applyConditionNarrowing(scope:Scope, condition:TypedExpression, truthy:Bool):Void {
		switch condition.expression {
			case TAnd(left, right) if (truthy):
				applyConditionNarrowing(scope, left, true);
				applyConditionNarrowing(scope, right, true);
				return;
			case TOr(left, right) if (!truthy):
				applyConditionNarrowing(scope, left, false);
				applyConditionNarrowing(scope, right, false);
				return;
			default:
		}
		var comparison = nullComparison(condition);
		if (comparison != null) {
			var nonNull = truthy == comparison.nonNullWhenTrue;
			scope.refine(comparison.name, nonNull ? comparison.nonNullType : TNull);
		}
	}

	static function nullComparison(condition:TypedExpression):Null<{name:String, nonNullType:CompilerType, nonNullWhenTrue:Bool}> {
		return switch condition.expression {
			case TEqual(left, right): var local = nullableLocal(left),
					other = isNullValue(right) ? true : false; if (local == null) {
					local = nullableLocal(right);
					other = isNullValue(left);
				} local == null || !other ? null : {name: local.name, nonNullType: local.nonNullType, nonNullWhenTrue: false};
			case TNot(value):
				var comparison = nullComparison(value);
				comparison == null ? null : {
					name: comparison.name,
					nonNullType: comparison.nonNullType,
					nonNullWhenTrue: !comparison.nonNullWhenTrue
				};
			default: null;
		};
	}

	static function nullableLocal(expression:TypedExpression):Null<{name:String, nonNullType:CompilerType}> {
		return switch expression.expression {
			case TLocal(name), TCellLocal(name, _): switch expression.type {
					case TNullable(element): {name: name, nonNullType: element};
					default: null;
				};
			default: null;
		};
	}

	static function isNullValue(expression:TypedExpression):Bool
		return switch expression.expression {
			case TNullLiteral: true;
			case TNullableWrap(value): isNullValue(value);
			default: false;
		};
}
