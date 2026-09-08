package compiler.ir.codec;

import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrValue;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;
import compiler.ir.IrFunction;
import compiler.ir.codec.IrInstructionCodec;
import compiler.ir.codec.IrTerminatorCodec;
import compiler.ir.codec.IrTypeCodec;
import compiler.ir.codec.IrValueTableCodec;
import compiler.ir.IrVerifier;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceLocation;
import compiler.ir.SourceProvenance.SourceOrigin;

/** Deterministic framing for a complete SSA IR function. */
class IrFunctionStateCodec {
	static inline final VERSION = 5;
	static inline final MAX_BLOCKS = 0x100000;
	static inline final MAX_INSTRUCTIONS = 0x1000000;

	public static function encode(fn:IrFunction):Bytes {
		var values:Map<Int, IrValue> = [];
		for (argument in fn.arguments)
			collectValue(argument, values);
		for (binding in fn.debugBindings)
			collectValue(binding.value, values);
		for (block in fn.blocks) {
			for (instruction in block.instructions)
				collectInstruction(instruction.value, values);
			var terminator = block.terminator;
			if (terminator != null)
				collectTerminator(terminator.value, values);
		}
		var valueBytes = IrValueTableCodec.encode([for (_ => value in values) value]),
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
		output.writeInt32(fn.debugBindings.length);
		for (binding in fn.debugBindings) {
			IrTypeCodec.writeString(output, binding.identity);
			IrTypeCodec.writeString(output, binding.name);
			IrValueTableCodec.writeReference(output, binding.value);
			IrTypeCodec.writeString(output, binding.path);
			output.writeInt32(binding.scopeStart);
			output.writeInt32(binding.scopeEnd);
		}
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
			for (instruction in block.instructions) {
				writeBytes(output, IrInstructionCodec.encode(instruction.value));
				writeProvenance(output, instruction.provenance);
			}
			var blockTerminator = block.terminator;
			if (blockTerminator == null)
				throw "IR block has no terminator";
			var terminator = new BytesOutput();
			terminator.bigEndian = false;
			IrTerminatorCodec.write(terminator, blockTerminator.value);
			writeBytes(output, terminator.getBytes());
			writeProvenance(output, blockTerminator.provenance);
		}
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):IrFunction {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "IRF")
				throw "Invalid IR function state";
			var version = input.readByte();
			if (version < 1 || version > VERSION)
				throw "Unsupported IR function state version";
			var valuesArray = IrValueTableCodec.decode(readBytes(input, bytes.length)),
				values = IrValueTableCodec.byId(valuesArray),
				name = IrTypeCodec.readString(input, bytes.length),
				argumentCount = input.readInt32();
			if (argumentCount < 0 || argumentCount > IrValueTableCodec.MAX_VALUES)
				throw "Invalid IR function argument count";
			var arguments = [for (_ in 0...argumentCount) IrValueTableCodec.readReference(input, values)],
				result = IrTypeCodec.readType(input, bytes.length, 0),
				debugBindings:Array<compiler.ir.IrFunction.IrDebugBinding> = [];
			if (version >= 3) {
				var bindingCount = input.readInt32();
				if (bindingCount < 0 || bindingCount > IrValueTableCodec.MAX_VALUES)
					throw "Invalid IR debug binding count";
				for (_ in 0...bindingCount) {
					var identity = version >= 4 ? IrTypeCodec.readString(input, bytes.length) : "",
						name = IrTypeCodec.readString(input, bytes.length),
						value = IrValueTableCodec.readReference(input, values);
					debugBindings.push(version >= 4 ? {
						identity: identity,
						name: name,
						value: value,
						path: IrTypeCodec.readString(input, bytes.length),
						scopeStart: input.readInt32(),
						scopeEnd: input.readInt32()
					} : {
						identity: name,
						name: name,
						value: value,
						path: "",
						scopeStart: -1,
						scopeEnd: -1
						});
				}
			}
			var blockCount = input.readInt32();
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
				for (_ in 0...instructionCount) {
					var instruction = IrInstructionCodec.decode(readBytes(input, bytes.length), values),
						provenance = version >= 2 ? readProvenance(input, bytes.length, version) : SourceProvenance.generated("legacy-ir-cache");
					block.instructions.push(new Located(instruction, provenance));
				}
				var terminatorBytes = readBytes(input, bytes.length),
					terminatorInput = new BytesInput(terminatorBytes);
				terminatorInput.bigEndian = false;
				var decodedTerminator = IrTerminatorCodec.read(terminatorInput, values, blockIds);
				block.terminator = new Located(decodedTerminator,
					version >= 2 ? readProvenance(input, bytes.length, version) : SourceProvenance.generated("legacy-ir-cache"));
				if (terminatorInput.position != terminatorBytes.length)
					throw "Trailing IR terminator data";
			}
			if (input.position != bytes.length)
				throw "Trailing IR function state data";
			return new IrFunction(name, arguments, result, blocks, debugBindings);
		} catch (error:haxe.io.Eof) {
			throw "Truncated IR function state";
		}
	}

	static function writeProvenance(output:BytesOutput, provenance:SourceProvenance):Void {
		var location = provenance.location;
		output.writeByte(location == null ? 0 : 1);
		if (location != null) {
			IrTypeCodec.writeString(output, location.path);
			output.writeInt32(location.start);
			output.writeInt32(location.end);
			output.writeInt32(location.line);
			output.writeInt32(location.column);
			output.writeInt32(location.endLine);
			output.writeInt32(location.endColumn);
			output.writeInt32(location.sourceHash);
		}
		switch provenance.origin {
			case UserSource:
				output.writeByte(0);
			case CompilerGenerated(reason):
				output.writeByte(1);
				IrTypeCodec.writeString(output, reason);
		}
	}

	static function readProvenance(input:BytesInput, limit:Int, version:Int):SourceProvenance {
		var hasLocation = input.readByte();
		if (hasLocation != 0 && hasLocation != 1)
			throw "Invalid IR provenance location flag";
		var location:Null<SourceLocation> = null;
		if (hasLocation == 1)
			location = versionedLocation(input, limit, version);
		var origin:SourceOrigin = switch input.readByte() {
			case 0: UserSource;
			case 1: CompilerGenerated(IrTypeCodec.readString(input, limit));
			default: throw "Invalid IR provenance origin";
		};
		return new SourceProvenance(location, origin);
	}

	static function versionedLocation(input:BytesInput, limit:Int, version:Int):SourceLocation {
		var path = IrTypeCodec.readString(input, limit),
			start = input.readInt32(),
			end = input.readInt32(),
			line = input.readInt32();
		return version >= 5 ? new SourceLocation(path, start, end, line, input.readInt32(), input.readInt32(), input.readInt32(),
			input.readInt32()) : new SourceLocation(path, start, end, line);
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

	static function collectInstruction(instruction:IrInstruction, values:Map<Int, IrValue>):Void {
		switch instruction {
			case Phi(output, inputs):
				collectValue(output, values);
				for (input in inputs)
					collectValue(input.value, values);
			case ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), ConstBool(output, _), ConstNull(output),
				TypeValue(output, _), Catch(output), GlobalGet(output, _), StaticClosure(output, _), NewObject(output, _):
				collectValue(output, values);
			case ToDyn(output, value), IntToFloat(output, value), SafeCast(output, value), InstanceClosure(output, _, value), ToVirtual(output, value),
				ArraySize(output, value), EnumIndex(output, value), EnumField(output, value, _, _):
				collectValue(output, values);
				collectValue(value, values);
			case Add(output, left, right), Sub(output, left, right), Mul(output, left, right), Div(output, left, right), Mod(output, left, right),
				BitAnd(output, left, right), BitXor(output, left, right), BitOr(output, left, right), ShiftLeft(output, left, right),
				ShiftRight(output, left, right), UnsignedShiftRight(output, left, right), Less(output, left, right), LessEqual(output, left, right),
				Equal(output, left, right), ArrayGet(output, left, right):
				collectValue(output, values);
				collectValue(left, values);
				collectValue(right, values);
			case Call(output, _, arguments), CallClosure(output, _, arguments), MethodCall(output, _, _, arguments), MakeEnum(output, _, _, arguments):
				collectValue(output, values);
				for (argument in arguments)
					collectValue(argument, values);
				switch instruction {
					case CallClosure(_, closure, _): collectValue(closure, values);
					case MethodCall(_, object, _, _): collectValue(object, values);
					default:
				}
			case GlobalSet(_, value):
				collectValue(value, values);
			case FieldGet(output, object, _):
				collectValue(output, values);
				collectValue(object, values);
			case FieldSet(object, _, value):
				collectValue(object, values);
				collectValue(value, values);
			case ArraySet(array, index, value):
				collectValue(array, values);
				collectValue(index, values);
				collectValue(value, values);
			case BeginTry(_, _), EndTry(_):
		}
	}

	static function collectTerminator(terminator:IrTerminator, values:Map<Int, IrValue>):Void {
		switch terminator {
			case Return(value), Throw(value), Rethrow(value), Branch(value, _, _):
				collectValue(value, values);
			case Jump(_):
		}
	}

	static function collectValue(value:IrValue, values:Map<Int, IrValue>):Void {
		var id:Int = value.id;
		if (values.exists(id)) {
			var previous = values.get(id);
			if (previous.name != value.name || Std.string(previous.type) != Std.string(value.type))
				throw "Conflicting IR value identity";
		}
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
