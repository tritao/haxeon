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
			var nonNull = truthy == comparison.nonNullWhenTrue,
				refined = nonNull ? comparison.nonNullType : TNull;
			if (comparison.localName.length > 0)
				scope.refine(comparison.localName, refined);
			else
				scope.refineExpression(comparison.path, refined);
		}
	}

	static function nullComparison(condition:TypedExpression):Null<{
		localName:String,
		path:String,
		nonNullType:CompilerType,
		nonNullWhenTrue:Bool
	}> {
		return switch condition.expression {
			case TEqual(left, right): var local = nullableAccess(left),
					other = isNullValue(right) ? true : false; if (local == null) {
					local = nullableAccess(right);
					other = isNullValue(left);
				} local == null || !other ? null : {
					localName: local.localName,
					path: local.path,
					nonNullType: local.nonNullType,
					nonNullWhenTrue: false
				};
			case TNot(value):
				var comparison = nullComparison(value);
				comparison == null ? null : {
					localName: comparison.localName,
					path: comparison.path,
					nonNullType: comparison.nonNullType,
					nonNullWhenTrue: !comparison.nonNullWhenTrue
				};
			default: null;
		};
	}

	static function nullableAccess(expression:TypedExpression):Null<{localName:String, path:String, nonNullType:CompilerType}> {
		return switch expression.expression {
			case TLocal(name), TCellLocal(name, _): switch expression.type {
					case TNullable(element): {localName: name, path: "", nonNullType: element};
					default: null;
				};
			default:
				var path = accessPath(expression);
				switch expression.type {
					case TNullable(element) if (path != null): {localName: "", path: path, nonNullType: element};
					default: null;
				}
		};
	}

	public static function accessPath(expression:TypedExpression):Null<String>
		return switch expression.expression {
			case TLocal(name), TCellLocal(name, _): name;
			case TField(object, name):
				var parent = accessPath(object);
				parent == null ? null : parent + "." + name;
			case TCast(value), TAbiCast(value): accessPath(value);
			default: null;
		};

	static function isNullValue(expression:TypedExpression):Bool
		return switch expression.expression {
			case TNullLiteral: true;
			case TNullableWrap(value): isNullValue(value);
			default: false;
		};
}
