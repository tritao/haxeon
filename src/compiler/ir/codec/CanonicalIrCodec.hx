package compiler.ir.codec;

import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrEnumCase;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrInterfaceMethod;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrObjectMethod;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrStaticField;
import compiler.ir.Ir.IrType;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Stable target-neutral container for the complete verified Haxeon IR. */
class CanonicalIrCodec {
	public static inline final VERSION:Int = 5;
	static inline final MAGIC = "HIR";
	static inline final MAX_ITEMS = 0x100000;

	public static function encode(program:IrProgram):Bytes {
		IrVerifier.verify(program);
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString(MAGIC);
		output.writeByte(VERSION);
		IrTypeCodec.writeString(output, program.entryPoint);
		writeNatives(output, program.natives);
		writeCNatives(output, program.cNatives);
		writeObjects(output, program.objects);
		writeInterfaces(output, program.interfaces);
		writeEnums(output, program.enums);
		writeStaticFields(output, program.staticFields);
		writeFunctions(output, program.functions);
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):IrProgram {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != MAGIC)
				throw "Invalid canonical Haxeon IR";
			var version = input.readByte();
			if (version < 1 || version > VERSION)
				throw "Unsupported canonical Haxeon IR version";
			var program = new IrProgram(IrTypeCodec.readString(input, bytes.length));
			program.natives = readNatives(input, bytes.length);
			program.cNatives = version >= 2 ? readCNatives(input, bytes.length, version) : [];
			program.objects = readObjects(input, bytes.length);
			program.interfaces = readInterfaces(input, bytes.length);
			program.enums = readEnums(input, bytes.length);
			program.staticFields = readStaticFields(input, bytes.length);
			program.functions = readFunctions(input, bytes.length);
			if (input.position != bytes.length)
				throw "Trailing canonical Haxeon IR data";
			IrVerifier.verify(program);
			return program;
		} catch (error:haxe.io.Eof) {
			throw "Truncated canonical Haxeon IR";
		}
	}

	static function writeNatives(output:BytesOutput, natives:Array<IrNative>):Void {
		writeCount(output, natives.length);
		for (native in natives) {
			IrTypeCodec.writeString(output, native.name);
			IrTypeCodec.writeString(output, native.library);
			IrTypeCodec.writeString(output, native.symbol);
			writeTypes(output, native.arguments);
			IrTypeCodec.writeType(output, native.result, 0);
		}
	}

	static function readNatives(input:BytesInput, limit:Int):Array<IrNative> {
		var result:Array<IrNative> = [];
		for (_ in 0...readCount(input))
			result.push({
				name: IrTypeCodec.readString(input, limit),
				library: IrTypeCodec.readString(input, limit),
				symbol: IrTypeCodec.readString(input, limit),
				arguments: readTypes(input, limit),
				result: IrTypeCodec.readType(input, limit, 0)
			});
		return result;
	}

	static function writeCNatives(output:BytesOutput, natives:Array<IrCNative>):Void {
		writeCount(output, natives.length);
		for (native in natives) {
			IrTypeCodec.writeString(output, native.name);
			IrTypeCodec.writeString(output, native.library);
			IrTypeCodec.writeString(output, native.symbol);
			IrTypeCodec.writeString(output, native.signature);
			IrTypeCodec.writeString(output, native.pointerOwnership);
			writeNullableString(output, native.pointerRelease);
			writeNullableString(output, native.pointerLength);
			output.writeByte(native.pointerNullable ? 1 : 0);
			writeTypes(output, native.arguments);
			writeCount(output, native.argumentModes.length);
			for (mode in native.argumentModes)
				switch mode {
					case Value:
						output.writeByte(0);
					case BytesInput(lengthArgument):
						output.writeByte(1);
						writeCount(output, lengthArgument);
					case BytesOutput(lengthArgument):
						output.writeByte(2);
						writeCount(output, lengthArgument);
					case Output:
						output.writeByte(3);
					case InputOutput:
						output.writeByte(4);
					case BytesInputOutput(lengthArgument):
						output.writeByte(5);
						writeCount(output, lengthArgument);
				}
			IrTypeCodec.writeType(output, native.result, 0);
		}
	}

	static function readCNatives(input:BytesInput, limit:Int, version:Int):Array<IrCNative> {
		var result:Array<IrCNative> = [];
		for (_ in 0...readCount(input)) {
			var name = IrTypeCodec.readString(input, limit),
				library = IrTypeCodec.readString(input, limit),
				symbol = IrTypeCodec.readString(input, limit),
				signature = IrTypeCodec.readString(input, limit),
				pointerOwnership = IrTypeCodec.readString(input, limit),
				pointerRelease = readNullableString(input, limit),
				pointerLength = readNullableString(input, limit),
				pointerNullable = input.readByte(),
				arguments = readTypes(input, limit),
				argumentModes:Array<IrCNativeArgumentMode> = [];
			if (pointerNullable != 0 && pointerNullable != 1)
				throw "Invalid canonical IR native nullability";
			if (version >= 5) {
				var modeCount = readCount(input);
				if (modeCount != arguments.length)
					throw "Canonical IR C native argument mode count does not match its signature";
				for (_ in 0...modeCount)
					argumentModes.push(switch input.readByte() {
						case 0: Value;
						case 1: BytesInput(readCount(input));
						case 2: BytesOutput(readCount(input));
						case 3: Output;
						case 4: InputOutput;
						case 5: BytesInputOutput(readCount(input));
						case _: throw "Invalid canonical IR C native argument mode";
					});
			} else {
				for (_ in 0...arguments.length)
					argumentModes.push(Value);
			}
			result.push({
				name: name,
				library: library,
				symbol: symbol,
				signature: signature,
				pointerOwnership: pointerOwnership,
				pointerRelease: pointerRelease,
				pointerLength: pointerLength,
				pointerNullable: pointerNullable == 1,
				arguments: arguments,
				argumentModes: argumentModes,
				result: IrTypeCodec.readType(input, limit, 0)
			});
		}
		return result;
	}

	static function writeObjects(output:BytesOutput, objects:Array<IrObject>):Void {
		writeCount(output, objects.length);
		for (object in objects) {
			IrTypeCodec.writeString(output, object.name);
			output.writeByte(object.isValue ? 1 : 0);
			writeNullableString(output, object.base);
			writeStrings(output, object.interfaces);
			writeCount(output, object.fields.length);
			for (field in object.fields) {
				IrTypeCodec.writeString(output, field.name);
				IrTypeCodec.writeType(output, field.type, 0);
			}
			writeCount(output, object.methods.length);
			for (method in object.methods) {
				IrTypeCodec.writeString(output, method.name);
				IrTypeCodec.writeString(output, method.functionName);
			}
		}
	}

	static function readObjects(input:BytesInput, limit:Int):Array<IrObject> {
		var result:Array<IrObject> = [];
		for (_ in 0...readCount(input)) {
			var name = IrTypeCodec.readString(input, limit),
				isValue = input.readByte() != 0,
				base = readNullableString(input, limit),
				interfaces = readStrings(input, limit),
				fields:Array<IrObjectField> = [],
				methods:Array<IrObjectMethod> = [];
			for (_ in 0...readCount(input))
				fields.push({name: IrTypeCodec.readString(input, limit), type: IrTypeCodec.readType(input, limit, 0)});
			for (_ in 0...readCount(input))
				methods.push({name: IrTypeCodec.readString(input, limit), functionName: IrTypeCodec.readString(input, limit)});
			result.push({
				name: name,
				isValue: isValue,
				base: base,
				interfaces: interfaces,
				fields: fields,
				methods: methods
			});
		}
		return result;
	}

	static function writeInterfaces(output:BytesOutput, interfaces:Array<IrInterface>):Void {
		writeCount(output, interfaces.length);
		for (interfaceDecl in interfaces) {
			IrTypeCodec.writeString(output, interfaceDecl.name);
			writeStrings(output, interfaceDecl.bases);
			writeCount(output, interfaceDecl.methods.length);
			for (method in interfaceDecl.methods) {
				IrTypeCodec.writeString(output, method.name);
				writeTypes(output, method.arguments);
				IrTypeCodec.writeType(output, method.result, 0);
			}
		}
	}

	static function readInterfaces(input:BytesInput, limit:Int):Array<IrInterface> {
		var result:Array<IrInterface> = [];
		for (_ in 0...readCount(input)) {
			var methods:Array<IrInterfaceMethod> = [],
				name = IrTypeCodec.readString(input, limit),
				bases = readStrings(input, limit);
			for (_ in 0...readCount(input))
				methods.push({name: IrTypeCodec.readString(input, limit), arguments: readTypes(input, limit), result: IrTypeCodec.readType(input, limit, 0)});
			result.push({name: name, bases: bases, methods: methods});
		}
		return result;
	}

	static function writeEnums(output:BytesOutput, enums:Array<IrEnum>):Void {
		writeCount(output, enums.length);
		for (enumDecl in enums) {
			IrTypeCodec.writeString(output, enumDecl.name);
			writeCount(output, enumDecl.cases.length);
			for (constructor in enumDecl.cases) {
				IrTypeCodec.writeString(output, constructor.name);
				writeTypes(output, constructor.params);
			}
		}
	}

	static function readEnums(input:BytesInput, limit:Int):Array<IrEnum> {
		var result:Array<IrEnum> = [];
		for (_ in 0...readCount(input)) {
			var cases:Array<IrEnumCase> = [],
				name = IrTypeCodec.readString(input, limit);
			for (_ in 0...readCount(input))
				cases.push({name: IrTypeCodec.readString(input, limit), params: readTypes(input, limit)});
			result.push({name: name, cases: cases});
		}
		return result;
	}

	static function writeStaticFields(output:BytesOutput, fields:Array<IrStaticField>):Void {
		writeCount(output, fields.length);
		for (field in fields) {
			IrTypeCodec.writeString(output, field.name);
			IrTypeCodec.writeType(output, field.type, 0);
		}
	}

	static function readStaticFields(input:BytesInput, limit:Int):Array<IrStaticField> {
		var result:Array<IrStaticField> = [];
		for (_ in 0...readCount(input))
			result.push({name: IrTypeCodec.readString(input, limit), type: IrTypeCodec.readType(input, limit, 0)});
		return result;
	}

	static function writeFunctions(output:BytesOutput, functions:Array<IrFunction>):Void {
		writeCount(output, functions.length);
		for (fn in functions) {
			var bytes = IrFunctionStateCodec.encode(fn);
			output.writeInt32(bytes.length);
			output.writeBytes(bytes, 0, bytes.length);
		}
	}

	static function readFunctions(input:BytesInput, limit:Int):Array<IrFunction> {
		var result:Array<IrFunction> = [];
		for (_ in 0...readCount(input)) {
			var length = input.readInt32();
			if (length < 0 || length > limit - input.position)
				throw "Invalid canonical IR function length";
			result.push(IrFunctionStateCodec.decode(input.read(length)));
		}
		return result;
	}

	static function writeTypes(output:BytesOutput, types:Array<IrType>):Void {
		writeCount(output, types.length);
		for (type in types)
			IrTypeCodec.writeType(output, type, 0);
	}

	static function readTypes(input:BytesInput, limit:Int):Array<IrType> {
		var result:Array<IrType> = [];
		for (_ in 0...readCount(input))
			result.push(IrTypeCodec.readType(input, limit, 0));
		return result;
	}

	static function writeStrings(output:BytesOutput, values:Array<String>):Void {
		writeCount(output, values.length);
		for (value in values)
			IrTypeCodec.writeString(output, value);
	}

	static function readStrings(input:BytesInput, limit:Int):Array<String> {
		var result:Array<String> = [];
		for (_ in 0...readCount(input))
			result.push(IrTypeCodec.readString(input, limit));
		return result;
	}

	static function writeNullableString(output:BytesOutput, value:Null<String>):Void {
		output.writeByte(value == null ? 0 : 1);
		if (value != null)
			IrTypeCodec.writeString(output, value);
	}

	static function readNullableString(input:BytesInput, limit:Int):Null<String> {
		return switch input.readByte() {
			case 0: null;
			case 1: IrTypeCodec.readString(input, limit);
			default: throw "Invalid nullable canonical IR string";
		};
	}

	static function writeCount(output:BytesOutput, count:Int):Void {
		if (count < 0 || count > MAX_ITEMS)
			throw "Canonical IR collection is too large";
		output.writeInt32(count);
	}

	static function readCount(input:BytesInput):Int {
		var count = input.readInt32();
		if (count < 0 || count > MAX_ITEMS)
			throw "Invalid canonical IR collection size";
		return count;
	}
}
