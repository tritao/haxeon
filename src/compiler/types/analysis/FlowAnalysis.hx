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
		var mapEntry = mapExistence(condition);
		if (mapEntry != null && truthy == mapEntry.existsWhenTrue) {
			scope.refineExpression(mapEntry.path, mapEntry.valueType);
			return;
		}
		var typeTest = typeTest(condition);
		if (typeTest != null && truthy == typeTest.narrowsWhenTrue) {
			refinePath(scope, typeTest.path, typeTest.type);
			return;
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

	static function typeTest(condition:TypedExpression):Null<{path:String, type:CompilerType, narrowsWhenTrue:Bool}> {
		return switch condition.expression {
			case TCall("__std_is_of_type", [value, target]):
				var path = accessPath(value);
				path == null ? null : {path: path, type: target.type, narrowsWhenTrue: true};
			case TNot(value):
				var nested = typeTest(value);
				nested == null ? null : {path: nested.path, type: nested.type, narrowsWhenTrue: !nested.narrowsWhenTrue};
			default: null;
		};
	}

	static function refinePath(scope:Scope, path:String, type:CompilerType):Void {
		if (path.indexOf(".") < 0)
			scope.refine(path, type);
		else
			scope.refineExpression(path, type);
	}

	static function mapExistence(condition:TypedExpression):Null<{path:String, valueType:CompilerType, existsWhenTrue:Bool}> {
		return switch condition.expression {
			case TCollectionCall(receiver, "exists", [key]):
				var path = mapEntryPath(receiver, key);
				switch receiver.type {
					case TMap(_, valueType) if (path != null): {path: path, valueType: valueType, existsWhenTrue: true};
					default: null;
				}
			case TNot(value):
				var existence = mapExistence(value);
				existence == null ? null : {path: existence.path, valueType: existence.valueType, existsWhenTrue: !existence.existsWhenTrue};
			default: null;
		};
	}

	public static function mapEntryPath(map:TypedExpression, key:TypedExpression):Null<String> {
		var mapPath = accessPath(map), keyPath = accessPath(key);
		if (mapPath == null)
			return null;
		if (keyPath != null)
			return 'map-entry:$mapPath:local:$keyPath';
		return switch key.expression {
			case TStringLiteral(value): 'map-entry:$mapPath:string:$value';
			case TIntLiteral(value): 'map-entry:$mapPath:int:$value';
			default: null;
		};
	}

	public static function mapEntriesPath(map:TypedExpression):Null<String> {
		var mapPath = accessPath(map);
		return mapPath == null ? null : 'map-entry:$mapPath:';
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
			case TLocal(name), TCellLocal(name, _), TCaptured(name), TCellCaptured(name, _): switch expression.type {
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
			case TLocal(name), TCellLocal(name, _), TCaptured(name), TCellCaptured(name, _): name;
			case TField(object, name):
				var parent = accessPath(object);
				parent == null ? null : parent + "." + name;
			case TCast(value), TAbiCast(value), TToDynamic(value): accessPath(value);
			default: null;
		};

	static function isNullValue(expression:TypedExpression):Bool
		return switch expression.expression {
			case TNullLiteral: true;
			case TNullableWrap(value): isNullValue(value);
			default: false;
		};
}
