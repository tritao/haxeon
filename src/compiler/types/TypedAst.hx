package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstType;

/** Expression paired with its resolved semantic type and original source span. */
class TypedExpression {
	public final expression:TypedExpressionKind;
	public final type:CompilerType;
	public final span:SourceSpan;

	public function new(expression, type, span) {
		this.expression = expression;
		this.type = type;
		this.span = span;
	}
}

/** Type-checked expression operations consumed by IR generation. */
enum TypedExpressionKind {
	TIntLiteral(value:Int);
	TFloatLiteral(value:Float);
	TStringLiteral(value:String);
	TBoolLiteral(value:Bool);
	TEnumLiteral(name:String, index:Int);
	TEnumConstruct(name:String, index:Int, arguments:Array<TypedExpression>);
	TNullLiteral;
	TUnreachable;
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
	final subjectBinding:Null<String>;

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

/** Local binding introduced for one enum-constructor payload position. */
typedef TypedSwitchBinding = {
	final name:String;
	final type:CompilerType;
	final storageType:CompilerType;
	final fieldStorageType:CompilerType;
	final index:Int;
	final arrayIndex:Int;
}

/** Constant or structural constraint applied to one enum payload position. */
typedef TypedSwitchPredicate = {
	final value:Null<TypedExpression>;
	final arrayLength:Int;
	final type:CompilerType;
	final storageType:CompilerType;
	final fieldStorageType:CompilerType;
	final index:Int;
	final arrayIndex:Int;
}

/** Resolved catch arm ready for IR exception lowering. */
typedef TypedCatch = {final name:String; final type:CompilerType; final statements:Array<TypedStatement>; final span:SourceSpan;}

/** Resolved enum-constructor signature. */
typedef TypedEnumCase = {final name:String; final params:Array<CompilerType>; final span:SourceSpan;}

/** Type-checked enum declaration. */
typedef TypedEnum = {final name:String; final cases:Array<TypedEnumCase>; final span:SourceSpan;}

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
	final base:Null<String>;
	final interfaces:Array<String>;
	final fields:Array<TypedField>;
	final methods:Array<TypedFunction>;
	final span:SourceSpan;
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
