package compiler;

enum AstType {
    IntType;
    BoolType;
}

typedef AstArgument = {
    final name:String;
    final type:AstType;
}

enum AstExpression {
    IntegerLiteral(value:Int);
    Variable(name:String);
    Add(left:AstExpression, right:AstExpression);
    Sub(left:AstExpression, right:AstExpression);
    Less(left:AstExpression, right:AstExpression);
    LessEqual(left:AstExpression, right:AstExpression);
    Equal(left:AstExpression, right:AstExpression);
    Call(name:String, arguments:Array<AstExpression>);
}

enum AstStatement {
    VarDeclaration(name:String, ?type:AstType, initializer:AstExpression);
    Return(expression:AstExpression);
    If(condition:AstExpression, thenBranch:Array<AstStatement>, elseBranch:Array<AstStatement>);
}

typedef AstFunction = {
    final name:String;
    final arguments:Array<AstArgument>;
    final result:AstType;
    final statements:Array<AstStatement>;
}

typedef AstProgram = {
    final functions:Array<AstFunction>;
}
