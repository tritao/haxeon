package compiler.ir;

import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrValue;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import compiler.ir.IrFunction;

/** Deterministic framing for a complete SSA IR function. */
class IrFunctionStateCodec {
	static inline final VERSION = 1;
	static inline final MAX_BLOCKS = 0x100000;
	static inline final MAX_INSTRUCTIONS = 0x1000000;

	public static function encode(fn:IrFunction):Bytes {
		var values:Map<Int, IrValue> = [];
		for (argument in fn.arguments)
			collectValue(argument, values);
		for (block in fn.blocks) {
			for (instruction in block.instructions)
				collectParameters(Type.enumParameters(instruction), values);
			if (block.terminator != null)
				collectParameters(Type.enumParameters(block.terminator), values);
		}
		var valueBytes = IrValueTableCodec.encode([for (value in values) value]),
			output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("IRF");
		output.writeByte(VERSION);
		writeBytes(output, valueBytes);
		IrTypeCodec.writeString(output, fn.name);
		output.writeInt32(fn.arguments.length);
		for (argument in fn.arguments)
			IrValueTableCodec.writeReference(output, argument);
		IrTypeCodec.writeType(output, fn.result, 0);
		if (fn.blocks.length == 0 || fn.blocks.length > MAX_BLOCKS)
			throw "Invalid IR function block count";
		var blocks:Map<Int, Bool> = [];
		output.writeInt32(fn.blocks.length);
		for (block in fn.blocks) {
			var blockId:Int = block.id;
			if (blockId < 0 || blocks.exists(blockId))
				throw "Duplicate or invalid IR block ID";
			blocks.set(blockId, true);
			output.writeInt32(blockId);
		}
		for (block in fn.blocks) {
			if (block.instructions.length > MAX_INSTRUCTIONS)
				throw "Too many IR instructions";
			output.writeInt32(block.instructions.length);
			for (instruction in block.instructions)
				writeBytes(output, IrInstructionCodec.encode(instruction));
			if (block.terminator == null)
				throw "IR block has no terminator";
			var terminator = new BytesOutput();
			terminator.bigEndian = false;
			IrTerminatorCodec.write(terminator, block.terminator);
			writeBytes(output, terminator.getBytes());
		}
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):IrFunction {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "IRF")
				throw "Invalid IR function state";
			if (input.readByte() != VERSION)
				throw "Unsupported IR function state version";
			var valuesArray = IrValueTableCodec.decode(readBytes(input, bytes.length)),
				values = IrValueTableCodec.byId(valuesArray),
				name = IrTypeCodec.readString(input, bytes.length),
				argumentCount = input.readInt32();
			if (argumentCount < 0 || argumentCount > IrValueTableCodec.MAX_VALUES)
				throw "Invalid IR function argument count";
			var arguments = [for (_ in 0...argumentCount) IrValueTableCodec.readReference(input, values)],
				result = IrTypeCodec.readType(input, bytes.length, 0),
				blockCount = input.readInt32();
			if (blockCount <= 0 || blockCount > MAX_BLOCKS)
				throw "Invalid IR function block count";
			var blocks:Array<IrBlock> = [], blockIds:Map<Int, Bool> = [];
			for (_ in 0...blockCount) {
				var id = input.readInt32();
				if (id < 0 || blockIds.exists(id))
					throw "Duplicate or invalid IR block ID";
				blockIds.set(id, true);
				blocks.push(new IrBlock(id));
			}
			for (block in blocks) {
				var instructionCount = input.readInt32();
				if (instructionCount < 0 || instructionCount > MAX_INSTRUCTIONS)
					throw "Invalid IR instruction count";
				for (_ in 0...instructionCount)
					block.instructions.push(IrInstructionCodec.decode(readBytes(input, bytes.length), values));
				var terminatorBytes = readBytes(input, bytes.length),
					terminatorInput = new BytesInput(terminatorBytes);
				terminatorInput.bigEndian = false;
				block.terminator = IrTerminatorCodec.read(terminatorInput, values, blockIds);
				if (terminatorInput.position != terminatorBytes.length)
					throw "Trailing IR terminator data";
			}
			if (input.position != bytes.length)
				throw "Trailing IR function state data";
			return new IrFunction(name, arguments, result, blocks);
		} catch (error:haxe.io.Eof) {
			throw "Truncated IR function state";
		}
	}

	public static function verify(functions:Array<IrFunction>, context:compiler.ir.Ir.IrProgram):Void {
		var program = new compiler.ir.Ir.IrProgram(context.entryPoint);
		program.natives = context.natives;
		program.objects = context.objects;
		program.interfaces = context.interfaces;
		program.enums = context.enums;
		program.staticFields = context.staticFields;
		program.functions = functions;
		IrVerifier.verify(program);
	}

	static function collectParameters(parameters:Array<Dynamic>, values:Map<Int, IrValue>):Void
		for (parameter in parameters)
			if (Std.isOfType(parameter, IrValue))
				collectValue(cast parameter, values);
			else if (parameter is Array)
				for (item in (cast parameter : Array<Dynamic>))
					if (Reflect.hasField(item, "value"))
						collectValue(Reflect.field(item, "value"), values);
					else if (Std.isOfType(item, IrValue))
						collectValue(item, values);

	static function collectValue(value:IrValue, values:Map<Int, IrValue>):Void {
		var id:Int = value.id, previous = values.get(id);
		if (previous != null && (previous.name != value.name || Std.string(previous.type) != Std.string(value.type)))
			throw "Conflicting IR value identity";
		values.set(id, value);
	}

	static function writeBytes(output:BytesOutput, bytes:Bytes):Void {
		output.writeInt32(bytes.length);
		output.write(bytes);
	}

	static function readBytes(input:BytesInput, totalLength:Int):Bytes {
		var length = input.readInt32();
		if (length < 0 || length > 0x10000000 || length > totalLength - input.position)
			throw "Invalid IR function section length";
		return input.read(length);
	}
}
