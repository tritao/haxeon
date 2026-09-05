package compiler.ir;

import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrValue;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Explicit encoding for control-flow terminators in persisted IR functions. */
class IrTerminatorCodec {
	public static function write(output:BytesOutput, terminator:IrTerminator):Void
		switch terminator {
			case Return(value):
				output.writeByte(0);
				IrValueTableCodec.writeReference(output, value);
			case Throw(value):
				output.writeByte(1);
				IrValueTableCodec.writeReference(output, value);
			case Rethrow(value):
				output.writeByte(2);
				IrValueTableCodec.writeReference(output, value);
			case Jump(target):
				output.writeByte(3);
				writeBlock(output, target);
			case Branch(condition, whenTrue, whenFalse):
				output.writeByte(4);
				IrValueTableCodec.writeReference(output, condition);
				writeBlock(output, whenTrue);
				writeBlock(output, whenFalse);
		};

	public static function read(input:BytesInput, values:Map<Int, IrValue>, blocks:Map<Int, Bool>):IrTerminator
		return switch input.readByte() {
			case 0: Return(IrValueTableCodec.readReference(input, values));
			case 1: Throw(IrValueTableCodec.readReference(input, values));
			case 2: Rethrow(IrValueTableCodec.readReference(input, values));
			case 3: Jump(readBlock(input, blocks));
			case 4: Branch(IrValueTableCodec.readReference(input, values), readBlock(input, blocks), readBlock(input, blocks));
			default: throw "Unknown IR terminator tag";
		};

	static function writeBlock(output:BytesOutput, block:Int):Void {
		if (block < 0)
			throw "Invalid IR block reference";
		output.writeInt32(block);
	}

	static function readBlock(input:BytesInput, blocks:Map<Int, Bool>):Int {
		var block = input.readInt32();
		if (block < 0 || !blocks.exists(block))
			throw "Unknown IR block reference";
		return block;
	}
}
