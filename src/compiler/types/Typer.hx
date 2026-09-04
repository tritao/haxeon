package compiler.types;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstProgram;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;

class Typer {
    final signatures:Map<String, AstFunction> = [];

    public static function type(program:AstProgram):TypedProgram return new Typer().typeProgram(program);
    function new() {}

    function typeProgram(program:AstProgram):TypedProgram {
        for (fn in program.functions) {
            if (signatures.exists(fn.name)) throw 'Duplicate function "${fn.name}"';
            signatures.set(fn.name, fn);
        }
        var main = signatures.get("main");
        if (main == null || main.arguments.length != 0 || lowerType(main.result) != TInt)
            throw "Program must define function main():Int";
        return {functions: [for (fn in program.functions) typeFunction(fn)]};
    }

    function typeFunction(fn:AstFunction):TypedFunction {
        var scope = new Scope();
        var arguments = [];
        for (argument in fn.arguments) {
            var type = lowerType(argument.type);
            scope.define(argument.name, type);
            arguments.push({name: argument.name, type: type});
        }
        var result = lowerType(fn.result);
        var statements = typeStatements(fn.statements, scope, result);
        if (!alwaysReturns(statements)) throw 'Function ${fn.name} does not return on every path';
        return {name: fn.name, arguments: arguments, result: result, statements: statements, span: fn.span};
    }

    function typeStatements(statements:Array<AstStatement>, scope:Scope, result:CompilerType):Array<TypedStatement> {
        var output = [];
        for (statement in statements) switch statement {
            case VarDeclaration(name, declared, initializer, span):
                var value = typeExpression(initializer, scope);
                if (declared != null && lowerType(declared) != value.type) throw 'Type mismatch for local "$name"';
                scope.define(name, value.type);
                output.push(TVar(name, value, span));
            case Return(expression, span):
                var value = typeExpression(expression, scope);
                if (value.type != result) throw "Return type mismatch";
                output.push(TReturn(value, span));
            case If(condition, thenBranch, elseBranch, span):
                var typedCondition = typeExpression(condition, scope);
                if (typedCondition.type != TBool) throw "If condition must be Bool";
                output.push(TIf(typedCondition,
                    typeStatements(thenBranch, new Scope(scope), result),
                    typeStatements(elseBranch, new Scope(scope), result), span));
        }
        return output;
    }

    function typeExpression(expression:AstExpression, scope:Scope):TypedExpression return switch expression {
        case IntegerLiteral(value, span): new TypedExpression(TIntLiteral(value), TInt, span);
        case Variable(name, span):
            var type = scope.resolve(name);
            if (type == null) throw 'Unknown variable "$name"';
            new TypedExpression(TLocal(name), type, span);
        case Add(left, right, span): arithmetic(left, right, scope, true, span);
        case Sub(left, right, span): arithmetic(left, right, scope, false, span);
        case Less(left, right, span): comparison(left, right, scope, 0, span);
        case LessEqual(left, right, span): comparison(left, right, scope, 1, span);
        case Equal(left, right, span): comparison(left, right, scope, 2, span);
        case Call(name, arguments, span):
            var signature = signatures.get(name);
            if (signature == null) throw 'Unknown function "$name"';
            if (arguments.length != signature.arguments.length) throw 'Function "$name" expects ${signature.arguments.length} arguments, got ${arguments.length}';
            var typed = [for (argument in arguments) typeExpression(argument, scope)];
            for (i in 0...typed.length) if (typed[i].type != lowerType(signature.arguments[i].type)) throw 'Argument ${i + 1} to "$name" has the wrong type';
            new TypedExpression(TCall(name, typed), lowerType(signature.result), span);
    }

    function arithmetic(a, b, scope, add, span):TypedExpression {
        var left = typeExpression(a, scope), right = typeExpression(b, scope);
        if (left.type != TInt || right.type != TInt) throw "Arithmetic requires Int operands";
        return new TypedExpression(add ? TAdd(left, right) : TSub(left, right), TInt, span);
    }

    function comparison(a, b, scope, operation, span):TypedExpression {
        var left = typeExpression(a, scope), right = typeExpression(b, scope);
        if (left.type != TInt || right.type != TInt) throw "Comparison requires Int operands";
        return new TypedExpression(switch operation { case 0: TLess(left,right); case 1: TLessEqual(left,right); default: TEqual(left,right); }, TBool, span);
    }

    static function alwaysReturns(statements:Array<TypedStatement>):Bool {
        for (statement in statements) switch statement {
            case TReturn(_, _): return true;
            case TIf(_, yes, no, _): if (no.length > 0 && alwaysReturns(yes) && alwaysReturns(no)) return true;
            default:
        }
        return false;
    }

    static function lowerType(type:AstType):CompilerType return switch type { case IntType: TInt; case BoolType: TBool; };
}
