package compiler.hl;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlCode.HlObjectField;
import compiler.hl.HlCode.HlObjectMethod;
import compiler.hl.HlCode.HlVirtualField;
import compiler.hl.HlCode.HlEnumConstructor;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Explicit persistence for the complete HashLink type-definition table. */
class HlTypeDefStateCodec {
	static inline final MAX_ITEMS = 0x100000;

	public static function encode(types:Array<HlTypeDef>):Bytes {
		var output = new BytesOutput();
		output.bigEndian = false;
		output.writeString("HTD");
		output.writeByte(1);
		writeList(output, types);
		return output.getBytes();
	}

	public static function decode(bytes:Bytes, stringCount:Int, globalCount:Int):Array<HlTypeDef> {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != "HTD" || input.readByte() != 1)
				throw "Invalid HashLink type state";
			var result = readList(input, stringCount, globalCount);
			if (input.position != bytes.length)
				throw "Trailing HashLink type state data";
			validateReferences(result, stringCount, globalCount);
			return result;
		} catch (error:haxe.io.Eof)
			throw "Truncated HashLink type state";
	}

	static function writeList(output:BytesOutput, types:Array<HlTypeDef>):Void {
		if (types.length > MAX_ITEMS)
			throw "Too many HashLink types";
		output.writeInt32(types.length);
		for (type in types)
			switch type {
				case Simple(kind):
					output.writeByte(0);
					output.writeByte(kind);
				case Abstract(name):
					output.writeByte(1);
					output.writeInt32(name);
				case Function(arguments, result):
					output.writeByte(2);
					writeInts(output, arguments);
					output.writeInt32(result);
				case Object(name, base, global, fields, methods, bindings):
					output.writeByte(3);
					output.writeInt32(name);
					output.writeInt32(base);
					output.writeInt32(global);
					output.writeInt32(fields.length);
					for (field in fields) {
						output.writeInt32(field.name);
						output.writeInt32(field.type);
					}
					output.writeInt32(methods.length);
					for (method in methods) {
						output.writeInt32(method.name);
						output.writeInt32(method.functionIndex);
						output.writeInt32(method.prototype);
					}
					writeInts(output, bindings);
				case Virtual(fields):
					output.writeByte(4);
					output.writeInt32(fields.length);
					for (field in fields) {
						output.writeInt32(field.name);
						output.writeInt32(field.type);
					}
				case Enum(name, global, constructors):
					output.writeByte(5);
					output.writeInt32(name);
					output.writeInt32(global);
					output.writeInt32(constructors.length);
					for (constructor in constructors) {
						output.writeInt32(constructor.name);
						writeInts(output, constructor.params);
					}
			}
	}

	static function readList(input:BytesInput, stringCount:Int, globalCount:Int):Array<HlTypeDef> {
		var count = readCount(input), result:Array<HlTypeDef> = [];
		for (_ in 0...count)
			result.push(switch input.readByte() {
				case 0:
					var kind = input.readByte();
					if (kind > 23)
						throw "Invalid HashLink simple type";
					Simple(cast kind);
				case 1: Abstract(input.readInt32());
				case 2: Function(readInts(input), input.readInt32());
				case 3:
					var name = input.readInt32(),
						base = input.readInt32(),
						global = input.readInt32();
					var fields:Array<HlObjectField> = [];
					for (_ in 0...readCount(input))
						fields.push({name: input.readInt32(), type: input.readInt32()});
					var methods:Array<HlObjectMethod> = [];
					for (_ in 0...readCount(input))
						methods.push({name: input.readInt32(), functionIndex: input.readInt32(), prototype: input.readInt32()});
					Object(name, base, global, fields, methods, readInts(input));
				case 4:
					var fields:Array<HlVirtualField> = [];
					for (_ in 0...readCount(input))
						fields.push({name: input.readInt32(), type: input.readInt32()});
					Virtual(fields);
				case 5:
					var name = input.readInt32(), global = input.readInt32();
					var constructors:Array<HlEnumConstructor> = [];
					for (_ in 0...readCount(input))
						constructors.push({name: input.readInt32(), params: readInts(input)});
					Enum(name, global, constructors);
				default: throw "Unknown HashLink type state tag";
			});
		return result;
	}

	static function validateReferences(types:Array<HlTypeDef>, strings:Int, globals:Int):Void {
		for (definition in types)
			switch definition {
				case Simple(_):
				case Abstract(name):
					validateStringReference(name, strings);
				case Function(arguments, result):
					for (argument in arguments)
						validateTypeReference(argument, types.length);
					validateTypeReference(result, types.length);
				case Object(name, base, global, fields, methods, bindings):
					validateStringReference(name, strings);
					if (base >= 0)
						validateTypeReference(base, types.length);
					if (global < 0 || global > globals)
						throw "Invalid HashLink object global";
					for (field in fields) {
						validateStringReference(field.name, strings);
						validateTypeReference(field.type, types.length);
					}
					for (method in methods) {
						validateStringReference(method.name, strings);
						if (method.functionIndex < 0 || method.prototype < 0)
							throw "Invalid HashLink object method";
					}
					for (binding in bindings)
						if (binding < 0)
							throw "Invalid HashLink object binding";
				case Virtual(fields):
					for (field in fields) {
						validateStringReference(field.name, strings);
						validateTypeReference(field.type, types.length);
					}
				case Enum(name, global, constructors):
					validateStringReference(name, strings);
					if (global < 0)
						throw "Invalid HashLink enum global";
					for (constructor in constructors) {
						validateStringReference(constructor.name, strings);
						for (parameter in constructor.params)
							validateTypeReference(parameter, types.length);
					}
			}
	}

	static function validateStringReference(index:Int, count:Int):Void {
		if (index < 0 || index >= count)
			throw "Invalid HashLink type string reference";
	}

	static function validateTypeReference(index:Int, count:Int):Void {
		if (index < 0 || index >= count)
			throw "Invalid HashLink type reference";
	}

	static function writeInts(output:BytesOutput, values:Array<Int>):Void {
		if (values.length > MAX_ITEMS)
			throw "Too many HashLink type references";
		output.writeInt32(values.length);
		for (value in values)
			output.writeInt32(value);
	}

	static function readInts(input:BytesInput):Array<Int>
		return [for (_ in 0...readCount(input)) input.readInt32()];

	static function readCount(input:BytesInput):Int {
		var count = input.readInt32();
		if (count < 0 || count > MAX_ITEMS)
			throw "Invalid HashLink type item count";
		return count;
	}
}
