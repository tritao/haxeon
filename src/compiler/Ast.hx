package compiler;

import compiler.Source.SourceSpan;

enum AstType {
	IntType;
	BoolType;
	FloatType;
	StringType;
	VoidType;
	InferredType;
	NamedType(name:String);
	ArrayType(element:AstType);
	MapType(key:AstType, value:AstType);
	NullableType(element:AstType);
	FunctionType(arguments:Array<AstType>, result:AstType);
	AnonymousType(fields:Array<AstAnonymousField>);
}

typedef AstAnonymousField = {final name:String; final type:AstType; final optional:Bool; final span:SourceSpan;}

typedef AstArgument = {
	final name:String;
	final type:AstType;
	final span:SourceSpan;
	final ?optional:Bool;
	final ?defaultValue:AstExpression;
}

enum AstFieldAccess {
	DefaultAccess;
	NullAccess;
	NeverAccess;
	GetAccess;
	SetAccess;
	DynamicAccess;
}

typedef AstField = {
	final name:String;
	final type:Null<AstType>;
	final initializer:Null<AstExpression>;
	final readAccess:Null<AstFieldAccess>;
	final writeAccess:Null<AstFieldAccess>;
	final isStatic:Bool;
	final isFinal:Bool;
	final span:SourceSpan;
}

typedef AstClass = {
	final name:String;
	final base:Null<String>;
	final interfaces:Array<String>;
	final fields:Array<AstField>;
	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

typedef AstInterface = {
	final name:String;
	final bases:Array<String>;
	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

typedef AstTypeAlias = {final name:String; final type:AstType; final span:SourceSpan;}
typedef AstEnumParameter = {final name:Null<String>; final type:AstType; final optional:Bool; final span:SourceSpan;}
typedef AstEnumCase = {final name:String; final params:Array<AstEnumParameter>; final span:SourceSpan;}
typedef AstEnum = {final name:String; final cases:Array<AstEnumCase>; final span:SourceSpan;}
typedef AstCatch = {final name:String; final type:AstType; final statements:Array<AstStatement>; final span:SourceSpan;}

enum AstExpression {
	IntegerLiteral(value:Int, span:SourceSpan);
	FloatLiteral(value:Float, span:SourceSpan);
	StringLiteral(value:String, span:SourceSpan);
	BoolLiteral(value:Bool, span:SourceSpan);
	NullLiteral(span:SourceSpan);
	Variable(name:String, span:SourceSpan);
	Member(object:AstExpression, name:String, span:SourceSpan);
	Add(left:AstExpression, right:AstExpression, span:SourceSpan);
	Sub(left:AstExpression, right:AstExpression, span:SourceSpan);
	Mul(left:AstExpression, right:AstExpression, span:SourceSpan);
	Div(left:AstExpression, right:AstExpression, span:SourceSpan);
	Mod(left:AstExpression, right:AstExpression, span:SourceSpan);
	Negate(value:AstExpression, span:SourceSpan);
	Less(left:AstExpression, right:AstExpression, span:SourceSpan);
	LessEqual(left:AstExpression, right:AstExpression, span:SourceSpan);
	Greater(left:AstExpression, right:AstExpression, span:SourceSpan);
	GreaterEqual(left:AstExpression, right:AstExpression, span:SourceSpan);
	Equal(left:AstExpression, right:AstExpression, span:SourceSpan);
	NotEqual(left:AstExpression, right:AstExpression, span:SourceSpan);
	Not(value:AstExpression, span:SourceSpan);
	And(left:AstExpression, right:AstExpression, span:SourceSpan);
	Or(left:AstExpression, right:AstExpression, span:SourceSpan);
	Conditional(condition:AstExpression, whenTrue:AstExpression, whenFalse:AstExpression, span:SourceSpan);
	BlockExpression(statements:Array<AstStatement>, result:AstExpression, span:SourceSpan);
	ThrowExpression(expression:AstExpression, span:SourceSpan);
	Cast(expression:AstExpression, target:Null<AstType>, span:SourceSpan);
	SwitchExpression(expression:AstExpression, cases:Array<AstSwitchExpressionCase>, defaultExpression:Null<AstExpression>, span:SourceSpan);
	ObjectLiteral(fields:Array<AstObjectField>, span:SourceSpan);
	ArrayLiteral(values:Array<AstExpression>, span:SourceSpan);
	ArrayComprehension(keyName:String, valueName:Null<String>, iterable:AstExpression, condition:Null<AstExpression>, value:AstExpression, span:SourceSpan);
	Range(start:AstExpression, end:AstExpression, span:SourceSpan);
	Call(name:String, arguments:Array<AstExpression>, span:SourceSpan);
	MethodCall(object:AstExpression, name:String, arguments:Array<AstExpression>, span:SourceSpan);
	New(typeName:String, arguments:Array<AstExpression>, span:SourceSpan);
	NewArray(element:AstType, length:AstExpression, span:SourceSpan);
	NewMap(key:AstType, value:AstType, span:SourceSpan);
	Index(array:AstExpression, index:AstExpression, span:SourceSpan);
	PostfixIncrement(target:AstExpression, delta:Int, span:SourceSpan);
	Lambda(arguments:Array<AstArgument>, statements:Array<AstStatement>, span:SourceSpan);
}

typedef AstObjectField = {final name:String; final value:AstExpression; final span:SourceSpan;}
typedef AstSwitchExpressionCase = {final value:AstExpression; final result:AstExpression; final span:SourceSpan;}

enum AstStatement {
	UninitializedDeclaration(name:String, type:AstType, span:SourceSpan);
	VarDeclaration(name:String, ?type:AstType, initializer:AstExpression, span:SourceSpan);
	Assignment(name:String, expression:AstExpression, span:SourceSpan);
	IndexAssignment(array:AstExpression, index:AstExpression, expression:AstExpression, span:SourceSpan);
	Return(expression:AstExpression, span:SourceSpan);
	ReturnVoid(span:SourceSpan);
	Throw(expression:AstExpression, span:SourceSpan);
	Try(tryBranch:Array<AstStatement>, catches:Array<AstCatch>, span:SourceSpan);
	If(condition:AstExpression, thenBranch:Array<AstStatement>, elseBranch:Array<AstStatement>, span:SourceSpan);
	While(condition:AstExpression, body:Array<AstStatement>, span:SourceSpan);
	DoWhile(body:Array<AstStatement>, condition:AstExpression, span:SourceSpan);
	ForIn(keyName:String, valueName:Null<String>, iterable:AstExpression, body:Array<AstStatement>, span:SourceSpan);
	Break(span:SourceSpan);
	Continue(span:SourceSpan);
	Switch(expression:AstExpression, cases:Array<AstSwitchCase>, defaultBranch:Array<AstStatement>, hasDefault:Bool, span:SourceSpan);
	Increment(name:String, delta:Int, span:SourceSpan);
	Expression(expression:AstExpression, span:SourceSpan);
}

typedef AstSwitchCase = {
	final value:AstExpression;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

typedef AstFunction = {
	final name:String;
	final isStatic:Bool;
	final ?typeParameters:Array<String>;
	final arguments:Array<AstArgument>;
	final result:AstType;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

typedef AstProgram = {
	final packageName:Null<String>;
	final imports:Array<String>;
	final aliases:Array<AstTypeAlias>;
	final enums:Array<AstEnum>;
	final interfaces:Array<AstInterface>;
	final classes:Array<AstClass>;
	final functions:Array<AstFunction>;
}
