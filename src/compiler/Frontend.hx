package compiler;

import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstStatement;
import compiler.Ast.AstType;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

class Frontend {
    public static function compile(source:String):IrProgram {
        var ast = new Parser(new Lexer(source).tokenize()).parseProgram();
        var signatures:Map<String, AstFunction> = [];
        for (fn in ast.functions) {
            if (signatures.exists(fn.name))
                throw 'Duplicate function "${fn.name}"';
            signatures.set(fn.name, fn);
        }
        var main = signatures.get("main");
        if (main == null || main.arguments.length != 0)
            throw "Program must define function main():Int";

        var program = new IrProgram("__entry");
        program.natives.push({
            name: "__exit",
            library: "std",
            symbol: "sys_exit",
            arguments: [IrType.I32],
            result: IrType.Void,
        });
        for (fn in ast.functions)
            program.functions.push(lowerFunction(fn, signatures));

        var entry = new IrBuilder();
        var result = entry.call("main", [], IrType.I32);
        var exited = entry.call("__exit", [result], IrType.Void);
        entry.returnValue(exited);
        program.functions.push(new IrFunction("__entry", [], IrType.Void, entry.instructions));
        return program;
    }

    static function lowerFunction(fn:AstFunction, signatures:Map<String, AstFunction>):IrFunction {
        var builder = new IrBuilder();
        var values:Map<String, IrValue> = [];
        var arguments = [];
        for (argument in fn.arguments) {
            if (values.exists(argument.name))
                throw 'Duplicate argument "${argument.name}" in function ${fn.name}';
            var value = new IrValue(argument.name, lowerType(argument.type));
            values.set(argument.name, value);
            arguments.push(value);
        }

        var returned = false;
        for (statement in fn.statements) {
            if (returned)
                throw 'Unreachable statement after return in function ${fn.name}';
            switch statement {
                case VarDeclaration(name, declaredType, initializer):
                    if (values.exists(name))
                        throw 'Duplicate local "$name" in function ${fn.name}';
                    var value = lowerExpression(initializer, builder, values, signatures);
                    if (declaredType != null && lowerType(declaredType) != value.type)
                        throw 'Type mismatch for local "$name" in function ${fn.name}';
                    values.set(name, value);
                case Return(expression):
                    var value = lowerExpression(expression, builder, values, signatures);
                    if (value.type != lowerType(fn.result))
                        throw 'Return type mismatch in function ${fn.name}';
                    builder.returnValue(value);
                    returned = true;
            }
        }
        if (!returned)
            throw 'Function ${fn.name} has no return';
        return new IrFunction(fn.name, arguments, lowerType(fn.result), builder.instructions);
    }

    static function lowerExpression(
        expression:AstExpression,
        builder:IrBuilder,
        values:Map<String, IrValue>,
        signatures:Map<String, AstFunction>
    ):IrValue {
        return switch expression {
            case IntegerLiteral(value): builder.constInt(value);
            case Variable(name):
                var value = values.get(name);
                if (value == null) throw 'Unknown variable "$name"';
                value;
            case Add(left, right):
                builder.add(requireInt(lowerExpression(left, builder, values, signatures)),
                    requireInt(lowerExpression(right, builder, values, signatures)));
            case Sub(left, right):
                builder.sub(requireInt(lowerExpression(left, builder, values, signatures)),
                    requireInt(lowerExpression(right, builder, values, signatures)));
            case Call(name, arguments):
                var signature = signatures.get(name);
                if (signature == null) throw 'Unknown function "$name"';
                if (arguments.length != signature.arguments.length)
                    throw 'Function "$name" expects ${signature.arguments.length} arguments, got ${arguments.length}';
                var lowered = [];
                for (i in 0...arguments.length) {
                    var argument = lowerExpression(arguments[i], builder, values, signatures);
                    if (argument.type != lowerType(signature.arguments[i].type))
                        throw 'Argument ${i + 1} to "$name" has the wrong type';
                    lowered.push(argument);
                }
                builder.call(name, lowered, lowerType(signature.result));
        }
    }

    static function requireInt(value:IrValue):IrValue {
        if (value.type != IrType.I32)
            throw "Arithmetic requires Int operands";
        return value;
    }

    static function lowerType(type:AstType):IrType {
        return switch type {
            case IntType: IrType.I32;
        }
    }
}
