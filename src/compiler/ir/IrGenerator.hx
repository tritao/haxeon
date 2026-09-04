package compiler.ir;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrPhiInput;

class IrGenerator {
    public static function generate(typed:TypedProgram):IrProgram {
        return assemble([for (fn in typed.functions) generateFunction(fn)]);
    }

    public static function generateFunction(fn:TypedFunction):IrFunction {
        var builder = new IrBuilder(), values:Map<String, IrValue> = [];
        for (argument in fn.arguments) {
            var value = builder.argument(argument.name, lowerType(argument.type));
            values.set(argument.name, value);
        }
        lowerStatements(fn.statements, builder, values);
        return new IrFunction(fn.name, builder.arguments, lowerType(fn.result), builder.blocks);
    }

    public static function assemble(functions:Array<IrFunction>,?natives:Array<IrNative>):IrProgram {
        var program = new IrProgram("__entry");
        program.natives.push({name:"__exit", library:"std", symbol:"sys_exit", arguments:[I32], result:Void});
        if(natives!=null)for(native in natives)program.natives.push(native);
        for (fn in functions) program.functions.push(fn);
        var entry = new IrBuilder();
        var result = entry.call("main", [], I32);
        var exited = entry.call("__exit", [result], Void);
        entry.returnValue(exited);
        program.functions.push(new IrFunction("__entry", [], Void, entry.blocks));
        return program;
    }

    static function lowerStatements(statements:Array<TypedStatement>, builder:IrBuilder, values:Map<String, IrValue>):Map<String,IrValue> {
        for (statement in statements) {
            if(builder.isTerminated())break;
            switch statement {
            case TVar(name, initializer, _): values.set(name, lowerExpression(initializer, builder, values));
            case TAssign(name,value,_):values.set(name,lowerExpression(value,builder,values));
            case TReturn(expression, _): builder.returnValue(lowerExpression(expression, builder, values));
            case TIf(condition, thenBranch, elseBranch, _):
                var incoming=copy(values),thenBlock=builder.createBlock(),elseBlock=builder.createBlock(),joinBlock=builder.createBlock();
                builder.branch(lowerExpression(condition, builder, values), thenBlock, elseBlock);
                builder.select(thenBlock);
                var thenValues=lowerStatements(thenBranch,builder,copy(incoming)),thenActive=!builder.isTerminated(),thenPredecessor=builder.currentBlock().id;
                if(thenActive)builder.jump(joinBlock);
                builder.select(elseBlock);
                var elseValues=lowerStatements(elseBranch,builder,copy(incoming)),elseActive=!builder.isTerminated(),elsePredecessor=builder.currentBlock().id;
                if(elseActive)builder.jump(joinBlock);
                if(thenActive||elseActive){builder.select(joinBlock);for(name in incoming.keys()){var yes=thenValues.get(name),no=elseValues.get(name);if(!thenActive)values.set(name,no);else if(!elseActive)values.set(name,yes);else if(yes.id==no.id)values.set(name,yes);else values.set(name,builder.phi(yes.type,[{block:thenPredecessor,value:yes},{block:elsePredecessor,value:no}]));}}
            case TWhile(condition,body,_):
                var entry=builder.currentBlock().id,conditionBlock=builder.createBlock(),bodyBlock=builder.createBlock(),afterBlock=builder.createBlock(),assigned=assignedNames(body);builder.jump(conditionBlock);builder.select(conditionBlock);
                var loopValues=copy(values),phis:Map<String,{output:IrValue,inputs:Array<IrPhiInput>}>=[];
                for(name in assigned.keys())if(values.exists(name)){var inputs=[{block:entry,value:values.get(name)}],output=builder.phi(values.get(name).type,inputs);phis.set(name,{output:output,inputs:inputs});loopValues.set(name,output);}
                builder.branch(lowerExpression(condition,builder,loopValues),bodyBlock,afterBlock);builder.select(bodyBlock);var bodyValues=lowerStatements(body,builder,copy(loopValues));
                if(!builder.isTerminated()){var backedge=builder.currentBlock().id;for(name=>phi in phis)phi.inputs.push({block:backedge,value:bodyValues.get(name)});builder.jump(conditionBlock);}
                builder.select(afterBlock);for(name=>phi in phis)values.set(name,phi.output);
            case TExpression(expression,_):lowerExpression(expression,builder,values);
            }
        }
        return values;
    }

    static function lowerExpression(expression:TypedExpression, builder:IrBuilder, values:Map<String, IrValue>):IrValue return switch expression.expression {
        case TIntLiteral(value): builder.constInt(value);
        case TFloatLiteral(value):builder.constFloat(value);
        case TStringLiteral(value):builder.constString(value);
        case TLocal(name): var value = values.get(name); if (value == null) throw 'Missing typed local "$name"'; value;
        case TAdd(a,b): builder.add(lowerExpression(a,builder,values), lowerExpression(b,builder,values));
        case TSub(a,b): builder.sub(lowerExpression(a,builder,values), lowerExpression(b,builder,values));
        case TMul(a,b):builder.mul(lowerExpression(a,builder,values),lowerExpression(b,builder,values));
        case TDiv(a,b):builder.div(lowerExpression(a,builder,values),lowerExpression(b,builder,values));
        case TLess(a,b): builder.less(lowerExpression(a,builder,values), lowerExpression(b,builder,values));
        case TLessEqual(a,b): builder.lessEqual(lowerExpression(a,builder,values), lowerExpression(b,builder,values));
        case TEqual(a,b): builder.equal(lowerExpression(a,builder,values), lowerExpression(b,builder,values));
        case TCall(name,args): builder.call(name, [for (arg in args) lowerExpression(arg,builder,values)], lowerType(expression.type));
    }

    static function copy(values:Map<String, IrValue>):Map<String, IrValue> {
        var result:Map<String, IrValue> = []; for (name => value in values) result.set(name, value); return result;
    }
    static function assignedNames(statements:Array<TypedStatement>):Map<String,Bool>{var result:Map<String,Bool>=[];for(statement in statements)switch statement{case TAssign(name,_,_):result.set(name,true);case TIf(_,yes,no,_):for(name in assignedNames(yes).keys())result.set(name,true);for(name in assignedNames(no).keys())result.set(name,true);case TWhile(_,body,_):for(name in assignedNames(body).keys())result.set(name,true);default:}return result;}
    static function alwaysReturns(statements:Array<TypedStatement>):Bool {
        for (statement in statements) switch statement {
            case TReturn(_, _): return true;
            case TIf(_, yes, no, _): if (no.length > 0 && alwaysReturns(yes) && alwaysReturns(no)) return true;
            default:
        }
        return false;
    }
    static function lowerType(type:CompilerType):IrType return switch type {case TInt:I32;case TBool:Bool;case TFloat:F64;case TString:Bytes;case TVoid:Void;};
}
