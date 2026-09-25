package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;

/** Applies branch-local type facts without owning declaration or body typing. */
class FlowAnalysis {
	/** `isPureCall` decides which calls inside the condition keep earlier mutable facts. */
	public static function narrowedScope(scope:Scope, condition:TypedExpression, truthy:Bool, isPureCall:String->Bool):Scope {
		var result = new Scope(scope);
		applyConditionNarrowing(result, condition, truthy, isPureCall);
		return result;
	}

	public static function refineAfterGuard(scope:Scope, condition:TypedExpression, isPureCall:String->Bool):Void
		applyConditionNarrowing(scope, condition, false, isPureCall);

	static function applyConditionNarrowing(scope:Scope, condition:TypedExpression, truthy:Bool, isPureCall:String->Bool):Void {
		switch condition.expression {
			// Facts from the left operand hold after the right one only when it cannot mutate state.
			case TAnd(left, right) if (truthy):
				applyConditionNarrowing(scope, left, true, isPureCall);
				if (mayHaveEffect(right, isPureCall))
					scope.invalidateAllExpressions();
				applyConditionNarrowing(scope, right, true, isPureCall);
				return;
			case TOr(left, right) if (!truthy):
				applyConditionNarrowing(scope, left, false, isPureCall);
				if (mayHaveEffect(right, isPureCall))
					scope.invalidateAllExpressions();
				applyConditionNarrowing(scope, right, false, isPureCall);
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
				scope.refineExpression(comparison.path, refined, comparison.stable);
		}
	}

	/** Conservative: only expression kinds known not to write state, and pure calls, are effect-free. */
	public static function mayHaveEffect(expression:TypedExpression, isPureCall:String->Bool):Bool {
		return switch expression.expression {
			case TIntLiteral(_), TFloatLiteral(_), TStringLiteral(_), TRuntimeDataAddress(_), TBoolLiteral(_), TEnumLiteral(_, _), TNullLiteral, TVoidLiteral,
				TLocal(_), TCellLocal(_, _), TCaptured(_), TCellCaptured(_, _), TClassRef(_), TStaticField(_, _), TFunctionRef(_), TLambda(_, _, _),
				TNewMap(_, _):
				false;
			case TEnumIndex(value), TEnumField(value, _, _), TNullableWrap(value), TIntToFloat(value), TIntToInt64(value), TFloatToInt(value),
				TToDynamic(value), TNegate(value), TNot(value), TCast(value), TAbiCast(value), TToInterface(value, _), TArrayLength(value),
				TStringLength(value), TStringFromCharCode(value), TNewArray(_, value), TMethodRef(value, _), TField(value, _):
				mayHaveEffect(value, isPureCall);
			case TAdd(left, right), TSub(left, right), TMul(left, right), TDiv(left, right), TMod(left, right), TBitAnd(left, right), TBitXor(left, right),
				TBitOr(left, right), TShiftLeft(left, right), TShiftRight(left, right), TUnsignedShiftRight(left, right), TLess(left, right),
				TLessEqual(left, right), TEqual(left, right), TAnd(left, right), TOr(left, right), TIndex(left, right), TMapGet(left, right),
				TStringIndexOf(left, right), TStringCharAt(left, right), TStringCharCodeAt(left, right), TRange(left, right): mayHaveEffect(left,
					isPureCall) || mayHaveEffect(right, isPureCall);
			case TStringSubstring(value, start, end): mayHaveEffect(value,
					isPureCall) || mayHaveEffect(start, isPureCall) || (end != null && mayHaveEffect(end, isPureCall));
			case TConditional(test, yes, no): mayHaveEffect(test, isPureCall) || mayHaveEffect(yes, isPureCall) || mayHaveEffect(no, isPureCall);
			case TEnumConstruct(_, _, values), TArrayLiteral(values): anyEffect(values, isPureCall);
			case TCall(name, arguments): !isPureCall(name) || anyEffect(arguments, isPureCall);
			case TMethodCall(object, name, arguments): !isPureCall(name) || mayHaveEffect(object, isPureCall) || anyEffect(arguments, isPureCall);
			case TCollectionCall(receiver, operation, arguments):
				switch operation {
					case "exists" | "index_of" | "copy" | "slice" | "join" | "keys": mayHaveEffect(receiver, isPureCall) || anyEffect(arguments, isPureCall);
					default: true;
				}
			default: true;
		};
	}

	static function anyEffect(values:Array<TypedExpression>, isPureCall:String->Bool):Bool {
		for (value in values)
			if (mayHaveEffect(value, isPureCall))
				return true;
		return false;
	}

	static function typeTest(condition:TypedExpression):Null<{path:String, type:CompilerType, narrowsWhenTrue:Bool}> {
		return switch condition.expression {
			case TCall("__std_is_of_type", [value, target]):
				// A bare Array test proves only HARRAY, not its element representation.
				// Narrowing to Array<Dynamic> would permit incompatible typed reads.
				switch target.type {
					case TArray(_): null;
					default:
						var path = accessPath(value);
						path == null ? null : {path: path, type: target.type, narrowsWhenTrue: true};
				}
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
		stable:Bool,
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
					stable: local.stable,
					nonNullWhenTrue: false
				};
			case TNot(value):
				var comparison = nullComparison(value);
				comparison == null ? null : {
					localName: comparison.localName,
					path: comparison.path,
					nonNullType: comparison.nonNullType,
					stable: comparison.stable,
					nonNullWhenTrue: !comparison.nonNullWhenTrue
				};
			default: null;
		};
	}

	static function nullableAccess(expression:TypedExpression):Null<{
		localName:String,
		path:String,
		nonNullType:CompilerType,
		stable:Bool
	}> {
		return switch expression.expression {
			case TLocal(name), TCellLocal(name, _), TCaptured(name), TCellCaptured(name, _): switch expression.type {
					case TNullable(element): {
							localName: name,
							path: "",
							nonNullType: element,
							stable: false
						};
					default: null;
				};
			default:
				var path = accessPath(expression);
				switch expression.type {
					case TNullable(element) if (path != null): {
							localName: "",
							path: path,
							nonNullType: element,
							stable: expression.stableFlowValue
						};
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
			case TMapGet(map, key): mapEntryPath(map, key);
			case TCast(value), TAbiCast(value), TToDynamic(value): accessPath(value);
			default: null;
		};

	public static function mapKeySource(expression:TypedExpression, scope:Scope):Null<TypedExpression> {
		return switch expression.expression {
			case TLocal(name), TCellLocal(name, _), TCaptured(name), TCellCaptured(name, _):
				var source = scope.mapKeySource(name);
				source == null ? expression.mapKeySource : source;
			case TCast(value), TAbiCast(value), TToDynamic(value): mapKeySource(value, scope);
			default: expression.mapKeySource;
		};
	}

	static function isNullValue(expression:TypedExpression):Bool
		return switch expression.expression {
			case TNullLiteral: true;
			case TNullableWrap(value): isNullValue(value);
			default: false;
		};
}
