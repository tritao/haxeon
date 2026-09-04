package compiler.ir;

import compiler.ir.Ir;

class IrVerifier {
    public static function verify(program:IrProgram):Void {
        var signatures:Map<String, {arguments:Array<IrType>, result:IrType}> = [];
        for (native in program.natives) addSignature(signatures, native.name, native.arguments, native.result);
        for (fn in program.functions) addSignature(signatures, fn.name, [for (a in fn.arguments) a.type], fn.result);
        if (!signatures.exists(program.entryPoint)) throw 'Unknown IR entry point "${program.entryPoint}"';
        for (fn in program.functions) verifyFunction(fn, signatures);
    }

    static function verifyFunction(fn:IrFunction, signatures:Map<String, {arguments:Array<IrType>, result:IrType}>):Void {
        if (fn.blocks.length == 0) throw 'IR function ${fn.name} has no entry block';
        var blocks:Map<Int, IrBlock> = [], values:Map<Int, IrType> = [];
        for (block in fn.blocks) {
            if (blocks.exists(block.id)) throw 'Duplicate IR block ${block.id}';
            blocks.set(block.id, block);
        }
        for (argument in fn.arguments) define(values, argument);
        var reachable:Map<Int, Bool> = [], work = [fn.blocks[0].id];
        while (work.length > 0) {
            var id = work.pop();
            if (reachable.exists(id)) continue;
            var block = blocks.get(id);
            if (block == null) throw 'Unknown IR block $id in ${fn.name}';
            reachable.set(id, true);
            for(instruction in block.instructions)switch instruction{case Phi(out,_):define(values,out);default:}
            for (instruction in block.instructions) verifyInstruction(instruction, values, signatures);
            if (block.terminator == null) throw 'Reachable IR block $id in ${fn.name} has no terminator';
            switch block.terminator {
                case Return(value):
                    require(values, value); if (value.type != fn.result) throw 'Wrong return type in ${fn.name}';
                case Jump(target): work.push(target);
                case Branch(condition, yes, no):
                    require(values, condition); if (condition.type != Bool) throw 'IR branch condition is not Bool';
                    work.push(yes); work.push(no);
            }
        }
        var predecessors:Map<Int,Map<Int,Bool>>=[];
        for(block in fn.blocks)if(reachable.exists(block.id)&&block.terminator!=null)switch block.terminator{case Jump(target):addPredecessor(predecessors,target,block.id);case Branch(_,yes,no):addPredecessor(predecessors,yes,block.id);addPredecessor(predecessors,no,block.id);default:}
        for(block in fn.blocks)if(reachable.exists(block.id))for(instruction in block.instructions)switch instruction{case Phi(out,inputs):var expected=predecessors.get(block.id),seen:Map<Int,Bool>=[];if(expected==null||inputs.length!=countKeys(expected))throw 'Phi ${out.id} does not cover every predecessor';for(input in inputs){if(!expected.exists(input.block)||seen.exists(input.block))throw 'Invalid phi predecessor ${input.block}';seen.set(input.block,true);require(values,input.value);if(input.value.type!=out.type)throw 'Wrong phi input type for ${out.id}';}default:}
    }

    static function verifyInstruction(instruction:IrInstruction, values:Map<Int, IrType>, signatures):Void switch instruction {
        case Phi(_, _):
        case ConstInt(out, _): expect(out, I32); define(values, out);
        case ConstFloat(out,_):expect(out,F64);define(values,out);
        case ConstString(out,_):expect(out,Bytes);define(values,out);
        case Add(out,a,b),Sub(out,a,b),Mul(out,a,b),Div(out,a,b):if(out.type!=a.type||a.type!=b.type||(a.type!=I32&&a.type!=F64))throw "IR arithmetic requires matching numeric values";require(values,a);require(values,b);define(values,out);
        case Less(out,a,b), LessEqual(out,a,b), Equal(out,a,b): expect(out,Bool); expect(a,I32); expect(b,I32); require(values,a); require(values,b); define(values,out);
        case Call(out,name,args):
            var signature = signatures.get(name); if (signature == null) throw 'Unknown IR call "$name"';
            if (args.length != signature.arguments.length) throw 'Wrong IR argument count for "$name"';
            for (i in 0...args.length) { require(values,args[i]); if (args[i].type != signature.arguments[i]) throw 'Wrong IR argument type for "$name"'; }
            if (out.type != signature.result) throw 'Wrong IR result type for "$name"'; define(values,out);
    }

    static function addPredecessor(map:Map<Int,Map<Int,Bool>>,target:Int,source:Int):Void{var found=map.get(target);if(found==null){found=[];map.set(target,found);}found.set(source,true);}
    static function countKeys(map:Map<Int,Bool>):Int{var count=0;for(_ in map.keys())count++;return count;}

    static function addSignature(map, name, arguments, result):Void {
        if (map.exists(name)) throw 'Duplicate IR function "$name"'; map.set(name, {arguments:arguments, result:result});
    }
    static function define(values:Map<Int, IrType>, value:IrValue):Void { if (values.exists(value.id)) throw 'Duplicate IR value ${value.id}'; values.set(value.id,value.type); }
    static function require(values:Map<Int, IrType>, value:IrValue):Void { if (!values.exists(value.id)) throw 'IR value ${value.id} is used before definition'; }
    static function expect(value:IrValue, type:IrType):Void { if (value.type != type) throw 'IR value ${value.id} has the wrong type'; }
}
