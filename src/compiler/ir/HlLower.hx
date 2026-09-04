package compiler.ir;

import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlType;
import compiler.hl.HlSymbolTable;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;

class HlLower {
    final code:HlCode;
    final symbols:HlSymbolTable;
    final functionIndices:Map<String, Int> = [];

    public static function lower(program:IrProgram):HlCode {
        IrVerifier.verify(program);
        return new HlLower(new HlSymbolTable(), null).lowerProgram(program);
    }

    public static function lowerStable(program:IrProgram, symbols:HlSymbolTable, indices:Map<String,Int>):HlCode {
        IrVerifier.verify(program);
        return new HlLower(symbols, indices).lowerProgram(program);
    }

    function new(symbols:HlSymbolTable, indices:Null<Map<String,Int>>) {
        this.symbols=symbols;
        code = new HlCode();
        code.ints=symbols.ints;code.strings=symbols.strings;code.types=symbols.types;
        if(indices!=null)for(name=>index in indices)functionIndices.set(name,index);
    }

    function lowerProgram(program:IrProgram):HlCode {
        if(functionIndices.keys().hasNext()==false) {
            var nextFunction = 0;
            for (native in program.natives) addFunctionName(native.name, nextFunction++);
            for (fn in program.functions) addFunctionName(fn.name, nextFunction++);
        }

        for (native in program.natives)
            lowerNative(native);
        for (fn in program.functions)
            code.functions.push(lowerFunction(fn));

        code.entryPoint = requireFunction(program.entryPoint);
        code.ints=code.ints.copy();code.strings=code.strings.copy();code.types=code.types.copy();
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
        var registers:Map<Int, Int> = [];
        var registerTypes:Array<Int> = [];
        for (argument in fn.arguments)
            defineRegister(argument, registers, registerTypes);

        var instructions:Array<HlInstruction> = [];
        for (block in fn.blocks) {
            if (block.instructions.length == 0 && block.terminator == null) continue;
            instructions.push(HlInstruction.Label('block_${block.id}'));
            for (instruction in block.instructions) {
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
            }
            }
            if (block.terminator == null) throw 'Reachable IR block ${block.id} has no terminator';
            switch block.terminator {
                case Return(value): instructions.push(HlInstruction.Return(requireRegister(value, registers)));
                case Jump(target): instructions.push(HlInstruction.Jump('block_$target'));
                case Branch(condition, yes, no):
                    instructions.push(HlInstruction.JumpTrue(requireRegister(condition, registers), 'block_$yes'));
                    instructions.push(HlInstruction.Jump('block_$no'));
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
        registers:Map<Int, Int>, registerTypes:Array<Int>, instructions:Array<HlInstruction>):Void {
        var destination = defineRegister(output, registers, registerTypes);
        var leftReg = requireRegister(left, registers), rightReg = requireRegister(right, registers);
        var trueLabel = '__cmp_true_${output.id}', endLabel = '__cmp_end_${output.id}';
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

    function defineRegister(value:IrValue, registers:Map<Int, Int>, types:Array<Int>):Int {
        if (registers.exists(value.id))
            throw 'IR value ${value.id} is defined more than once';
        var index = types.length;
        registers.set(value.id, index);
        types.push(internType(value.type));
        return index;
    }

    function requireRegister(value:IrValue, registers:Map<Int, Int>):Int {
        var index = registers.get(value.id);
        if (index == null)
            throw 'IR value ${value.id} is used before definition';
        return index;
    }

    function internInt(value:Int):Int {
        return symbols.internInt(value);
    }

    function internString(value:String):Int {
        return symbols.internString(value);
    }

    function internType(type:IrType):Int {
        return symbols.internType(type);
    }

    function internFunctionType(arguments:Array<IrType>, result:IrType):Int {
        return symbols.internFunction(arguments,result);
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
