package compiler.types;

import compiler.types.Type.CompilerType;

class TypedExpression {
    public final expression:TypedExpressionKind;
    public final type:CompilerType;
    public function new(expression, type) { this.expression = expression; this.type = type; }
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
    TVar(name:String, initializer:TypedExpression);
    TReturn(expression:TypedExpression);
    TIf(condition:TypedExpression, thenBranch:Array<TypedStatement>, elseBranch:Array<TypedStatement>);
}

typedef TypedFunction = {
    final name:String;
    final arguments:Array<{name:String, type:CompilerType}>;
    final result:CompilerType;
    final statements:Array<TypedStatement>;
}

typedef TypedProgram = { final functions:Array<TypedFunction>; }
