package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Source.SourceFile;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstExpression;

/** Expression paired with its resolved semantic type and original source span. */
class TypedExpression {
	public final expression:TypedExpressionKind;
	public final type:CompilerType;
	public final span:SourceSpan;
	public final stableFlowValue:Bool;

	/** Map whose keys are represented by this array, when the value originated from Map.keys(). */
	public final mapKeySource:Null<TypedExpression>;

	/** Declared storage type for a captured value whose flow type may be narrowed. */
	public final storageType:Null<CompilerType>;

	public function new(expression, type, span, stableFlowValue:Bool = false, ?mapKeySource:TypedExpression, ?storageType:CompilerType) {
		this.expression = expression;
		this.type = type;
		this.span = span;
		this.stableFlowValue = stableFlowValue;
		this.mapKeySource = mapKeySource;
		this.storageType = storageType;
	}
}

/** Type-checked expression operations consumed by IR generation. */
enum TypedExpressionKind {
	TIntLiteral(value:Int);
	TFloatLiteral(value:Float);
	TStringLiteral(value:String);
	TRuntimeDataAddress(bytes:Array<Int>);
	TBoolLiteral(value:Bool);
	TEnumLiteral(name:String, index:Int);
	TEnumConstruct(name:String, index:Int, arguments:Array<TypedExpression>);
	TEnumIndex(value:TypedExpression);
	TEnumField(value:TypedExpression, constructor:Int, field:Int);
	TNullLiteral;
	TUnreachable;
	TVoidLiteral;
	TNullableWrap(value:TypedExpression);
	TIntToFloat(value:TypedExpression);
	TIntToInt64(value:TypedExpression);
	TFloatToInt(value:TypedExpression);
	TToDynamic(value:TypedExpression);
	TLocal(name:String);
	TCellLocal(name:String, cellClass:String);
	TCaptured(name:String);
	TCellCaptured(name:String, cellClass:String);
	TClassRef(name:String);
	TStaticField(name:String, field:String);
	TFunctionRef(name:String);
	TMethodRef(object:TypedExpression, functionName:String);
	TLambda(name:String, environment:Null<String>, captures:Array<TypedCapture>);
	TAdd(left:TypedExpression, right:TypedExpression);
	TSub(left:TypedExpression, right:TypedExpression);
	TMul(left:TypedExpression, right:TypedExpression);
	TDiv(left:TypedExpression, right:TypedExpression);
	TMod(left:TypedExpression, right:TypedExpression);
	TBitAnd(left:TypedExpression, right:TypedExpression);
	TBitXor(left:TypedExpression, right:TypedExpression);
	TBitOr(left:TypedExpression, right:TypedExpression);
	TShiftLeft(left:TypedExpression, right:TypedExpression);
	TShiftRight(left:TypedExpression, right:TypedExpression);
	TUnsignedShiftRight(left:TypedExpression, right:TypedExpression);
	TNegate(value:TypedExpression);
	TLess(left:TypedExpression, right:TypedExpression);
	TLessEqual(left:TypedExpression, right:TypedExpression);
	TEqual(left:TypedExpression, right:TypedExpression);
	TNot(value:TypedExpression);
	TAnd(left:TypedExpression, right:TypedExpression);
	TOr(left:TypedExpression, right:TypedExpression);
	TConditional(condition:TypedExpression, whenTrue:TypedExpression, whenFalse:TypedExpression);
	TBlockExpression(statements:Array<TypedStatement>, result:TypedExpression);
	TThrowExpression(expression:TypedExpression);
	TNoReturn(expression:TypedExpression);
	TCast(expression:TypedExpression);
	TAbiCast(expression:TypedExpression);
	TSwitchExpression(expression:TypedExpression, cases:Array<TypedSwitchExpressionCase>, defaultExpression:Null<TypedExpression>);
	TObjectLiteral(name:String, fields:Array<TypedObjectField>);
	TArrayLiteral(values:Array<TypedExpression>);
	TMapLiteral(entries:Array<TypedMapEntry>);
	TArrayComprehension(keyName:String, valueName:Null<String>, iterable:TypedExpression, condition:Null<TypedExpression>, value:TypedExpression);
	TMapComprehension(keyName:String, valueName:Null<String>, iterable:TypedExpression, condition:Null<TypedExpression>, key:TypedExpression,
		value:TypedExpression);
	TRange(start:TypedExpression, end:TypedExpression);
	TCall(name:String, arguments:Array<TypedExpression>);
	TCNativeCall(name:String, arguments:Array<TypedExpression>);
	TCollectionCall(receiver:TypedExpression, operation:String, arguments:Array<TypedExpression>);
	TClosureCall(callee:TypedExpression, arguments:Array<TypedExpression>);
	TToInterface(value:TypedExpression, name:String);
	TNew(typeName:String, arguments:Array<TypedExpression>, hasConstructor:Bool);
	TNewArray(element:CompilerType, length:TypedExpression);
	TNewMap(key:CompilerType, value:CompilerType);
	TField(object:TypedExpression, name:String);
	TMethodCall(object:TypedExpression, functionName:String, arguments:Array<TypedExpression>);
	TSuperCall(owner:String, arguments:Array<TypedExpression>);
	TIndex(array:TypedExpression, index:TypedExpression);
	TPostfixLocal(name:String, delta:Int);
	TPostfixCellLocal(name:String, cellClass:String, delta:Int);
	TPostfixCellCaptured(name:String, cellClass:String, delta:Int);
	TPostfixStaticField(owner:String, name:String, delta:Int);
	TPostfixField(object:TypedExpression, name:String, delta:Int);
	TPostfixIndex(array:TypedExpression, index:TypedExpression, delta:Int);
	TMapGet(map:TypedExpression, key:TypedExpression);
	TArrayLength(array:TypedExpression);
	TStringLength(value:TypedExpression);
	TStringIndexOf(value:TypedExpression, needle:TypedExpression);
	TStringCharAt(value:TypedExpression, index:TypedExpression);
	TStringCharCodeAt(value:TypedExpression, index:TypedExpression);
	TStringFromCharCode(code:TypedExpression);
	TStringSubstring(value:TypedExpression, start:TypedExpression, end:Null<TypedExpression>);
	TArrayPush(array:TypedExpression, value:TypedExpression);
	TArrayUnshift(array:TypedExpression, value:TypedExpression);
	TArrayPop(array:TypedExpression);
	TArraySort(array:TypedExpression, comparator:TypedExpression);
}

/** Resolved field initializer in a typed object literal. */
typedef TypedObjectField = {final name:String; final value:TypedExpression;}

/** Resolved key/value pair in a typed map literal. */
typedef TypedMapEntry = {final key:TypedExpression; final value:TypedExpression;}

/** Type-checked, guarded arm of a switch expression. */
typedef TypedSwitchExpressionCase = {
	final value:TypedExpression;
	final span:SourceSpan;
	final subjectBinding:Null<String>;
	final arrayPattern:Null<TypedSwitchArrayPattern>;

	/** True when the source arm is the wildcard pattern `_`, which has no binding name. */
	final isCatchAll:Bool;

	final guard:Null<TypedExpression>;
	final result:TypedExpression;
	final enumName:Null<String>;
	final constructorIndex:Int;
	final bindings:Array<TypedSwitchBinding>;
	final predicates:Array<TypedSwitchPredicate>;
}

/** Type-checked statements with explicit storage and dispatch decisions. */
enum TypedStatement {
	TDeclare(name:String, type:CompilerType, span:SourceSpan);
	TVar(name:String, initializer:TypedExpression, span:SourceSpan);
	TAssign(name:String, value:TypedExpression, span:SourceSpan);
	TCellAssign(name:String, cellClass:String, value:TypedExpression, span:SourceSpan);
	TCellCapturedAssign(name:String, cellClass:String, value:TypedExpression, span:SourceSpan);
	TFieldAssign(object:TypedExpression, name:String, value:TypedExpression, span:SourceSpan);
	TStaticFieldAssign(name:String, field:String, value:TypedExpression, span:SourceSpan);
	TIndexAssign(array:TypedExpression, index:TypedExpression, value:TypedExpression, span:SourceSpan);
	TMapAssign(map:TypedExpression, key:TypedExpression, value:TypedExpression, span:SourceSpan);
	TReturn(expression:TypedExpression, span:SourceSpan);
	TReturnVoid(span:SourceSpan);
	TThrow(expression:TypedExpression, span:SourceSpan);
	TTry(tryBranch:Array<TypedStatement>, catches:Array<TypedCatch>, span:SourceSpan);
	TIf(condition:TypedExpression, thenBranch:Array<TypedStatement>, elseBranch:Array<TypedStatement>, span:SourceSpan);
	TWhile(condition:TypedExpression, body:Array<TypedStatement>, span:SourceSpan);
	TDoWhile(body:Array<TypedStatement>, condition:TypedExpression, span:SourceSpan);
	TForIn(keyName:String, valueName:Null<String>, iterable:TypedExpression, body:Array<TypedStatement>, span:SourceSpan);
	TBreak(span:SourceSpan);
	TContinue(span:SourceSpan);
	TSwitch(expression:TypedExpression, cases:Array<TypedSwitchCase>, defaultBranch:Array<TypedStatement>, hasDefault:Bool, span:SourceSpan);
	TIncrement(name:String, delta:Int, span:SourceSpan);
	TCellIncrement(name:String, cellClass:String, valueType:CompilerType, delta:Int, span:SourceSpan);
	TCellCapturedIncrement(name:String, cellClass:String, valueType:CompilerType, delta:Int, span:SourceSpan);
	TExpression(expression:TypedExpression, span:SourceSpan);
}

/** Type-checked switch arm with resolved enum bindings, when applicable. */
typedef TypedSwitchCase = {
	final value:TypedExpression;
	final subjectBinding:Null<String>;
	final arrayPattern:Null<TypedSwitchArrayPattern>;

	/** True when the source arm is the wildcard pattern `_`, which has no binding name. */
	final isCatchAll:Bool;

	final guard:Null<TypedExpression>;
	final statements:Array<TypedStatement>;
	final enumName:Null<String>;
	final constructorIndex:Int;
	final bindings:Array<TypedSwitchBinding>;
	final predicates:Array<TypedSwitchPredicate>;
	final span:SourceSpan;
}

/** Fixed-length array pattern used by a switch arm, including nested enum patterns. */
typedef TypedSwitchArrayPattern = {final elements:Array<TypedSwitchArrayElement>;}

/** One typed element constraint or binding in a fixed-length array pattern. */
typedef TypedSwitchArrayElement = {
	final type:CompilerType;
	final value:Null<TypedExpression>;
	final subjectBinding:Null<String>;
	final isCatchAll:Bool;
	final constructorIndex:Int;
	final bindings:Array<TypedSwitchBinding>;
	final predicates:Array<TypedSwitchPredicate>;
}

/** Local binding introduced for one enum-constructor payload position. */
typedef TypedSwitchBinding = {
	final name:String;
	final type:CompilerType;
	final storageType:CompilerType;
	final fieldStorageType:CompilerType;
	final index:Int;
	final arrayIndex:Int;
	final ?nestedPath:Array<TypedSwitchFieldAccess>;
}

/** One enum payload field traversed while matching a nested constructor pattern. */
typedef TypedSwitchFieldAccess = {final constructorIndex:Int; final fieldIndex:Int; final storageType:CompilerType;}

/** One anonymous-object field traversed while matching an enum payload pattern. */
typedef TypedSwitchObjectFieldAccess = {final name:String; final storageType:CompilerType;}

/** Constant or structural constraint applied to one enum payload position. */
typedef TypedSwitchPredicate = {
	final value:Null<TypedExpression>;
	final arrayLength:Int;
	final type:CompilerType;
	final storageType:CompilerType;
	final fieldStorageType:CompilerType;
	final index:Int;
	final arrayIndex:Int;
	final ?nestedPath:Array<TypedSwitchFieldAccess>;
	final ?objectPath:Array<TypedSwitchObjectFieldAccess>;
	final ?nestedConstructorIndex:Int;
}

/** Minimal typed information needed to prove constructor coverage across switch arms. */
typedef TypedSwitchCoverageCase = {
	final constructorIndex:Int;
	final subjectBinding:Null<String>;
	final isCatchAll:Bool;
	final guard:Null<TypedExpression>;
	final predicates:Array<TypedSwitchPredicate>;
}

/** Resolved catch arm ready for IR exception lowering. */
typedef TypedCatch = {final name:String; final type:CompilerType; final statements:Array<TypedStatement>; final span:SourceSpan;}

/** Resolved enum-constructor signature. */
typedef TypedEnumCase = {
	final name:String;
	final metadata:Array<compiler.syntax.Ast.AstMetadata>;
	final params:Array<CompilerType>;
	final span:SourceSpan;
}

/** Type-checked enum declaration. */
typedef TypedEnum = {
	final name:String;
	final metadata:Array<compiler.syntax.Ast.AstMetadata>;
	final cases:Array<TypedEnumCase>;
	final span:SourceSpan;
}

/** Type-checked enum-abstract initializer retained for semantic indexing. */
typedef TypedInitializer = {final owner:String; final source:AstExpression; final expression:TypedExpression;}

/**
 * Fully typed function or method body.
 *
 * Cell maps record mutable storage decisions that IR generation must preserve
 * across closures and exception edges.
 */
typedef TypedFunction = {
	final name:String;
	final ?genericOrigin:String;
	final ?typeArguments:Array<CompilerType>;
	final owner:Null<String>;
	final isStatic:Bool;
	final isConstructor:Bool;
	final arguments:Array<{name:String, type:CompilerType}>;
	final result:CompilerType;
	final statements:Array<TypedStatement>;
	final cells:Map<String, String>;
	final cellCaptures:Map<String, String>;
	final span:SourceSpan;
}

/** Class field after annotation inference and initializer type checking. */
typedef TypedField = {
	final name:String;
	final metadata:Array<compiler.syntax.Ast.AstMetadata>;
	final type:CompilerType;
	final initializer:Null<TypedExpression>;

	/** Evaluated constant retained for compile-time inline-field substitution. */
	final inlineValue:Null<TypedExpression>;

	final readAccess:Null<compiler.syntax.Ast.AstFieldAccess>;
	final writeAccess:Null<compiler.syntax.Ast.AstFieldAccess>;
	final isStatic:Bool;
	final isInline:Bool;
	final isFinal:Bool;
	final span:SourceSpan;
}

/** Class declaration with resolved field, method, and inheritance contracts. */
typedef TypedClass = {
	final name:String;
	final isValue:Bool;

	/** C-layout record with no HashLink object or value-structure representation. */
	final isNativeValue:Bool;

	/** Portable and selected-target layouts retained for compile-time layout queries. */
	final nativeLayouts:Array<TypedNativeLayout>;

	final base:Null<String>;
	final interfaces:Array<String>;
	final fields:Array<TypedField>;
	final methods:Array<TypedFunction>;
	final span:SourceSpan;
}

/** Computed layout for one portable target ABI. */
typedef TypedNativeLayout = {
	final target:String;
	final size:Int;
	final alignment:Int;
	final fields:Array<TypedNativeFieldLayout>;
}

/** Byte placement of one field in a native record. */
typedef TypedNativeFieldLayout = {
	final name:String;
	final offset:Int;
	final size:Int;
	final alignment:Int;
}

/** Resolved callable contract required by an interface. */
typedef TypedInterfaceMethod = {final name:String; final arguments:Array<CompilerType>; final result:CompilerType;}

/** Interface declaration after base and method signature resolution. */
typedef TypedInterface = {final name:String; final bases:Array<String>; final methods:Array<TypedInterfaceMethod>;}

/** Reason a local is represented by a shared generated cell. */
enum CellStorageKind {
	MutableCapture;
	ExceptionEdge;
}

/** Storage location read while constructing a closure environment. */
enum TypedCaptureSource {
	CaptureLocal(bindingId:String);
	CaptureReceiver;
	CaptureCellLocal(name:String, cellClass:String);
	CaptureEnvironmentField(name:String);
	CaptureCellEnvironmentField(name:String, cellClass:String);
	CaptureExpression(expression:TypedExpression);
}

/** A closure capture tied to its resolved lexical binding and storage source. */
typedef TypedCapture = {
	final field:String;
	final bindingId:String;
	final type:CompilerType;
	final storageType:CompilerType;
	final source:TypedCaptureSource;
}

/** Semantic storage required to preserve a binding across an exceptional edge or closure. */
typedef TypedStorageRequirement = {final name:String; final valueType:CompilerType; final kind:CellStorageKind;}

/** Semantic captures shared by one generated lambda body. */
typedef TypedEnvironmentRequirement = {final name:String; final captures:Array<TypedCapture>;}

/** Closure and exceptional-edge requirements consumed by lowering. */
typedef TypedClosurePlan = {
	final storage:Array<TypedStorageRequirement>;
	final environments:Array<TypedEnvironmentRequirement>;
}

/** Named backend representation of a structural anonymous type. */
typedef TypedAnonymous = {final name:String; final fields:Array<compiler.types.Type.AnonymousField>;}

/** Complete semantic module consumed by IR generation. */
typedef TypedProgram = {
	final enums:Array<TypedEnum>;
	final interfaces:Array<TypedInterface>;
	final classes:Array<TypedClass>;
	final functions:Array<TypedFunction>;
	final initializers:Array<TypedInitializer>;
	final closurePlan:TypedClosurePlan;
	final anonymousTypes:Array<TypedAnonymous>;
	final natives:Array<TypedNative>;
}

/** A source-declared target function with no generated body. */
typedef TypedNative = {
	final name:String;
	final library:String;
	final symbol:String;
	final arguments:Array<CompilerType>;
	final result:CompilerType;
	final convention:NativeConvention;
}

enum NativeConvention {
	HashLinkNative;
	CNative(signature:String);
}

/** Utilities for moving a safely reusable typed body to a new source offset. */
class TypedAstTools {
	/** Generated lambda bodies are tied to their generated names, so do not reuse them across offsets. */
	public static function canRebase(fn:TypedFunction):Bool {
		for (statement in fn.statements)
			if (containsLambdaStatement(statement))
				return false;
		return true;
	}

	/** Rebase all source spans in a typed function while preserving semantic identities and types. */
	public static function rebaseFunction(fn:TypedFunction, source:SourceFile, delta:Int):TypedFunction {
		return {
			name: fn.name,
			genericOrigin: fn.genericOrigin,
			typeArguments: fn.typeArguments,
			owner: fn.owner,
			isStatic: fn.isStatic,
			isConstructor: fn.isConstructor,
			arguments: fn.arguments.copy(),
			result: fn.result,
			statements: [for (statement in fn.statements) rebaseStatement(statement, source, delta)],
			cells: fn.cells,
			cellCaptures: fn.cellCaptures,
			span: rebaseSpan(fn.span, source, delta)
		};
	}

	static function rebaseSpan(span:SourceSpan, source:SourceFile, delta:Int):SourceSpan {
		return span.file.path == source.path ? source.span(span.start + delta, span.end + delta) : span;
	}

	static function rebaseStatement(statement:TypedStatement, source:SourceFile, delta:Int):TypedStatement {
		return switch statement {
			case TDeclare(name, type, span): TDeclare(name, type, rebaseSpan(span, source, delta));
			case TVar(name, initializer, span): TVar(name, rebaseExpression(initializer, source, delta), rebaseSpan(span, source, delta));
			case TAssign(name, value, span): TAssign(name, rebaseExpression(value, source, delta), rebaseSpan(span, source, delta));
			case TCellAssign(name, cellClass, value, span): TCellAssign(name, cellClass, rebaseExpression(value, source, delta), rebaseSpan(span, source, delta));
			case TCellCapturedAssign(name, cellClass, value, span):
				TCellCapturedAssign(name, cellClass, rebaseExpression(value, source, delta), rebaseSpan(span, source, delta));
			case TFieldAssign(object, name, value, span):
				TFieldAssign(rebaseExpression(object, source, delta), name, rebaseExpression(value, source, delta), rebaseSpan(span, source, delta));
			case TStaticFieldAssign(owner, name, value, span):
				TStaticFieldAssign(owner, name, rebaseExpression(value, source, delta), rebaseSpan(span, source, delta));
			case TIndexAssign(array, index, value, span):
				TIndexAssign(rebaseExpression(array, source, delta), rebaseExpression(index, source, delta),
					rebaseExpression(value, source, delta), rebaseSpan(span, source, delta));
			case TMapAssign(map, key, value, span):
				TMapAssign(rebaseExpression(map, source, delta), rebaseExpression(key, source, delta),
					rebaseExpression(value, source, delta), rebaseSpan(span, source, delta));
			case TReturn(expression, span): TReturn(rebaseExpression(expression, source, delta), rebaseSpan(span, source, delta));
			case TReturnVoid(span): TReturnVoid(rebaseSpan(span, source, delta));
			case TThrow(expression, span): TThrow(rebaseExpression(expression, source, delta), rebaseSpan(span, source, delta));
			case TTry(body, catches, span):
				TTry(
					[for (nested in body) rebaseStatement(nested, source, delta)],
					[for (caught in catches) {
						name: caught.name,
						type: caught.type,
						statements: [for (nested in caught.statements) rebaseStatement(nested, source, delta)],
						span: rebaseSpan(caught.span, source, delta)
					}],
					rebaseSpan(span, source, delta));
			case TIf(condition, thenBranch, elseBranch, span):
				TIf(rebaseExpression(condition, source, delta),
					[for (nested in thenBranch) rebaseStatement(nested, source, delta)],
					[for (nested in elseBranch) rebaseStatement(nested, source, delta)], rebaseSpan(span, source, delta));
			case TWhile(condition, body, span):
				TWhile(rebaseExpression(condition, source, delta),
					[for (nested in body) rebaseStatement(nested, source, delta)], rebaseSpan(span, source, delta));
			case TDoWhile(body, condition, span):
				TDoWhile([for (nested in body) rebaseStatement(nested, source, delta)],
					rebaseExpression(condition, source, delta), rebaseSpan(span, source, delta));
			case TForIn(keyName, valueName, iterable, body, span):
				TForIn(keyName, valueName, rebaseExpression(iterable, source, delta),
					[for (nested in body) rebaseStatement(nested, source, delta)], rebaseSpan(span, source, delta));
			case TBreak(span): TBreak(rebaseSpan(span, source, delta));
			case TContinue(span): TContinue(rebaseSpan(span, source, delta));
			case TSwitch(expression, cases, defaultBranch, hasDefault, span):
				TSwitch(rebaseExpression(expression, source, delta),
					[for (item in cases) {
						value: rebaseExpression(item.value, source, delta),
						subjectBinding: item.subjectBinding,
						arrayPattern: item.arrayPattern,
						isCatchAll: item.isCatchAll,
						guard: item.guard == null ? null : rebaseExpression(item.guard, source, delta),
						statements: [for (nested in item.statements) rebaseStatement(nested, source, delta)],
						enumName: item.enumName,
						constructorIndex: item.constructorIndex,
						bindings: item.bindings,
						predicates: item.predicates,
						span: rebaseSpan(item.span, source, delta)
					}],
					[for (nested in defaultBranch) rebaseStatement(nested, source, delta)], hasDefault, rebaseSpan(span, source, delta));
			case TIncrement(name, deltaValue, span): TIncrement(name, deltaValue, rebaseSpan(span, source, delta));
			case TCellIncrement(name, cellClass, valueType, deltaValue, span):
				TCellIncrement(name, cellClass, valueType, deltaValue, rebaseSpan(span, source, delta));
			case TCellCapturedIncrement(name, cellClass, valueType, deltaValue, span):
				TCellCapturedIncrement(name, cellClass, valueType, deltaValue, rebaseSpan(span, source, delta));
			case TExpression(expression, span): TExpression(rebaseExpression(expression, source, delta), rebaseSpan(span, source, delta));
		};
	}

	static function rebaseExpression(expression:TypedExpression, source:SourceFile, delta:Int):TypedExpression {
		var rebased:TypedExpressionKind = switch expression.expression {
			case TEnumConstruct(name, index, arguments): TEnumConstruct(name, index, rebaseExpressions(arguments, source, delta));
			case TEnumIndex(value): TEnumIndex(rebaseExpression(value, source, delta));
			case TEnumField(value, constructor, field): TEnumField(rebaseExpression(value, source, delta), constructor, field);
			case TNullableWrap(value): TNullableWrap(rebaseExpression(value, source, delta));
			case TIntToFloat(value): TIntToFloat(rebaseExpression(value, source, delta));
			case TIntToInt64(value): TIntToInt64(rebaseExpression(value, source, delta));
			case TFloatToInt(value): TFloatToInt(rebaseExpression(value, source, delta));
			case TToDynamic(value): TToDynamic(rebaseExpression(value, source, delta));
			case TNegate(value): TNegate(rebaseExpression(value, source, delta));
			case TNot(value): TNot(rebaseExpression(value, source, delta));
			case TThrowExpression(value): TThrowExpression(rebaseExpression(value, source, delta));
			case TNoReturn(value): TNoReturn(rebaseExpression(value, source, delta));
			case TCast(value): TCast(rebaseExpression(value, source, delta));
			case TAbiCast(value): TAbiCast(rebaseExpression(value, source, delta));
			case TToInterface(value, name): TToInterface(rebaseExpression(value, source, delta), name);
			case TArrayLength(value): TArrayLength(rebaseExpression(value, source, delta));
			case TStringLength(value): TStringLength(rebaseExpression(value, source, delta));
			case TAdd(left, right): TAdd(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TSub(left, right): TSub(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TMul(left, right): TMul(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TDiv(left, right): TDiv(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TMod(left, right): TMod(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TBitAnd(left, right): TBitAnd(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TBitXor(left, right): TBitXor(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TBitOr(left, right): TBitOr(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TShiftLeft(left, right): TShiftLeft(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TShiftRight(left, right): TShiftRight(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TUnsignedShiftRight(left, right): TUnsignedShiftRight(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TLess(left, right): TLess(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TLessEqual(left, right): TLessEqual(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TEqual(left, right): TEqual(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TAnd(left, right): TAnd(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TOr(left, right): TOr(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TIndex(left, right): TIndex(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TMapGet(left, right): TMapGet(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TStringIndexOf(left, right): TStringIndexOf(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TStringCharAt(left, right): TStringCharAt(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TStringCharCodeAt(left, right): TStringCharCodeAt(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TArrayPush(left, right): TArrayPush(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TArrayUnshift(left, right): TArrayUnshift(rebaseExpression(left, source, delta), rebaseExpression(right, source, delta));
			case TConditional(condition, whenTrue, whenFalse):
				TConditional(rebaseExpression(condition, source, delta), rebaseExpression(whenTrue, source, delta), rebaseExpression(whenFalse, source, delta));
			case TBlockExpression(statements, result):
				TBlockExpression([for (statement in statements) rebaseStatement(statement, source, delta)], rebaseExpression(result, source, delta));
			case TField(object, name): TField(rebaseExpression(object, source, delta), name);
			case TPostfixField(object, name, deltaValue): TPostfixField(rebaseExpression(object, source, delta), name, deltaValue);
			case TMethodCall(object, name, arguments):
				TMethodCall(rebaseExpression(object, source, delta), name, rebaseExpressions(arguments, source, delta));
			case TCollectionCall(object, operation, arguments):
				TCollectionCall(rebaseExpression(object, source, delta), operation, rebaseExpressions(arguments, source, delta));
			case TCall(name, arguments): TCall(name, rebaseExpressions(arguments, source, delta));
			case TCNativeCall(name, arguments): TCNativeCall(name, rebaseExpressions(arguments, source, delta));
			case TFunctionRef(name): TFunctionRef(name);
			case TMethodRef(object, name): TMethodRef(rebaseExpression(object, source, delta), name);
			case TNew(name, arguments, hasConstructor): TNew(name, rebaseExpressions(arguments, source, delta), hasConstructor);
			case TNewArray(element, length): TNewArray(element, rebaseExpression(length, source, delta));
			case TSwitchExpression(value, cases, defaultExpression):
				TSwitchExpression(rebaseExpression(value, source, delta),
					[for (item in cases) {
					value: rebaseExpression(item.value, source, delta),
					span: rebaseSpan(item.span, source, delta),
					subjectBinding: item.subjectBinding,
					arrayPattern: item.arrayPattern,
						isCatchAll: item.isCatchAll,
						guard: item.guard == null ? null : rebaseExpression(item.guard, source, delta),
						result: rebaseExpression(item.result, source, delta),
						enumName: item.enumName,
						constructorIndex: item.constructorIndex,
						bindings: item.bindings,
						predicates: item.predicates
					}],
					defaultExpression == null ? null : rebaseExpression(defaultExpression, source, delta));
			case TObjectLiteral(name, fields):
				TObjectLiteral(name, [for (field in fields) {name: field.name, value: rebaseExpression(field.value, source, delta)}]);
			case TArrayLiteral(values): TArrayLiteral(rebaseExpressions(values, source, delta));
			case TMapLiteral(entries):
				TMapLiteral([for (entry in entries) {key: rebaseExpression(entry.key, source, delta), value: rebaseExpression(entry.value, source, delta)}]);
			case TArrayComprehension(keyName, valueName, iterable, condition, value):
				TArrayComprehension(keyName, valueName, rebaseExpression(iterable, source, delta),
					condition == null ? null : rebaseExpression(condition, source, delta), rebaseExpression(value, source, delta));
			case TMapComprehension(keyName, valueName, iterable, condition, key, value):
				TMapComprehension(keyName, valueName, rebaseExpression(iterable, source, delta),
					condition == null ? null : rebaseExpression(condition, source, delta), rebaseExpression(key, source, delta),
					rebaseExpression(value, source, delta));
			case TRange(start, end): TRange(rebaseExpression(start, source, delta), rebaseExpression(end, source, delta));
			case TClosureCall(callee, arguments): TClosureCall(rebaseExpression(callee, source, delta), rebaseExpressions(arguments, source, delta));
			case TStaticField(owner, name): TStaticField(owner, name);
			case TPostfixStaticField(owner, name, deltaValue): TPostfixStaticField(owner, name, deltaValue);
			case TPostfixIndex(array, index, deltaValue):
				TPostfixIndex(rebaseExpression(array, source, delta), rebaseExpression(index, source, delta), deltaValue);
			case TSuperCall(owner, arguments): TSuperCall(owner, rebaseExpressions(arguments, source, delta));
			case TStringFromCharCode(code): TStringFromCharCode(rebaseExpression(code, source, delta));
			case TStringSubstring(value, start, end):
				TStringSubstring(rebaseExpression(value, source, delta), rebaseExpression(start, source, delta),
					end == null ? null : rebaseExpression(end, source, delta));
			case TArrayPop(array): TArrayPop(rebaseExpression(array, source, delta));
			case TArraySort(array, comparator): TArraySort(rebaseExpression(array, source, delta), rebaseExpression(comparator, source, delta));
			case TIntLiteral(_), TFloatLiteral(_), TStringLiteral(_), TRuntimeDataAddress(_), TBoolLiteral(_), TEnumLiteral(_, _), TNullLiteral,
				TUnreachable, TVoidLiteral, TLocal(_), TCellLocal(_, _), TCaptured(_), TCellCaptured(_), TClassRef(_),
				TLambda(_, _, _), TNewMap(_, _), TPostfixLocal(_, _), TPostfixCellLocal(_, _, _), TPostfixCellCaptured(_, _, _):
				expression.expression;
		};
		return new TypedExpression(rebased, expression.type, rebaseSpan(expression.span, source, delta));
	}

	static function rebaseExpressions(expressions:Array<TypedExpression>, source:SourceFile, delta:Int):Array<TypedExpression>
		return [for (expression in expressions) rebaseExpression(expression, source, delta)];

	static function containsLambdaStatement(statement:TypedStatement):Bool {
		return switch statement {
			case TVar(_, value, _), TAssign(_, value, _), TCellAssign(_, _, value, _), TCellCapturedAssign(_, _, value, _),
				TReturn(value, _), TThrow(value, _), TExpression(value, _): containsLambdaExpression(value);
			case TFieldAssign(object, _, value, _): containsLambdaExpression(object) || containsLambdaExpression(value);
			case TStaticFieldAssign(_, _, value, _): containsLambdaExpression(value);
			case TIndexAssign(array, index, value, _), TMapAssign(array, index, value, _):
				containsLambdaExpression(array) || containsLambdaExpression(index) || containsLambdaExpression(value);
			case TTry(body, catches, _):
				containsLambdaStatements(body) || [for (caught in catches) containsLambdaStatements(caught.statements)].indexOf(true) >= 0;
			case TIf(condition, thenBranch, elseBranch, _):
				containsLambdaExpression(condition) || containsLambdaStatements(thenBranch) || containsLambdaStatements(elseBranch);
			case TWhile(condition, body, _): containsLambdaExpression(condition) || containsLambdaStatements(body);
			case TDoWhile(body, condition, _): containsLambdaStatements(body) || containsLambdaExpression(condition);
			case TForIn(_, _, iterable, body, _): containsLambdaExpression(iterable) || containsLambdaStatements(body);
			case TSwitch(expression, cases, defaultBranch, _, _):
				containsLambdaExpression(expression) || [for (item in cases)
					containsLambdaExpression(item.value) || item.guard != null && containsLambdaExpression(item.guard)
					|| containsLambdaStatements(item.statements)].indexOf(true) >= 0 || containsLambdaStatements(defaultBranch);
			case TDeclare(_, _, _), TReturnVoid(_), TBreak(_), TContinue(_), TIncrement(_, _, _), TCellIncrement(_, _, _, _, _),
				TCellCapturedIncrement(_, _, _, _, _): false;
		};
	}

	static function containsLambdaStatements(statements:Array<TypedStatement>):Bool {
		for (statement in statements)
			if (containsLambdaStatement(statement))
				return true;
		return false;
	}

	static function containsLambdaExpression(expression:TypedExpression):Bool {
		return switch expression.expression {
			case TLambda(_, _, _): true;
			case TEnumConstruct(_, _, arguments), TCall(_, arguments), TCNativeCall(_, arguments), TArrayLiteral(arguments),
				TClosureCall(_, arguments): [for (argument in arguments) containsLambdaExpression(argument)].indexOf(true) >= 0;
			case TEnumIndex(value), TEnumField(value, _, _): containsLambdaExpression(value);
			case TNullableWrap(value), TIntToFloat(value), TIntToInt64(value), TFloatToInt(value), TToDynamic(value), TNegate(value), TNot(value),
				TThrowExpression(value), TNoReturn(value), TCast(value), TAbiCast(value), TArrayLength(value), TStringLength(value),
				TStringFromCharCode(value), TArrayPop(value): containsLambdaExpression(value);
			case TToInterface(value, _): containsLambdaExpression(value);
			case TAdd(left, right), TSub(left, right), TMul(left, right), TDiv(left, right), TMod(left, right), TBitAnd(left, right),
				TBitXor(left, right), TBitOr(left, right), TShiftLeft(left, right), TShiftRight(left, right), TUnsignedShiftRight(left, right),
				TLess(left, right), TLessEqual(left, right), TEqual(left, right), TAnd(left, right), TOr(left, right), TIndex(left, right),
				TMapGet(left, right), TStringIndexOf(left, right), TStringCharAt(left, right), TStringCharCodeAt(left, right),
				TArrayPush(left, right), TArrayUnshift(left, right), TPostfixIndex(left, right, _):
				containsLambdaExpression(left) || containsLambdaExpression(right);
			case TConditional(condition, whenTrue, whenFalse):
				containsLambdaExpression(condition) || containsLambdaExpression(whenTrue) || containsLambdaExpression(whenFalse);
			case TBlockExpression(statements, result): containsLambdaStatements(statements) || containsLambdaExpression(result);
			case TField(object, _), TPostfixField(object, _, _), TMethodRef(object, _): containsLambdaExpression(object);
			case TCollectionCall(object, _, arguments):
				containsLambdaExpression(object) || [for (argument in arguments) containsLambdaExpression(argument)].indexOf(true) >= 0;
			case TMethodCall(object, _, arguments): containsLambdaExpression(object) || [for (argument in arguments) containsLambdaExpression(argument)].indexOf(true) >= 0;
			case TNew(_, arguments, _), TSuperCall(_, arguments): [for (argument in arguments) containsLambdaExpression(argument)].indexOf(true) >= 0;
			case TNewArray(_, length): containsLambdaExpression(length);
			case TSwitchExpression(value, cases, defaultExpression):
				containsLambdaExpression(value) || [for (item in cases)
					containsLambdaExpression(item.value) || item.guard != null && containsLambdaExpression(item.guard)
					|| containsLambdaExpression(item.result)].indexOf(true) >= 0
					|| defaultExpression != null && containsLambdaExpression(defaultExpression);
			case TObjectLiteral(_, fields): [for (field in fields) containsLambdaExpression(field.value)].indexOf(true) >= 0;
			case TMapLiteral(entries): [for (entry in entries)
				containsLambdaExpression(entry.key) || containsLambdaExpression(entry.value)].indexOf(true) >= 0;
			case TArrayComprehension(_, _, iterable, condition, value):
				containsLambdaExpression(iterable) || condition != null && containsLambdaExpression(condition) || containsLambdaExpression(value);
			case TMapComprehension(_, _, iterable, condition, key, value):
				containsLambdaExpression(iterable) || condition != null && containsLambdaExpression(condition)
					|| containsLambdaExpression(key) || containsLambdaExpression(value);
			case TRange(start, end): containsLambdaExpression(start) || containsLambdaExpression(end);
			case TStringSubstring(value, start, end):
				containsLambdaExpression(value) || containsLambdaExpression(start) || end != null && containsLambdaExpression(end);
			case TArraySort(array, comparator): containsLambdaExpression(array) || containsLambdaExpression(comparator);
			case TFunctionRef(_), TClassRef(_), TStaticField(_, _), TPostfixStaticField(_, _, _), TLocal(_), TCellLocal(_, _), TCaptured(_),
				TCellCaptured(_, _), TPostfixLocal(_, _), TPostfixCellLocal(_, _, _), TPostfixCellCaptured(_, _, _), TIntLiteral(_), TFloatLiteral(_),
				TStringLiteral(_), TRuntimeDataAddress(_), TBoolLiteral(_), TEnumLiteral(_, _), TNullLiteral, TUnreachable, TVoidLiteral, TNewMap(_, _): false;
		};
	}
}
