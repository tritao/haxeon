package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;
import compiler.Ast.AstType;

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

enum TypedExpressionKind {
	TIntLiteral(value:Int);
	TFloatLiteral(value:Float);
	TStringLiteral(value:String);
	TBoolLiteral(value:Bool);
	TEnumLiteral(name:String, index:Int);
	TEnumConstruct(name:String, index:Int, arguments:Array<TypedExpression>);
	TNullLiteral;
	TNullableWrap(value:TypedExpression);
	TToDynamic(value:TypedExpression);
	TLocal(name:String);
	TCellLocal(name:String, cellClass:String);
	TCaptured(name:String);
	TCellCaptured(name:String, cellClass:String);
	TClassRef(name:String);
	TStaticField(name:String, field:String);
	TFunctionRef(name:String);
	TLambda(name:String, environment:Null<String>, captures:Array<String>);
	TAdd(left:TypedExpression, right:TypedExpression);
	TSub(left:TypedExpression, right:TypedExpression);
	TMul(left:TypedExpression, right:TypedExpression);
	TDiv(left:TypedExpression, right:TypedExpression);
	TMod(left:TypedExpression, right:TypedExpression);
	TNegate(value:TypedExpression);
	TLess(left:TypedExpression, right:TypedExpression);
	TLessEqual(left:TypedExpression, right:TypedExpression);
	TEqual(left:TypedExpression, right:TypedExpression);
	TNot(value:TypedExpression);
	TAnd(left:TypedExpression, right:TypedExpression);
	TOr(left:TypedExpression, right:TypedExpression);
	TConditional(condition:TypedExpression, whenTrue:TypedExpression, whenFalse:TypedExpression);
	TObjectLiteral(name:String, fields:Array<TypedObjectField>);
	TCall(name:String, arguments:Array<TypedExpression>);
	TCollectionCall(receiver:TypedExpression, operation:String, arguments:Array<TypedExpression>);
	TClosureCall(callee:TypedExpression, arguments:Array<TypedExpression>);
	TToInterface(value:TypedExpression, name:String);
	TNew(typeName:String, arguments:Array<TypedExpression>, hasConstructor:Bool);
	TNewArray(element:CompilerType, length:TypedExpression);
	TNewMap(key:CompilerType, value:CompilerType);
	TField(object:TypedExpression, name:String);
	TMethodCall(object:TypedExpression, functionName:String, arguments:Array<TypedExpression>);
	TIndex(array:TypedExpression, index:TypedExpression);
	TMapGet(map:TypedExpression, key:TypedExpression);
	TArrayLength(array:TypedExpression);
	TStringLength(value:TypedExpression);
	TStringIndexOf(value:TypedExpression, needle:TypedExpression);
	TStringSubstring(value:TypedExpression, start:TypedExpression, end:TypedExpression);
	TArrayPush(array:TypedExpression, value:TypedExpression);
	TArrayPop(array:TypedExpression);
}

typedef TypedObjectField = {final name:String; final value:TypedExpression;}

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
	TForIn(name:String, iterable:TypedExpression, body:Array<TypedStatement>, span:SourceSpan);
	TBreak(span:SourceSpan);
	TContinue(span:SourceSpan);
	TSwitch(expression:TypedExpression, cases:Array<TypedSwitchCase>, defaultBranch:Array<TypedStatement>, hasDefault:Bool, span:SourceSpan);
	TIncrement(name:String, delta:Int, span:SourceSpan);
	TCellIncrement(name:String, cellClass:String, valueType:CompilerType, delta:Int, span:SourceSpan);
	TCellCapturedIncrement(name:String, cellClass:String, valueType:CompilerType, delta:Int, span:SourceSpan);
	TExpression(expression:TypedExpression, span:SourceSpan);
}

typedef TypedSwitchCase = {
	final value:TypedExpression;
	final statements:Array<TypedStatement>;
	final enumName:Null<String>;
	final constructorIndex:Int;
	final bindings:Array<TypedSwitchBinding>;
	final span:SourceSpan;
}

typedef TypedSwitchBinding = {final name:String; final type:CompilerType; final index:Int;}
typedef TypedCatch = {final name:String; final type:CompilerType; final statements:Array<TypedStatement>; final span:SourceSpan;}
typedef TypedEnumCase = {final name:String; final params:Array<CompilerType>; final span:SourceSpan;}
typedef TypedEnum = {final name:String; final cases:Array<TypedEnumCase>; final span:SourceSpan;}

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

typedef TypedField = {final name:String; final type:CompilerType; final initializer:Null<TypedExpression>; final isStatic:Bool; final isFinal:Bool; final span:SourceSpan;}

typedef TypedClass = {
	final name:String;
	final base:Null<String>;
	final interfaces:Array<String>;
	final fields:Array<TypedField>;
	final methods:Array<TypedFunction>;
	final span:SourceSpan;
}

typedef TypedInterfaceMethod = {final name:String; final arguments:Array<CompilerType>; final result:CompilerType;}
typedef TypedInterface = {final name:String; final bases:Array<String>; final methods:Array<TypedInterfaceMethod>;}

enum CellStorageKind {
	MutableCapture;
	ExceptionEdge;
}

typedef TypedCell = {final name:String; final valueType:CompilerType; final kind:CellStorageKind;}
typedef TypedCaptureEnvironment = {final name:String; final fields:Array<{name:String, type:CompilerType}>;}
typedef TypedAnonymous = {final name:String; final fields:Array<compiler.types.Type.AnonymousField>;}

typedef TypedProgram = {
	final enums:Array<TypedEnum>;
	final interfaces:Array<TypedInterface>;
	final classes:Array<TypedClass>;
	final functions:Array<TypedFunction>;
	final cells:Array<TypedCell>;
	final captureEnvironments:Array<TypedCaptureEnvironment>;
	final anonymousTypes:Array<TypedAnonymous>;
}
