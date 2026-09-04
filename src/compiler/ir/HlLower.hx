package compiler.ir;

import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;

class HlLower {
    final code:HlCode;
    final typeIndices:Map<String, Int> = [];
    final stringIndices:Map<String, Int> = [];
    final intIndices:Map<Int, Int> = [];
    final functionIndices:Map<String, Int> = [];

    public static function lower(program:IrProgram):HlCode {
        return new HlLower().lowerProgram(program);
    }

    function new() {
        code = new HlCode();
    }

    function lowerProgram(program:IrProgram):HlCode {
        var nextFunction = 0;
        for (native in program.natives)
            addFunctionName(native.name, nextFunction++);
        for (fn in program.functions)
            addFunctionName(fn.name, nextFunction++);

        for (native in program.natives)
            lowerNative(native);
        for (fn in program.functions)
            code.functions.push(lowerFunction(fn));

        code.entryPoint = requireFunction(program.entryPoint);
        return code;
    }

    function lowerNative(native:IrNative):Void {
        code.natives.push({
            library: internString(native.library),
            name: internString(native.symbol),
            type: internFunctionType(native.arguments, native.result),
            functionIndex: requireFunction(native.name),
        });
    }

    function lowerFunction(fn:IrFunction):HlFunction {
        var registers:Map<String, Int> = [];
        var registerTypes:Array<Int> = [];
        for (argument in fn.arguments)
            defineRegister(argument, registers, registerTypes);

        var instructions:Array<HlInstruction> = [];
        for (instruction in fn.instructions) {
            switch instruction {
                case ConstInt(output, value):
                    instructions.push(HlInstruction.LoadInt(defineRegister(output, registers, registerTypes), internInt(value)));
                case Add(output, left, right):
                    instructions.push(HlInstruction.Add(
                        defineRegister(output, registers, registerTypes),
                        requireRegister(left, registers),
                        requireRegister(right, registers)
                    ));
                case Sub(output, left, right):
                    instructions.push(HlInstruction.Sub(
                        defineRegister(output, registers, registerTypes),
                        requireRegister(left, registers),
                        requireRegister(right, registers)
                    ));
                case Less(output, left, right):
                    lowerComparison(output, left, right, 0, registers, registerTypes, instructions);
                case LessEqual(output, left, right):
                    lowerComparison(output, left, right, 1, registers, registerTypes, instructions);
                case Equal(output, left, right):
                    lowerComparison(output, left, right, 2, registers, registerTypes, instructions);
                case Call(output, functionName, arguments):
                    var destination = defineRegister(output, registers, registerTypes);
                    var functionIndex = requireFunction(functionName);
                    var args = [for (argument in arguments) requireRegister(argument, registers)];
                    switch args.length {
                        case 0: instructions.push(HlInstruction.Call0(destination, functionIndex));
                        case 1: instructions.push(HlInstruction.Call1(destination, functionIndex, args[0]));
                        case 2: instructions.push(HlInstruction.Call2(destination, functionIndex, args[0], args[1]));
                        default: throw 'HL lowering supports at most two call arguments, got ${args.length}';
                    }
                case BranchLessOrEqual(left, right, target):
                    instructions.push(HlInstruction.JumpSignedLessOrEqual(
                        requireRegister(left, registers),
                        requireRegister(right, registers),
                        target
                    ));
                case BranchTrue(condition, target):
                    instructions.push(HlInstruction.JumpTrue(requireRegister(condition, registers), target));
                case Jump(target):
                    instructions.push(HlInstruction.Jump(target));
                case Label(name):
                    instructions.push(HlInstruction.Label(name));
                case Return(value):
                    instructions.push(HlInstruction.Return(requireRegister(value, registers)));
            }
        }

        return new HlFunction(
            internFunctionType([for (argument in fn.arguments) argument.type], fn.result),
            requireFunction(fn.name),
            registerTypes,
            instructions
        );
    }

    function lowerComparison(output:IrValue, left:IrValue, right:IrValue, operation:Int,
        registers:Map<String, Int>, registerTypes:Array<Int>, instructions:Array<HlInstruction>):Void {
        var destination = defineRegister(output, registers, registerTypes);
        var leftReg = requireRegister(left, registers), rightReg = requireRegister(right, registers);
        var trueLabel = '__cmp_true_${output.name}', endLabel = '__cmp_end_${output.name}';
        instructions.push(switch operation {
            case 0: HlInstruction.JumpSignedLess(leftReg, rightReg, trueLabel);
            case 1: HlInstruction.JumpSignedLessOrEqual(leftReg, rightReg, trueLabel);
            default: HlInstruction.JumpEqual(leftReg, rightReg, trueLabel);
        });
        instructions.push(HlInstruction.LoadBool(destination, false));
        instructions.push(HlInstruction.Jump(endLabel));
        instructions.push(HlInstruction.Label(trueLabel));
        instructions.push(HlInstruction.LoadBool(destination, true));
        instructions.push(HlInstruction.Label(endLabel));
    }

    function defineRegister(value:IrValue, registers:Map<String, Int>, types:Array<Int>):Int {
        if (registers.exists(value.name))
            throw 'IR value "${value.name}" is defined more than once';
        var index = types.length;
        registers.set(value.name, index);
        types.push(internType(value.type));
        return index;
    }

    function requireRegister(value:IrValue, registers:Map<String, Int>):Int {
        var index = registers.get(value.name);
        if (index == null)
            throw 'IR value "${value.name}" is used before definition';
        return index;
    }

    function internInt(value:Int):Int {
        var existing = intIndices.get(value);
        if (existing != null)
            return existing;
        var index = code.ints.length;
        code.ints.push(value);
        intIndices.set(value, index);
        return index;
    }

    function internString(value:String):Int {
        var existing = stringIndices.get(value);
        if (existing != null)
            return existing;
        var index = code.strings.length;
        code.strings.push(value);
        stringIndices.set(value, index);
        return index;
    }

    function internType(type:IrType):Int {
        var key = typeKey(type);
        var existing = typeIndices.get(key);
        if (existing != null)
            return existing;
        var index = code.types.length;
        code.types.push(Simple(switch type {
            case Void: HlType.Void;
            case I32: HlType.I32;
            case Bool: HlType.Bool;
        }));
        typeIndices.set(key, index);
        return index;
    }

    function internFunctionType(arguments:Array<IrType>, result:IrType):Int {
        var key = 'fun(${[for (argument in arguments) typeKey(argument)].join(",")})->${typeKey(result)}';
        var existing = typeIndices.get(key);
        if (existing != null)
            return existing;
        var argumentTypes = [for (argument in arguments) internType(argument)];
        var resultType = internType(result);
        var index = code.types.length;
        code.types.push(Function(argumentTypes, resultType));
        typeIndices.set(key, index);
        return index;
    }

    function typeKey(type:IrType):String {
        return switch type {
            case Void: "void";
            case I32: "i32";
            case Bool: "bool";
        }
    }

    function addFunctionName(name:String, index:Int):Void {
        if (functionIndices.exists(name))
            throw 'Duplicate IR function "$name"';
        functionIndices.set(name, index);
    }

    function requireFunction(name:String):Int {
        var index = functionIndices.get(name);
        if (index == null)
            throw 'Unknown IR function "$name"';
        return index;
    }
}
