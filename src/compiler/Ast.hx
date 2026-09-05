package compiler;

import compiler.Source.SourceSpan;

enum AstType {
	IntType;
	BoolType;
	FloatType;
	StringType;
	VoidType;
	NamedType(name:String);
	FunctionType(arguments:Array<AstType>, result:AstType);
}

typedef AstArgument = {
	final name:String;
	final type:AstType;
	final span:SourceSpan;
}

typedef AstField = {
	final name:String;
	final type:AstType;
	final isStatic:Bool;
	final isFinal:Bool;
	final span:SourceSpan;
}

typedef AstClass = {
	final name:String;
	final base:Null<String>;
	final fields:Array<AstField>;
	final methods:Array<AstFunction>;
	final span:SourceSpan;
}

enum AstExpression {
	IntegerLiteral(value:Int, span:SourceSpan);
	FloatLiteral(value:Float, span:SourceSpan);
	StringLiteral(value:String, span:SourceSpan);
	Variable(name:String, span:SourceSpan);
	Add(left:AstExpression, right:AstExpression, span:SourceSpan);
	Sub(left:AstExpression, right:AstExpression, span:SourceSpan);
	Mul(left:AstExpression, right:AstExpression, span:SourceSpan);
	Div(left:AstExpression, right:AstExpression, span:SourceSpan);
	Less(left:AstExpression, right:AstExpression, span:SourceSpan);
	LessEqual(left:AstExpression, right:AstExpression, span:SourceSpan);
	Equal(left:AstExpression, right:AstExpression, span:SourceSpan);
	Call(name:String, arguments:Array<AstExpression>, span:SourceSpan);
	New(typeName:String, arguments:Array<AstExpression>, span:SourceSpan);
	Lambda(arguments:Array<AstArgument>, statements:Array<AstStatement>, span:SourceSpan);
}

enum AstStatement {
	VarDeclaration(name:String, ?type:AstType, initializer:AstExpression, span:SourceSpan);
	Assignment(name:String, expression:AstExpression, span:SourceSpan);
	Return(expression:AstExpression, span:SourceSpan);
	If(condition:AstExpression, thenBranch:Array<AstStatement>, elseBranch:Array<AstStatement>, span:SourceSpan);
	While(condition:AstExpression, body:Array<AstStatement>, span:SourceSpan);
	Expression(expression:AstExpression, span:SourceSpan);
}

typedef AstFunction = {
	final name:String;
	final isStatic:Bool;
	final arguments:Array<AstArgument>;
	final result:AstType;
	final statements:Array<AstStatement>;
	final span:SourceSpan;
}

typedef AstProgram = {
	final packageName:Null<String>;
	final imports:Array<String>;
	final classes:Array<AstClass>;
	final functions:Array<AstFunction>;
}
