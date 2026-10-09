package compiler.types;

import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorField;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Versioned container for the descriptors emitted by a compiled program. */
class NativeTypeDescriptorCodec {
	public static inline final FORMAT_VERSION:Int = 1;
	static inline final MAGIC = "HTD";
	static inline final MAX_ITEMS = 0x100000;
	static inline final MAX_DEPTH = 128;

	public static function encode(descriptors:Array<NativeTypeDescriptorData>):Bytes {
		var ordered = orderedDescriptors(descriptors),
			output = new BytesOutput();
		output.bigEndian = false;
		output.writeString(MAGIC);
		output.writeByte(FORMAT_VERSION);
		writeCount(output, ordered.length);
		for (descriptor in ordered) {
			validateDescriptor(descriptor);
			writeCount(output, descriptor.version);
			writeString(output, descriptor.name);
			writeString(output, descriptor.type);
			writeBool(output, descriptor.flat);
			writeBool(output, descriptor.portable);
			writeNullableInt(output, descriptor.size);
			writeNullableInt(output, descriptor.alignment);
			writeStrings(output, descriptor.annotations);
			writeNodes(output, descriptor.fields, 0);
			writeNodes(output, descriptor.arguments, 0);
			writeString(output, descriptor.hash);
		}
		return output.getBytes();
	}

	public static function decode(bytes:Bytes):Array<NativeTypeDescriptorData> {
		var input = new BytesInput(bytes);
		input.bigEndian = false;
		try {
			if (input.readString(3) != MAGIC)
				throw "Invalid native type descriptor artifact";
			var version = input.readByte();
			if (version != FORMAT_VERSION)
				throw 'Unsupported native type descriptor artifact version $version';
			var result:Array<NativeTypeDescriptorData> = [];
			for (_ in 0...readCount(input)) {
				var descriptor:NativeTypeDescriptorData = {
					version: readCount(input),
					name: readString(input, bytes.length),
					type: readString(input, bytes.length),
					flat: readBool(input),
					portable: readBool(input),
					size: readNullableInt(input),
					alignment: readNullableInt(input),
					annotations: readStrings(input, bytes.length),
					fields: readNodes(input, bytes.length, 0),
					arguments: readNodes(input, bytes.length, 0),
					hash: readString(input, bytes.length)
				};
				validateDescriptor(descriptor);
				result.push(descriptor);
			}
			if (input.position != bytes.length)
				throw "Trailing native type descriptor artifact data";
			return orderedDescriptors(result);
		} catch (error:haxe.io.Eof) {
			throw "Truncated native type descriptor artifact";
		}
	}

	/** Stable JSON companion for tests and tooling that inspect the binary artifact. */
	public static function toJson(descriptors:Array<NativeTypeDescriptorData>):String
		return Json.stringify({formatVersion: FORMAT_VERSION, descriptors: orderedDescriptors(descriptors)}, null, "  ") + "\n";

	static function orderedDescriptors(descriptors:Array<NativeTypeDescriptorData>):Array<NativeTypeDescriptorData> {
		var result = descriptors.copy();
		result.sort(function(left, right) {
			var byName = Reflect.compare(left.name, right.name);
			return byName == 0 ? Reflect.compare(left.type, right.type) : byName;
		});
		for (index in 1...result.length)
			if (result[index - 1].name == result[index].name && result[index - 1].type == result[index].type)
				throw 'Duplicate native type descriptor "${result[index].name}" (${result[index].type})';
		return result;
	}

	static function validateDescriptor(descriptor:NativeTypeDescriptorData):Void {
		if (descriptor.version != NativeTypeDescriptor.VERSION)
			throw 'Unsupported native type descriptor schema version ${descriptor.version}';
		if (descriptor.name.length == 0 || descriptor.type.length == 0)
			throw "Native type descriptor name and type must be nonempty";
		var expected = NativeTypeDescriptor.contentHash(descriptor.type, descriptor.name, descriptor.type, descriptor.flat, descriptor.portable,
			descriptor.size, descriptor.alignment, descriptor.annotations, descriptor.fields, descriptor.arguments);
		if (descriptor.hash != expected)
			throw 'Native type descriptor hash mismatch for "${descriptor.name}"';
	}

	static function writeNodes(output:BytesOutput, nodes:Array<NativeTypeDescriptorField>, depth:Int):Void {
		checkDepth(depth);
		writeCount(output, nodes.length);
		for (node in nodes) {
			writeString(output, node.name);
			writeString(output, node.type);
			writeBool(output, node.flat);
			writeBool(output, node.portable);
			writeNullableInt(output, node.size);
			writeNullableInt(output, node.alignment);
			writeNullableInt(output, node.offset);
			writeStrings(output, node.annotations);
			writeNodes(output, node.fields, depth + 1);
			writeNodes(output, node.arguments, depth + 1);
			writeBool(output, node.recursive);
		}
	}

	static function readNodes(input:BytesInput, limit:Int, depth:Int):Array<NativeTypeDescriptorField> {
		checkDepth(depth);
		var result:Array<NativeTypeDescriptorField> = [];
		for (_ in 0...readCount(input))
			result.push({
				name: readString(input, limit),
				type: readString(input, limit),
				flat: readBool(input),
				portable: readBool(input),
				size: readNullableInt(input),
				alignment: readNullableInt(input),
				offset: readNullableInt(input),
				annotations: readStrings(input, limit),
				fields: readNodes(input, limit, depth + 1),
				arguments: readNodes(input, limit, depth + 1),
				recursive: readBool(input)
			});
		return result;
	}

	static function writeStrings(output:BytesOutput, values:Array<String>):Void {
		writeCount(output, values.length);
		for (value in values)
			writeString(output, value);
	}

	static function readStrings(input:BytesInput, limit:Int):Array<String> {
		var result:Array<String> = [];
		for (_ in 0...readCount(input))
			result.push(readString(input, limit));
		return result;
	}

	static function writeString(output:BytesOutput, value:String):Void {
		var bytes = Bytes.ofString(value);
		writeCount(output, bytes.length);
		output.write(bytes);
	}

	static function readString(input:BytesInput, limit:Int):String {
		var length = readCount(input);
		if (length > limit - input.position)
			throw "Truncated native type descriptor artifact";
		return input.readString(length);
	}

	static function writeNullableInt(output:BytesOutput, value:Null<Int>):Void {
		if (value == null)
			output.writeByte(0);
		else {
			output.writeByte(1);
			output.writeInt32(cast value);
		}
	}

	static function readNullableInt(input:BytesInput):Null<Int>
		return switch input.readByte() {
			case 0: null;
			case 1: input.readInt32();
			case _: throw "Invalid nullable integer in native type descriptor artifact";
		};

	static function writeBool(output:BytesOutput, value:Bool):Void
		output.writeByte(value ? 1 : 0);

	static function readBool(input:BytesInput):Bool
		return switch input.readByte() {
			case 0: false;
			case 1: true;
			case _: throw "Invalid boolean in native type descriptor artifact";
		};

	static function writeCount(output:BytesOutput, value:Int):Void {
		if (value < 0 || value > MAX_ITEMS)
			throw 'Native type descriptor item count $value is out of range';
		output.writeInt32(value);
	}

	static function readCount(input:BytesInput):Int {
		var count = input.readInt32();
		if (count < 0 || count > MAX_ITEMS)
			throw 'Native type descriptor item count $count is out of range';
		return count;
	}

	static function checkDepth(depth:Int):Void
		if (depth > MAX_DEPTH)
			throw 'Native type descriptor nesting exceeds $MAX_DEPTH';
}
