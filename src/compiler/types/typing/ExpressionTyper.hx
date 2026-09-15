package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.ffi.HxiAbi;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.ffi.NativeLayout;
import compiler.semantic.SemanticSignature;
import compiler.syntax.Ast.AstMapEntry;
import compiler.syntax.Ast.AstObjectField;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstSwitchExpressionCase;
import compiler.syntax.Ast.AstType;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.Scope;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedMapEntry;
import compiler.types.TypedAst.TypedObjectField;
import compiler.types.TypedAst.TypedSwitchBinding;
import compiler.types.TypedAst.TypedSwitchExpressionCase;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedSwitchCoverageCase;
import compiler.types.TypedAst.TypedSwitchArrayPattern;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;

typedef ExpressionTypeCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef ExpressionCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;
typedef ExpressionSwitchArrayPatternCallback = (AstExpression, CompilerType, Scope) -> Null<TypedSwitchArrayPattern>;
typedef ExpressionSwitchArrayPatternKeyCallback = TypedSwitchArrayPattern->Null<String>;
typedef ExpressionArrayElementTypeCallback = (CompilerType, SourceSpan) -> CompilerType;
typedef ContextualExpressionTypeCallback = (AstExpression, Scope) -> Null<CompilerType>;
typedef LowerExpressionTypeCallback = AstType->CompilerType;
typedef ExpressionVariableCallback = (String, SourceSpan, Scope, Null<CompilerType>) -> TypedExpression;
typedef ExpressionLambdaCallback = (Array<AstArgument>, Array<AstStatement>, SourceSpan, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef ExpressionMemberCallback = (AstExpression, String, SourceSpan, Scope) -> TypedExpression;
typedef ExpressionBlockCallback = (Array<AstStatement>, AstExpression, SourceSpan, Scope, Null<CompilerType>) -> TypedExpression;
typedef ExpressionMethodCallCallback = (AstExpression, String, Array<AstExpression>, SourceSpan, Scope, Null<CompilerType>) -> TypedExpression;

typedef ExpressionDispatchRules = {
	variable:ExpressionVariableCallback,
	lambda:ExpressionLambdaCallback,
	member:ExpressionMemberCallback,
	block:ExpressionBlockCallback,
	methodCall:ExpressionMethodCallCallback,
	contextualType:ContextualExpressionTypeCallback
};

typedef ExpressionSwitchPattern = {
	value:TypedExpression,
	enumName:String,
	index:Int,
	bindings:Array<TypedSwitchBinding>,
	predicates:Array<TypedSwitchPredicate>
};

typedef ExpressionSwitchRules = {
	subjectBinding:(AstExpression, CompilerType, Scope) -> Null<String>,
	catchAll:AstExpression->Bool,
	enumPattern:(AstExpression, CompilerType, Scope) -> Null<ExpressionSwitchPattern>,
	arrayPattern:ExpressionSwitchArrayPatternCallback,
	arrayPatternKey:ExpressionSwitchArrayPatternKeyCallback,
	caseKey:(TypedExpression, Array<TypedSwitchPredicate>) -> Null<String>,
	enumCaseCovered:(CompilerType, Int, Array<TypedSwitchCoverageCase>) -> Bool,
	enumLiteral:TypedExpression->Null<{name:String, index:Int}>,
	isEnum:CompilerType->Bool,
	isNullableEnum:CompilerType->Bool,
	enumName:CompilerType->Null<String>
};

/** Dispatches source expressions and owns their expression-specific typing rules. */
class ExpressionTyper {
	final session:TypingSession;
	final conversionResolver:ConversionResolver;
	final callResolver:CallResolver;
	final typeExpressionCallback:ExpressionTypeCallback;
	final coerce:ExpressionCoerceCallback;
	final switchRules:ExpressionSwitchRules;
	final anonymousTypeRegistry:AnonymousTypeRegistry;
	final arrayElementType:ExpressionArrayElementTypeCallback;
	final lowerType:LowerExpressionTypeCallback;
	final dispatchRules:ExpressionDispatchRules;

	public function new(session:TypingSession, conversionResolver:ConversionResolver, callResolver:CallResolver, typeExpression:ExpressionTypeCallback,
			coerce:ExpressionCoerceCallback, switchRules:ExpressionSwitchRules, anonymousTypeRegistry:AnonymousTypeRegistry,
			arrayElementType:ExpressionArrayElementTypeCallback, lowerType:LowerExpressionTypeCallback, dispatchRules:ExpressionDispatchRules) {
		this.session = session;
		this.conversionResolver = conversionResolver;
		this.callResolver = callResolver;
		this.typeExpressionCallback = typeExpression;
		this.coerce = coerce;
		this.switchRules = switchRules;
		this.anonymousTypeRegistry = anonymousTypeRegistry;
		this.arrayElementType = arrayElementType;
		this.lowerType = lowerType;
		this.dispatchRules = dispatchRules;
	}

	/** Dispatches each source expression to its focused typing rule or semantic resolver. */
	public function typeExpression(expression:AstExpression, scope:Scope, ?expectedType:CompilerType, inferDynamicLambdaResult:Bool = false):TypedExpression
		return switch expression {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_), EmptyExpression(_),
				ErrorExpression(_):
				typeLiteral(expression, expectedType);
			case Variable(name, span): dispatchRules.variable(name, span, scope, expectedType);
			case Lambda(arguments, body, span): dispatchRules.lambda(arguments, body, span, scope, expectedType, inferDynamicLambdaResult);
			case Member(object, name, span): dispatchRules.member(object, name, span, scope);
			case Add(left, right, span): arithmetic(left, right, scope, true, span, expectedType);
			case Sub(left, right, span): arithmetic(left, right, scope, false, span, expectedType);
			case Mul(left, right, span): numeric(left, right, scope, 2, span);
			case Div(left, right, span): numeric(left, right, scope, 3, span);
			case Mod(left, right, span): modulo(left, right, scope, span);
			case BitAnd(left, right, span): bitwise(left, right, scope, 0, span);
			case BitXor(left, right, span): bitwise(left, right, scope, 1, span);
			case BitOr(left, right, span): bitwise(left, right, scope, 2, span);
			case ShiftLeft(left, right, span): bitwise(left, right, scope, 3, span);
			case ShiftRight(left, right, span): bitwise(left, right, scope, 4, span);
			case UnsignedShiftRight(left, right, span): bitwise(left, right, scope, 5, span);
			case Negate(value, span): negate(value, span, scope, expectedType);
			case Less(left, right, span): comparison(left, right, scope, 0, span);
			case LessEqual(left, right, span): comparison(left, right, scope, 1, span);
			case Greater(left, right, span): comparison(right, left, scope, 0, span);
			case GreaterEqual(left, right, span): comparison(right, left, scope, 1, span);
			case Equal(left, right, span): comparison(left, right, scope, 2, span);
			case NotEqual(left, right, span): new TypedExpression(TNot(comparison(left, right, scope, 2, span)), TBool, span);
			case Not(value, span): logicalNot(value, span, scope);
			case And(left, right, span): logical(left, right, scope, true, span);
			case Or(left, right, span): logical(left, right, scope, false, span);
			case Conditional(predicate, whenTrue, whenFalse, span):
				typeConditional(predicate, whenTrue, whenFalse, span, scope, expectedType, dispatchRules.contextualType);
			case BlockExpression(statements, result, span): dispatchRules.block(statements, result, span, scope, expectedType);
			case ThrowExpression(value, span): throwExpression(value, span, scope);
			case Cast(value, target, span): typeCast(value, target, span, scope, expectedType, lowerType);
			case PostfixIncrement(target, delta, span): postfixIncrement(target, delta, span, scope);
			case SwitchExpression(subject, cases, defaultExpression, span): typeSwitchExpression(subject, cases, defaultExpression, span, scope, expectedType);
			case ObjectLiteral(fields, span): typeObjectLiteral(fields, span, scope, expectedType);
			case ArrayLiteral(values, span): typeArrayLiteral(values, span, scope, expectedType);
			case MapLiteral(entries, span): typeMapLiteral(entries, span, scope, expectedType);
			case ArrayComprehension(keyName, valueName, iterable, predicate, value, span):
				typeArrayComprehension(keyName, valueName, iterable, predicate, value, span, scope, expectedType);
			case MapComprehension(keyName, valueName, iterable, predicate, key, value, span):
				typeMapComprehension(keyName, valueName, iterable, predicate, key, value, span, scope, expectedType);
			case Range(start, rangeEnd, span): typeRange(start, rangeEnd, span, scope);
			case NativeLayoutQuery(kind, type, field, span): typeNativeLayoutQuery(kind, type, field, span);
			case NewGeneric(typeName, typeArguments, arguments, span):
				callResolver.typeConstruction(typeName, typeArguments, arguments, span, scope, expectedType, true);
			case New(typeName, arguments, span): callResolver.typeConstruction(typeName, [], arguments, span, scope, expectedType, false);
			case NewArray(element, length, span): typeNewArray(element, length, span, scope, lowerType);
			case NewMap(key, value, span): typeNewMap(key, value, span, lowerType);
			case Index(array, offset, span): typeIndex(array, offset, span, scope);
			case Call(name, arguments, span):
				var rawPointerCall = callResolver.typeRawPointerNullCall(name, arguments, span, expectedType);
				if (rawPointerCall != null)
					return rawPointerCall;
				if (name == "super")
					return callResolver.typeSuperCall(arguments, span, scope);
				var runtimeDataCall = callResolver.typeRuntimeDataCall(name, arguments, span, scope);
				if (runtimeDataCall != null)
					return runtimeDataCall;
				var builtinCall = callResolver.typeBuiltinCall(name, arguments, span, scope, expectedType);
				if (builtinCall != null)
					return builtinCall;
				callResolver.typeNamedCall(name, arguments, span, scope, expectedType);
			case ClosureCall(callee, arguments, span): callResolver.typeClosureCall(callee, arguments, span, scope);
			case MethodCall(object, name, arguments, span):
				var call = dispatchRules.methodCall(object, name, arguments, span, scope, expectedType);
				scope.invalidateAllExpressions();
				call;
		};

	function typeNativeLayoutQuery(kind:compiler.syntax.Ast.NativeLayoutQueryKind, type:AstType, field:Null<String>, span:SourceSpan):TypedExpression {
		var resolved = session.declarations.resolve(type, span, session.currentContext.typeSubstitutions), size:Int;
		switch resolved {
			case TInstance(NominalKind.NativeValue, name, _):
				var layout = session.nativeLayoutsByName.get(name);
				if (layout == null)
					fail("E1022", 'Native value "$name" has no layout for ABI target "${session.nativeAbiTarget}"', span);
				switch kind {
					case SizeOf: size = layout.size;
					case AlignOf: size = layout.alignment;
					case OffsetOf:
						if (field == null)
							fail("E1022", "offsetof requires a field name", span);
						var found:Null<Int> = null;
						for (candidate in layout.fields)
							if (candidate.name == field)
								found = candidate.offset;
						if (found == null)
							fail("E1022", 'Native value "$name" has no field "$field"', span);
						size = cast found;
				}
			case _:
				if (kind == OffsetOf)
					fail("E1022", "offsetof requires a native value record type", span);
				var hxiType = try NativeLayout.fieldType(resolved) catch (_:Dynamic) {
					fail("E1022", 'Type "$resolved" has no fixed native ABI layout', span);
					cast null;
				},
					layout = HxiAbi.forTarget(session.nativeAbiTarget).layout(hxiType);
				if (layout == null)
					fail("E1022", 'Type "$resolved" has no fixed native ABI layout for "${session.nativeAbiTarget}"', span);
				size = switch kind {
					case SizeOf: layout.size;
					case AlignOf: layout.align;
					case OffsetOf: 0;
				};
		}
		return new TypedExpression(TIntLiteral(size), TInt, span);
	}

	public function typeObjectLiteral(fields:Array<AstObjectField>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var objectExpected = objectLiteralExpectation(expectedType),
			expectedFields = anonymousFields(objectExpected),
			seen:Map<String, Bool> = [],
			typedFields:Array<TypedObjectField> = [];
		for (field in fields) {
			if (seen.exists(field.name))
				fail("E1001", 'Duplicate object field "${field.name}"', field.span);
			seen.set(field.name, true);
			var expectedField = anonymousField(expectedFields, field.name);
			if (expectedFields != null && expectedField == null)
				fail("E1002", 'Unexpected object field "${field.name}"', field.span);
			var value = typeExpressionCallback(field.value, scope, expectedField == null ? null : expectedField.type, false);
			if (expectedField != null)
				value = coerce(value, expectedField.type, 'object field "${field.name}"', "E1002");
			else if (value.type == TNull)
				value = coerce(value, TDynamic, 'object field "${field.name}"', "E1002");
			typedFields.push({name: field.name, value: value});
		}
		if (expectedFields != null)
			for (field in expectedFields)
				if (!field.optional && !seen.exists(field.name))
					fail("E1002", 'Missing object field "${field.name}"', span);
		var resolvedResult:CompilerType;
		if (objectExpected == null) {
			var inferred:Array<AnonymousField> = [
				for (field in typedFields)
					{name: field.name, type: field.value.type, optional: false}
			];
			inferred.sort(function(left, right) return Reflect.compare(left.name, right.name));
			resolvedResult = TAnonymous(anonymousTypeName(inferred), inferred);
		} else
			resolvedResult = objectExpected;
		var typeName = switch resolvedResult {
			case TAnonymous(name, _): name;
			default: "";
		};
		anonymousTypeRegistry.register(resolvedResult);
		return new TypedExpression(TObjectLiteral(typeName, typedFields), resolvedResult, span);
	}

	public function typeArrayLiteral(values:Array<AstExpression>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var expectedMap = mapExpectation(expectedType);
		if (values.length == 0 && expectedMap != null)
			return new TypedExpression(TMapLiteral([]), TMap(expectedMap.key, expectedMap.value), span);
		var expectedElement = arrayElementExpectation(expectedType);
		if (values.length == 0 && expectedElement == null)
			fail("E1003", "Empty array literal requires an expected element type", span);
		var typedValues:Array<TypedExpression> = [],
			elementType = expectedElement;
		for (value in values) {
			var typedValue = typeExpressionCallback(value, scope, elementType, false),
				resolvedElement:CompilerType;
			if (elementType == null) {
				resolvedElement = typedValue.type;
				elementType = resolvedElement;
			} else
				resolvedElement = elementType;
			typedValues.push(coerce(typedValue, resolvedElement, "array element", "E1003"));
		}
		if (elementType == null)
			throw "Array element type was not resolved";
		return new TypedExpression(TArrayLiteral(typedValues), TArray(elementType), span);
	}

	public function typeMapLiteral(entries:Array<AstMapEntry>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var expected = mapExpectation(expectedType),
			keyType = expected == null ? null : expected.key,
			valueType = expected == null ? null : expected.value,
			typedEntries:Array<TypedMapEntry> = [];
		for (entry in entries) {
			var key = typeExpressionCallback(entry.key, scope, keyType, false),
				value = typeExpressionCallback(entry.value, scope, valueType, false),
				resolvedKey:CompilerType,
				resolvedValue:CompilerType;
			if (keyType == null) {
				resolvedKey = key.type;
				keyType = resolvedKey;
			} else
				resolvedKey = keyType;
			if (valueType == null) {
				resolvedValue = value.type;
				valueType = resolvedValue;
			} else
				resolvedValue = valueType;
			typedEntries.push({key: coerce(key, resolvedKey, "map key", "E1003"), value: coerce(value, resolvedValue, "map value", "E1003")});
		}
		if (keyType == null || valueType == null)
			throw "Map key/value types were not resolved";
		if (session.mapName(keyType, valueType) == null)
			fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
		return new TypedExpression(TMapLiteral(typedEntries), TMap(keyType, valueType), span);
	}

	public function typeArrayComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, predicate:Null<AstExpression>, value:AstExpression,
			span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedIterable = typeExpressionCallback(iterable, scope, null, false),
			originalIterable = typedIterable,
			loopScope = new Scope(scope),
			keyType:Null<CompilerType> = null;
		switch typedIterable.type {
			case TArray(element):
				if (valueName != null)
					fail("E1014", "Key/value array comprehension requires a Map", span);
				keyType = element;
			case TIterator(element):
				if (valueName != null)
					fail("E1014", "Key/value array comprehension requires a Map", span);
				keyType = element;
			case TRange:
				if (valueName != null)
					fail("E1014", "Key/value array comprehension requires a Map", span);
				keyType = TInt;
			case TMap(key, mapValue):
				if (session.mapName(key, mapValue) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				keyType = valueName == null ? mapValue : key;
				if (valueName == null)
					typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(mapValue), span);
			default:
				fail("E1014", "Array comprehension iterable must be an Array, Iterator, or Map", span);
		}
		if (keyType == null)
			throw "Array comprehension item type was not resolved";
		loopScope.define(keyName, keyType, span);
		if (valueName != null)
			switch originalIterable.type {
				case TMap(_, mapValue):
					loopScope.define(valueName, mapValue, span);
				default:
			}
		var map = valueName == null ? CallResolver.mapKeyIteratorSource(originalIterable) : null;
		if (map == null)
			map = valueName == null ? FlowAnalysis.mapKeySource(originalIterable, scope) : null;
		if (valueName == null) {
			if (map != null) {
				var key = new TypedExpression(TLocal(loopScope.requireId(keyName)), keyType, span),
					entryPath = FlowAnalysis.mapEntryPath(map, key);
				if (entryPath != null)
					switch map.type {
						case TMap(_, value):
							loopScope.refineExpression(entryPath, value);
						default:
					}
			}
		}
		var typedCondition = predicate == null ? null : typeExpressionCallback(predicate, loopScope, TBool, false);
		if (typedCondition != null && typedCondition.type != TBool)
			fail("E1004", "Array comprehension condition must be Bool", span);
		var expectedElement = arrayElementExpectation(expectedType),
			typedValue = typeExpressionCallback(value, loopScope, expectedElement, false),
			flattenedElement = switch typedValue.expression {
				case TArrayComprehension(_, _, _, _, _): arrayElementType(typedValue.type, span);
				case _: null;
			},
			elementType = expectedElement == null ? (flattenedElement == null ? typedValue.type : flattenedElement) : expectedElement;
		if (flattenedElement == null)
			typedValue = coerce(typedValue, elementType, "array comprehension value", "E1003");
		return new TypedExpression(TArrayComprehension(loopScope.requireId(keyName), valueName == null ? null : loopScope.requireId(valueName),
			valueName == null ? typedIterable : originalIterable, typedCondition, typedValue),
			TArray(elementType), span, false, map);
	}

	public function typeMapComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, predicate:Null<AstExpression>, key:AstExpression,
			value:AstExpression, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedIterable = typeExpressionCallback(iterable, scope, null, false),
			originalIterable = typedIterable,
			loopScope = new Scope(scope),
			itemType:Null<CompilerType> = null;
		switch typedIterable.type {
			case TArray(element):
				if (valueName != null)
					fail("E1014", "Key/value map comprehension requires a Map", span);
				itemType = element;
			case TIterator(element):
				if (valueName != null)
					fail("E1014", "Key/value map comprehension requires a Map", span);
				itemType = element;
			case TRange:
				if (valueName != null)
					fail("E1014", "Key/value map comprehension requires a Map", span);
				itemType = TInt;
			case TMap(mapKey, mapValue):
				if (session.mapName(mapKey, mapValue) == null)
					fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
				itemType = valueName == null ? mapValue : mapKey;
				if (valueName == null)
					typedIterable = new TypedExpression(TCollectionCall(typedIterable, "values", []), TArray(mapValue), span);
			default:
				fail("E1014", "Map comprehension iterable must be an Array, Iterator, or Map", span);
		}
		if (itemType == null)
			throw "Map comprehension item type was not resolved";
		loopScope.define(keyName, itemType, span);
		if (valueName != null)
			switch originalIterable.type {
				case TMap(_, mapValue):
					loopScope.define(valueName, mapValue, span);
				default:
			}
		var typedCondition = predicate == null ? null : typeExpressionCallback(predicate, loopScope, TBool, false);
		if (typedCondition != null && typedCondition.type != TBool)
			fail("E1004", "Map comprehension condition must be Bool", span);
		var expected = mapExpectation(expectedType),
			typedKey = typeExpressionCallback(key, loopScope, expected == null ? null : expected.key, false),
			typedValue = typeExpressionCallback(value, loopScope, expected == null ? null : expected.value, false),
			resultKey = expected == null ? typedKey.type : expected.key,
			resultValue = expected == null ? typedValue.type : expected.value;
		typedKey = coerce(typedKey, resultKey, "map comprehension key", "E1003");
		typedValue = coerce(typedValue, resultValue, "map comprehension value", "E1003");
		if (session.mapName(resultKey, resultValue) == null)
			fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
		return new TypedExpression(TMapComprehension(loopScope.requireId(keyName), valueName == null ? null : loopScope.requireId(valueName),
			valueName == null ? typedIterable : originalIterable, typedCondition, typedKey, typedValue),
			TMap(resultKey, resultValue), span);
	}

	public function typeRange(start:AstExpression, rangeEnd:AstExpression, span:SourceSpan, scope:Scope):TypedExpression {
		var typedStart = typeExpressionCallback(start, scope, TInt, false),
			typedEnd = typeExpressionCallback(rangeEnd, scope, TInt, false);
		if (typedStart.type != TInt || typedEnd.type != TInt) {
			if (!session.tolerant)
				fail("E1014", "Range bounds must be Int values", span);
			session.rememberRecoveryDiagnostic(new Diagnostic("E1014", "Range bounds must be Int values", span));
			if (typedStart.type != TInt)
				typedStart = recoveredError(typedStart.span);
			if (typedEnd.type != TInt)
				typedEnd = recoveredError(typedEnd.span);
		}
		return new TypedExpression(TRange(typedStart, typedEnd), TRange, span);
	}

	public function typeIndex(array:AstExpression, offset:AstExpression, span:SourceSpan, scope:Scope):TypedExpression {
		var typedArray = unwrapNullable(typeExpressionCallback(array, scope, null, false)),
			typedIndex = typeExpressionCallback(offset, scope, null, false);
		return switch typedArray.type {
			case TMap(key, value):
				if (session.mapName(key, value) == null) {
					if (!session.tolerant)
						fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
					session.rememberRecoveryDiagnostic(new Diagnostic("E1016", "This map key/value type has no compiler-owned runtime ABI", span));
				}
				var typedKey = recoverCoerce(typedIndex, key, "map key", "E1002"),
					entryPath = FlowAnalysis.mapEntryPath(typedArray, typedKey),
					refined = entryPath == null ? null : scope.resolveExpression(entryPath);
				new TypedExpression(TMapGet(typedArray, typedKey), refined == null ? CallResolver.nullableMapValue(value) : refined, span);
			default:
				if (typedIndex.type == TNever)
					typedIndex = recoverCoerce(typedIndex, TInt, "array index", "E1014");
				if (typedIndex.type != TInt) {
					if (!session.tolerant)
						fail("E1014", "Array index must be Int", typedIndex.span);
					session.rememberRecoveryDiagnostic(new Diagnostic("E1014", "Array index must be Int", typedIndex.span));
					typedIndex = recoveredError(typedIndex.span);
				}
				var element = switch typedArray.type {
					case TArray(value): value;
					case TUnknown, TError: TUnknown;
					default: arrayElementType(typedArray.type, span);
				};
				new TypedExpression(TIndex(typedArray, typedIndex), element, span);
		};
	}

	public function typeNewArray(element:AstType, length:AstExpression, span:SourceSpan, scope:Scope, lowerType:LowerExpressionTypeCallback):TypedExpression {
		var typedLength = typeExpressionCallback(length, scope, null, false);
		if (typedLength.type != TInt) {
			if (!session.tolerant)
				fail("E1014", "Array length must be Int", typedLength.span);
			session.rememberRecoveryDiagnostic(new Diagnostic("E1014", "Array length must be Int", typedLength.span));
			typedLength = recoveredError(typedLength.span);
		}
		var loweredElement = lowerType(element);
		return new TypedExpression(TNewArray(loweredElement, typedLength), TArray(loweredElement), span);
	}

	public function typeNewMap(key:AstType, value:AstType, span:SourceSpan, lowerType:LowerExpressionTypeCallback):TypedExpression {
		var loweredKey = lowerType(key), loweredValue = lowerType(value);
		if (session.mapName(loweredKey, loweredValue) == null) {
			if (!session.tolerant)
				fail("E1016", "This map key/value type has no compiler-owned runtime ABI", span);
			session.rememberRecoveryDiagnostic(new Diagnostic("E1016", "This map key/value type has no compiler-owned runtime ABI", span));
		}
		return new TypedExpression(TNewMap(loweredKey, loweredValue), TMap(loweredKey, loweredValue), span);
	}

	public function typeSwitchExpression(expression:AstExpression, cases:Array<AstSwitchExpressionCase>, defaultExpression:Null<AstExpression>,
			span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedSubject = typeExpressionCallback(expression, scope, null, false);
		if (!sameType(typedSubject.type, TInt)
			&& !sameType(typedSubject.type, TString)
			&& !isNullableString(typedSubject.type)
			&& !isArraySwitchable(typedSubject.type)
			&& !switchRules.isEnum(typedSubject.type))
			fail("E1019", "Switch requires an Int, String, array, or enum value", typedSubject.span);
		var typedCases:Array<TypedSwitchExpressionCase> = [],
			deferredCaseResults:Map<Int, {expression:AstExpression, scope:Scope}> = [],
			deferredDefault:Null<{expression:AstExpression, scope:Scope}> = null,
			seenCases:Map<String, Bool> = [],
			resultType = expectedType,
			defaultScope = new Scope(scope),
			typedDefault:Null<TypedExpression> = null;
		if (defaultExpression != null) {
			if (expectedType == null && isEmptyArrayLiteral(defaultExpression))
				deferredDefault = {expression: defaultExpression, scope: defaultScope};
			else
				typedDefault = typeExpressionCallback(defaultExpression, defaultScope, expectedType, false);
		}
		// A switch arm can need the inferred result type to resolve an enum constructor
		// (for example, `case A: SomeConstructor(...); default: value;`). Seed that
		// context from the fallback before typing the arms; the normal branch join below
		// still permits widening and nullable results.
		if (expectedType == null && typedDefault != null && typedDefault.type != TNever)
			resultType = typedDefault.type;
		for (switchCase in cases) {
			var caseScope = new Scope(scope),
				subjectBinding = switchRules.subjectBinding(switchCase.value, typedSubject.type, caseScope),
				isCatchAll = switchRules.catchAll(switchCase.value),
				arrayPattern = subjectBinding == null ? switchRules.arrayPattern(switchCase.value, typedSubject.type, caseScope) : null,
				pattern = subjectBinding == null
					&& arrayPattern == null ? switchRules.enumPattern(switchCase.value, typedSubject.type, caseScope) : null,
				typedValue = isCatchAll
					|| subjectBinding != null
					|| arrayPattern != null ? typedSubject : pattern == null ? coerce(typeExpressionCallback(switchCase.value, scope, typedSubject.type,
						false), typedSubject.type, "switch case", "E1019") : pattern.value;
			var parsedGuard = switchCase.guard,
				typedGuard = parsedGuard == null ? null : coerce(typeExpressionCallback(parsedGuard, caseScope, null, false), TBool, "switch guard", "E1003"),
				caseIndex = typedCases.length,
				typedResult:TypedExpression;
			if (typedGuard != null)
				caseScope = FlowAnalysis.narrowedScope(caseScope, typedGuard, true);
			if (expectedType == null && resultType == null && isEmptyArrayLiteral(switchCase.result)) {
				deferredCaseResults.set(caseIndex, {expression: switchCase.result, scope: caseScope});
				typedResult = new TypedExpression(TUnreachable, TNever, switchCase.span);
			} else
				typedResult = typeExpressionCallback(switchCase.result, caseScope, expectedType == null ? resultType : expectedType, false);
			var enumName:Null<String> = pattern == null ? null : pattern.enumName,
				constructorIndex = pattern == null ? -1 : pattern.index,
				predicates:Array<TypedSwitchPredicate> = pattern == null ? [] : pattern.predicates;
			if (expectedType == null && typedResult.type != TNever) {
				var joined = resultType == null ? typedResult.type : commonConditionalType(resultType, typedResult.type);
				if (joined == null)
					fail("E1003", "Switch branches must have matching types", switchCase.span);
				resultType = joined;
			}
			if (pattern == null) {
				var literal = switchRules.enumLiteral(typedValue);
				if (literal != null) {
					enumName = literal.name;
					constructorIndex = literal.index;
				}
			}
			var caseKey = arrayPattern == null ? switchRules.caseKey(typedValue, predicates) : switchRules.arrayPatternKey(arrayPattern);
			if (isCatchAll || subjectBinding != null)
				seenCases.set("$catchall", true);
			if (caseKey != null && typedGuard == null) {
				if (seenCases.exists(caseKey))
					fail("E1020", "Duplicate switch case", switchCase.span);
				seenCases.set(caseKey, true);
			}
			typedCases.push({
				value: typedValue,
				subjectBinding: subjectBinding,
				arrayPattern: arrayPattern,
				span: switchCase.span,
				isCatchAll: isCatchAll,
				guard: typedGuard,
				result: typedResult,
				enumName: enumName,
				constructorIndex: constructorIndex,
				bindings: pattern == null ? [] : pattern.bindings,
				predicates: predicates
			});
		}
		if (typedDefault != null && expectedType == null && typedDefault.type != TNever) {
			var joined = resultType == null ? typedDefault.type : commonConditionalType(resultType, typedDefault.type);
			if (joined == null)
				fail("E1003", "Switch branches must have matching types", span);
			resultType = joined;
		}
		if (resultType == null)
			fail("E1003", "Switch expression has no result branches", span);
		typedCases = [
			for (index in 0...typedCases.length) {
				var switchCase = typedCases[index],
					deferred = deferredCaseResults.get(index),
					result = deferred == null ? switchCase.result : typeExpressionCallback(deferred.expression, deferred.scope, resultType, false);
				{
					value: switchCase.value,
					subjectBinding: switchCase.subjectBinding,
					arrayPattern: switchCase.arrayPattern,
					span: switchCase.span,
					isCatchAll: switchCase.isCatchAll,
					guard: switchCase.guard,
					result: coerce(result, resultType, "switch branch", "E1003"),
					enumName: switchCase.enumName,
					constructorIndex: switchCase.constructorIndex,
					bindings: switchCase.bindings,
					predicates: switchCase.predicates
				}
			}
		];
		if (deferredDefault != null)
			typedDefault = typeExpressionCallback(deferredDefault.expression, deferredDefault.scope, resultType, false);
		if (typedDefault != null)
			typedDefault = coerce(typedDefault, resultType, "switch branch", "E1003");
		if (typedDefault == null && !switchRules.isEnum(typedSubject.type) && !seenCases.exists("$catchall"))
			fail("E1021", "Switch expression requires a default branch", span);
		if (switchRules.isEnum(typedSubject.type) && typedDefault == null && !seenCases.exists("$catchall")) {
			var resolvedEnumName = Std.string(switchRules.enumName(typedSubject.type)),
				missing:Array<String> = [],
				coverageCases:Array<TypedSwitchCoverageCase> = [
					for (switchCase in typedCases)
						{
							constructorIndex: switchCase.constructorIndex,
							subjectBinding: switchCase.subjectBinding,
							isCatchAll: switchCase.isCatchAll,
							guard: switchCase.guard,
							predicates: switchCase.predicates
						}
				];
			if (session.enumDecls.exists(resolvedEnumName)) {
				var enumDecl = session.enumDecls.get(resolvedEnumName);
				for (index in 0...enumDecl.cases.length)
					if (!seenCases.exists('enum:$resolvedEnumName:$index')
						&& !switchRules.enumCaseCovered(typedSubject.type, index, coverageCases))
						missing.push(enumDecl.cases[index].name);
			}
			if (switchRules.isNullableEnum(typedSubject.type) && !seenCases.exists("null"))
				missing.push("null");
			if (missing.length > 0)
				fail("E1021", 'Enum switch is missing cases: ${missing.join(", ")}', span);
		}
		return new TypedExpression(TSwitchExpression(typedSubject, typedCases, typedDefault), resultType, span);
	}

	static function isEmptyArrayLiteral(expression:AstExpression):Bool
		return switch expression {
			case ArrayLiteral(values, _): values.length == 0;
			default: false;
		};

	static function isNullableString(type:CompilerType):Bool
		return switch type {
			case TNullable(TString): true;
			default: false;
		};

	static function isArraySwitchable(type:CompilerType):Bool
		return switch type {
			case TArray(_): true;
			default: false;
		};

	public function typeConditional(predicate:AstExpression, whenTrue:AstExpression, whenFalse:AstExpression, span:SourceSpan, scope:Scope,
			expectedType:Null<CompilerType>, contextualExpressionType:ContextualExpressionTypeCallback):TypedExpression {
		var typedCondition = typeExpressionCallback(predicate, scope, TBool, false);
		var invalidCondition = !sameType(typedCondition.type, TBool);
		if (invalidCondition) {
			if (!session.tolerant)
				fail("E1011", "Conditional expression requires a Bool condition", span);
			session.rememberRecoveryDiagnostic(new Diagnostic("E1011", "Conditional expression requires a Bool condition", span));
		}
		// A failed predicate must not prevent either branch from being typed. In
		// recovery mode there is no sound narrowing to apply, but each branch
		// still contributes useful result and expected-type information.
		var trueScope = invalidCondition ? new Scope(scope) : FlowAnalysis.narrowedScope(scope, typedCondition, true),
			falseScope = invalidCondition ? new Scope(scope) : FlowAnalysis.narrowedScope(scope, typedCondition, false),
			contextualType = expectedType;
		if (contextualType == null) {
			contextualType = contextualExpressionType(whenTrue, trueScope);
			if (contextualType == null)
				contextualType = contextualExpressionType(whenFalse, falseScope);
			if (contextualType != null
				&& !isNullable(contextualType)
				&& contextualType != TNull
				&& (containsNullLiteral(whenTrue) || containsNullLiteral(whenFalse)))
				contextualType = TNullable(contextualType);
		}
		var typedTrue = typeExpressionCallback(whenTrue, trueScope, contextualType, false),
			branchExpected = expectedType == null
				&& typedTrue.type != TNull
				&& typedTrue.type != TNever ? (containsNullLiteral(whenFalse) ? CompilerType.TNullable(typedTrue.type) : typedTrue.type) : expectedType,
			typedFalse = typeExpressionCallback(whenFalse, falseScope, branchExpected, false),
			resultType = expectedType == null ? commonConditionalType(typedTrue.type, typedFalse.type) : expectedType;
		if (resultType == null)
			fail("E1003", "Conditional branches must have matching types", span);
		typedTrue = coerce(typedTrue, resultType, "conditional branch", "E1003");
		typedFalse = coerce(typedFalse, resultType, "conditional branch", "E1003");
		return new TypedExpression(TConditional(typedCondition, typedTrue, typedFalse), resultType, span);
	}

	public function typeCast(value:AstExpression, target:Null<AstType>, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>,
			lowerType:LowerExpressionTypeCallback):TypedExpression {
		var targetType = target == null ? expectedType : lowerType(target);
		if (targetType == null)
			fail("E1003", "Untyped cast requires an expected type", span);
		return conversionResolver.adaptFunction(typeExpressionCallback(value, scope, null, false), targetType, span);
	}

	public function negate(value:AstExpression, span:SourceSpan, scope:Scope, expectedType:Null<CompilerType>):TypedExpression {
		var typedValue = typeExpressionCallback(value, scope, expectedType == TInt64 ? TInt64 : null, false);
		if (!isNumeric(typedValue.type))
			fail("E1010", "Numeric negation requires an Int, Int64, or Float operand", span);
		return new TypedExpression(TNegate(typedValue), typedValue.type, span);
	}

	public function logicalNot(value:AstExpression, span:SourceSpan, scope:Scope):TypedExpression {
		var typedValue = typeExpressionCallback(value, scope, null, false);
		if (!sameType(typedValue.type, TBool))
			fail("E1011", "Logical negation requires a Bool operand", span);
		return new TypedExpression(TNot(typedValue), TBool, span);
	}

	public function throwExpression(value:AstExpression, span:SourceSpan, scope:Scope):TypedExpression
		return new TypedExpression(TThrowExpression(typeExpressionCallback(value, scope, null, false)), TNever, span);

	public function postfixIncrement(target:AstExpression, delta:Int, span:SourceSpan, scope:Scope):TypedExpression {
		var typedTarget = typeExpressionCallback(target, scope, null, false);
		if (!sameType(typedTarget.type, TInt) && !sameType(typedTarget.type, TFloat))
			fail("E1018", "Postfix increment requires a numeric target", span);
		var operation:TypedExpressionKind = switch typedTarget.expression {
			case TLocal(name): TPostfixLocal(name, delta);
			case TCellLocal(name, cellClass): TPostfixCellLocal(name, cellClass, delta);
			case TCellCaptured(name, cellClass): TPostfixCellCaptured(name, cellClass, delta);
			case TStaticField(owner, name): TPostfixStaticField(owner, name, delta);
			case TField(object, name): TPostfixField(object, name, delta);
			case TIndex(array, index): TPostfixIndex(array, index, delta);
			default:
				fail("E1018", "Postfix increment target is not assignable", span);
				TPostfixLocal("", delta);
		};
		return new TypedExpression(operation, typedTarget.type, span);
	}

	public static function containsNullLiteral(expression:AstExpression):Bool
		return switch expression {
			case NullLiteral(_): true;
			case Conditional(_, whenTrue, whenFalse, _): containsNullLiteral(whenTrue) || containsNullLiteral(whenFalse);
			default: false;
		};

	public function commonConditionalType(left:CompilerType, right:CompilerType):Null<CompilerType> {
		if (left == TNever)
			return right;
		if (right == TNever || sameType(left, right))
			return left;
		if ((left == TInt && right == TFloat) || (left == TFloat && right == TInt))
			return TFloat;
		switch left {
			case TNull:
				return right == TVoid ? null : (isNullable(right) ? right : TNullable(right));
			case TNullable(inner) if (sameType(inner, right)):
				return TNullable(inner);
			default:
		}
		switch right {
			case TNull:
				return left == TVoid ? null : (isNullable(left) ? left : TNullable(left));
			case TNullable(inner) if (sameType(left, inner)):
				return TNullable(inner);
			default:
		}
		if (session.relations.isAssignable(left, right))
			return right;
		if (session.relations.isAssignable(right, left))
			return left;
		return null;
	}

	public function typeLiteral(expression:AstExpression, expectedType:Null<CompilerType>):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span):
				var type = switch expectedType {
					case TInt64: TInt64;
					case TNativeScalar(name) if (name != "f32" && name != "f64"): expectedType;
					case _: TInt;
				};
				new TypedExpression(TIntLiteral(value), type, span);
			case FloatLiteral(value, span):
				var type = switch expectedType {
					case TNativeScalar("f32") | TNativeScalar("f64"): expectedType;
					case _: TFloat;
				};
				new TypedExpression(TFloatLiteral(value), type, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case BoolLiteral(value, span): new TypedExpression(TBoolLiteral(value), TBool, span);
			case NullLiteral(span): new TypedExpression(TNullLiteral, TNull, span);
			case Unreachable(span): new TypedExpression(TUnreachable, TNever, span);
			case EmptyExpression(span): new TypedExpression(TVoidLiteral, TVoid, span);
			case ErrorExpression(span): new TypedExpression(TNullLiteral, session.tolerant ? TError : TDynamic, span);
			default: throw "ExpressionTyper.typeLiteral requires a literal expression";
		};

	public function arithmetic(a:AstExpression, b:AstExpression, scope:Scope, add:Bool, span:SourceSpan, expected:Null<CompilerType>):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		if (expected != null && isNumeric(expected)) {
			if (left.type == TDynamic)
				left = coerce(left, expected, "arithmetic operand", "E1010");
			if (right.type == TDynamic)
				right = coerce(right, expected, "arithmetic operand", "E1010");
		}
		if (left.type == TNever && isNumeric(right.type))
			left = coerce(left, right.type, "arithmetic operand", "E1009");
		if (right.type == TNever && isNumeric(left.type))
			right = coerce(right, left.type, "arithmetic operand", "E1009");
		if (add && (isStringConvertible(left.type) || isStringConvertible(right.type))) {
			left = stringify(left);
			right = stringify(right);
			return new TypedExpression(TAdd(left, right), TString, span);
		}
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span);
		return new TypedExpression(add ? TAdd(promoted.left, promoted.right) : TSub(promoted.left, promoted.right), promoted.type, span);
	}

	public function logical(a:AstExpression, b:AstExpression, scope:Scope, and:Bool, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			rightScope = FlowAnalysis.narrowedScope(scope, left, and),
			right = typeExpressionCallback(b, rightScope, null, false);
		if (!sameType(left.type, TBool) || !sameType(right.type, TBool))
			fail("E1011", "Logical operators require Bool operands", span);
		return new TypedExpression(and ? TAnd(left, right) : TOr(left, right), TBool, span);
	}

	public function numeric(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span, operation != 2);
		return new TypedExpression(operation == 2 ? TMul(promoted.left, promoted.right) : TDiv(promoted.left, promoted.right), promoted.type, span);
	}

	public function modulo(a:AstExpression, b:AstExpression, scope:Scope, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Modulo requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span);
		return sameType(promoted.type, TInt)
			|| sameType(promoted.type,
				TInt64) ? new TypedExpression(TMod(promoted.left, promoted.right), promoted.type,
				span) : new TypedExpression(TCall("__math_fmod", [promoted.left, promoted.right]), TFloat, span);
	}

	public function bitwise(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, null, false);
		if (operation >= 3) {
			if (!sameType(left.type, TInt) && !sameType(left.type, TInt64))
				fail("E1010", "Shift operators require an Int or Int64 value", span);
			if (!sameType(right.type, TInt))
				fail("E1010", "Shift counts must be Int values", span);
			var shift:TypedExpressionKind = switch operation {
				case 3: TShiftLeft(left, right);
				case 4: TShiftRight(left, right);
				default: TUnsignedShiftRight(left, right);
			};
			return new TypedExpression(shift, left.type, span);
		}

		if ((!sameType(left.type, TInt) && !sameType(left.type, TInt64)) || (!sameType(right.type, TInt) && !sameType(right.type, TInt64)))
			fail("E1010", "Bitwise operators require integer operands", span);
		var operandType = sameType(left.type, TInt64) || sameType(right.type, TInt64) ? TInt64 : TInt;
		left = coerce(left, operandType, "bitwise operand", "E1010");
		right = coerce(right, operandType, "bitwise operand", "E1010");
		var expression:TypedExpressionKind = switch operation {
			case 0: TBitAnd(left, right);
			case 1: TBitXor(left, right);
			case 2: TBitOr(left, right);
			default: throw "Unknown bitwise operation";
		};
		return new TypedExpression(expression, operandType, span);
	}

	public function comparison(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpressionCallback(a, scope, null, false),
			right = typeExpressionCallback(b, scope, left.type, false);
		if (operation == 2
			&& ((sameType(left.type, TNull) && !isNullable(right.type) && right.type != TNull && !TypeRelations.isReference(right.type))
				|| (sameType(right.type, TNull) && !isNullable(left.type) && left.type != TNull && !TypeRelations.isReference(left.type))))
			return new TypedExpression(TBoolLiteral(false), TBool, span);
		if (operation == 2) {
			if (sameType(left.type, TNull) && isNullable(right.type))
				left = coerce(left, right.type, "null comparison", "E1009");
			else if (sameType(right.type, TNull) && isNullable(left.type))
				right = coerce(right, left.type, "null comparison", "E1009");
		}
		if (operation == 2 && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && sameType(left.type, TBool) && sameType(right.type, TBool))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && session.relations.isAssignable(left.type, right.type)) {
			left = coerce(left, right.type, "equality comparison", "E1011");
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && session.relations.isAssignable(right.type, left.type)) {
			right = coerce(right, left.type, "equality comparison", "E1011");
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2
			&& ((sameType(left.type, TNull) && TypeRelations.isReference(right.type))
				|| (sameType(right.type, TNull) && TypeRelations.isReference(left.type)))) {
			if (sameType(left.type, TNull))
				left = new TypedExpression(TNullableWrap(left), right.type, left.span);
			else
				right = new TypedExpression(TNullableWrap(right), left.type, right.span);
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && (sameType(left.type, TNull) || sameType(right.type, TNull))) {
			var nullableComparison = switch left.type {
				case TNull:
					switch right.type {
						case TNullable(_): true;
						default: false;
					}
				case TNullable(_):
					switch right.type {
						case TNull, TNullable(_): true;
						default: false;
					}
				default: false;
			};
			if (nullableComparison)
				return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && sameType(left.type, right.type))
			switch left.type {
				case TDynamic, TNativeAbstract(_), TAbstract(_, _, _), TInstance(Class, _, []), TInstance(Interface, _, []), TInstance(Enum, _, _),
					TNullable(_), TArray(_), TIterator(_), TMap(_, _), TFunction(_, _), TAnonymous(_, _):
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
		if (!isNumeric(left.type) || !isNumeric(right.type)) {
			fail("E1011", "Comparison requires matching numeric operands", span);
		}
		var promoted = promoteNumericOperands(left, right, span);
		left = promoted.left;
		right = promoted.right;
		return new TypedExpression(switch operation {
			case 0: TLess(left, right);
			case 1: TLessEqual(left, right);
			default: TEqual(left, right);
		}, TBool, span);
	}

	public function isNumeric(type:CompilerType):Bool
		return sameType(type, TInt) || sameType(type, TInt64) || sameType(type, TFloat);

	function promoteNumericOperands(left:TypedExpression, right:TypedExpression, span:SourceSpan, forceFloat:Bool = false):{
		left:TypedExpression,
		right:TypedExpression,
		type:CompilerType
	} {
		var hasInt64 = sameType(left.type, TInt64) || sameType(right.type, TInt64);
		var hasFloat = sameType(left.type, TFloat) || sameType(right.type, TFloat);
		if (hasInt64 && hasFloat)
			fail("E1010", "Int64 and Float arithmetic requires an explicit conversion", span);
		var type = hasInt64 ? TInt64 : forceFloat || hasFloat ? TFloat : TInt;
		return {left: coerce(left, type, "numeric operand", "E1010"), right: coerce(right, type, "numeric operand", "E1010"), type: type};
	}

	function isStringConvertible(type:CompilerType):Bool
		return switch type {
			case TString: true;
			case TAbstract(_, _, _): session.relations.isAssignable(type, TString);
			default: false;
		};

	function stringify(value:TypedExpression):TypedExpression {
		if (isStringConvertible(value.type))
			return coerce(value, TString, "string concatenation", "E1010");
		if (sameType(value.type, TFloat) || sameType(value.type, TDynamic)) {
			session.runtimeDependencyTracker.record(session.currentContext.name, "Std");
			var dynamicValue = coerce(value, TDynamic, "string concatenation", "E1010");
			return new TypedExpression(TCall("Std.string", [dynamicValue]), TString, value.span);
		}
		var dynamicValue = coerce(value, TDynamic, "string concatenation", "E1010");
		return new TypedExpression(TCall("__std_string", [dynamicValue]), TString, value.span);
	}

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);

	public static function anonymousFields(type:Null<CompilerType>):Null<Array<AnonymousField>> {
		if (type == null)
			return null;
		return switch type {
			case TAnonymous(_, fields): fields;
			default: null;
		};
	}

	static function objectLiteralExpectation(type:Null<CompilerType>):Null<CompilerType> {
		if (type == null)
			return null;
		return switch type {
			case TAnonymous(_, _): type;
			case TNullable(element):
				switch element {
					case TAnonymous(_, _): element;
					default: null;
				}
			default: null;
		};
	}

	public static function arrayElementExpectation(type:Null<CompilerType>):Null<CompilerType> {
		if (type == null)
			return null;
		return switch type {
			case TArray(element): element;
			case TNullable(element): arrayElementExpectation(element);
			default: null;
		};
	}

	public static function mapExpectation(type:Null<CompilerType>):Null<{key:CompilerType, value:CompilerType}> {
		if (type == null)
			return null;
		return switch type {
			case TMap(key, value): {key: key, value: value};
			case TNullable(element): mapExpectation(element);
			default: null;
		};
	}

	public static function anonymousField(fields:Null<Array<AnonymousField>>, name:String):Null<AnonymousField> {
		if (fields != null)
			for (field in fields)
				if (field.name == name)
					return field;
		return null;
	}

	static function anonymousTypeName(fields:Array<AnonymousField>):String
		return SemanticSignature.anonymousTypeName(fields);

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	function recoverCoerce(value:TypedExpression, expected:CompilerType, context:String, code:String):TypedExpression {
		if (!session.tolerant)
			return coerce(value, expected, context, code);
		try {
			return coerce(value, expected, context, code);
		}
		catch (error:Dynamic) {
			if (Std.isOfType(error, compiler.service.CancellationError))
				throw error;
			if (Std.isOfType(error, CompileError)) {
				var compileError:CompileError = cast error;
				session.rememberRecoveryDiagnostic(compileError.diagnostic);
			}
			return recoveredError(value.span);
		}
	}

	static function recoveredError(span:SourceSpan):TypedExpression
		return new TypedExpression(TNullLiteral, TError, span);

	static function unwrapNullable(value:TypedExpression):TypedExpression
		return switch value.type {
			case TNullable(element): new TypedExpression(value.expression, element, value.span);
			default: value;
		};

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
