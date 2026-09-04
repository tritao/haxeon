package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;

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
	TLocal(name:String);
	TAdd(left:TypedExpression, right:TypedExpression);
	TSub(left:TypedExpression, right:TypedExpression);
	TMul(left:TypedExpression, right:TypedExpression);
	TDiv(left:TypedExpression, right:TypedExpression);
	TLess(left:TypedExpression, right:TypedExpression);
	TLessEqual(left:TypedExpression, right:TypedExpression);
	TEqual(left:TypedExpression, right:TypedExpression);
	TCall(name:String, arguments:Array<TypedExpression>);
}

enum TypedStatement {
	TVar(name:String, initializer:TypedExpression, span:SourceSpan);
	TAssign(name:String, value:TypedExpression, span:SourceSpan);
	TReturn(expression:TypedExpression, span:SourceSpan);
	TIf(condition:TypedExpression, thenBranch:Array<TypedStatement>, elseBranch:Array<TypedStatement>, span:SourceSpan);
	TWhile(condition:TypedExpression, body:Array<TypedStatement>, span:SourceSpan);
	TExpression(expression:TypedExpression, span:SourceSpan);
}

typedef TypedFunction = {
	final name:String;
	final arguments:Array<{name:String, type:CompilerType}>;
	final result:CompilerType;
	final statements:Array<TypedStatement>;
	final span:SourceSpan;
}

typedef TypedField = {final name:String; final type:CompilerType; final isStatic:Bool; final isFinal:Bool; final span:SourceSpan;}

typedef TypedClass = {
	final name:String;
	final base:Null<String>;
	final fields:Array<TypedField>;
	final methods:Array<TypedFunction>;
	final span:SourceSpan;
}

typedef TypedProgram = {final classes:Array<TypedClass>; final functions:Array<TypedFunction>;}
