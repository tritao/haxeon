package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.Source.SourceSpan;

class TypedExpression {
    public final expression:TypedExpressionKind;
    public final type:CompilerType;
    public final span:SourceSpan;
    public function new(expression, type, span) { this.expression = expression; this.type = type; this.span = span; }
}

enum TypedExpressionKind {
    TIntLiteral(value:Int);
    TLocal(name:String);
    TAdd(left:TypedExpression, right:TypedExpression);
    TSub(left:TypedExpression, right:TypedExpression);
    TLess(left:TypedExpression, right:TypedExpression);
    TLessEqual(left:TypedExpression, right:TypedExpression);
    TEqual(left:TypedExpression, right:TypedExpression);
    TCall(name:String, arguments:Array<TypedExpression>);
}

enum TypedStatement {
    TVar(name:String, initializer:TypedExpression, span:SourceSpan);
    TReturn(expression:TypedExpression, span:SourceSpan);
    TIf(condition:TypedExpression, thenBranch:Array<TypedStatement>, elseBranch:Array<TypedStatement>, span:SourceSpan);
}

typedef TypedFunction = {
    final name:String;
    final arguments:Array<{name:String, type:CompilerType}>;
    final result:CompilerType;
    final statements:Array<TypedStatement>;
    final span:SourceSpan;
}

typedef TypedProgram = { final functions:Array<TypedFunction>; }
