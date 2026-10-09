package compiler.types;

import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorData;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorField;
import compiler.types.NativeTypeDescriptor.NativeTypeDescriptorDefault;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationData;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationArgument;
import compiler.types.NativeTypeDescriptor.NativeTypeAnnotationValue;
import haxe.Json;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Versioned container for the descriptors emitted by a compiled program. */
class NativeTypeDescriptorCodec {
	public static inline final FORMAT_VERSION:Int = 4;
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
			writeString(output, descriptor.sourceKind);
			writeStrings(output, descriptor.interfaces);
			writeBool(output, descriptor.flat);
			writeBool(output, descriptor.portable);
			writeNullableInt(output, descriptor.size);
			writeNullableInt(output, descriptor.alignment);
			writeStrings(output, descriptor.annotations);
			writeAnnotationValues(output, descriptor.annotationValues);
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
					sourceKind: readString(input, bytes.length),
					interfaces: readStrings(input, bytes.length),
					flat: readBool(input),
					portable: readBool(input),
					size: readNullableInt(input),
					alignment: readNullableInt(input),
					annotations: readStrings(input, bytes.length),
					annotationValues: readAnnotationValues(input, bytes.length),
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
	public static function toJson(descriptors:Array<NativeTypeDescriptorData>):String {
		var replacements:Array<{marker:String, number:String}> = [],
			json = Json.stringify({
				formatVersion: FORMAT_VERSION,
				descriptors: [
					for (descriptor in orderedDescriptors(descriptors))
						descriptorJson(descriptor, replacements)
				]
			}, null, "  ");
		for (replacement in replacements)
			json = StringTools.replace(json, '"${replacement.marker}"', replacement.number);
		return json + "\n";
	}

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
		if (!NativeTypeDescriptor.validSourceKind(descriptor.sourceKind)
			|| !NativeTypeDescriptor.canonicalInterfaces(descriptor.interfaces))
			throw 'Native type descriptor has invalid source conformance facts for "${descriptor.name}"';
		var expected = NativeTypeDescriptor.contentHash(descriptor.type, descriptor.name, descriptor.type, descriptor.sourceKind, descriptor.interfaces,
			descriptor.flat, descriptor.portable, descriptor.size, descriptor.alignment, descriptor.annotations, descriptor.annotationValues,
			descriptor.fields, descriptor.arguments);
		if (descriptor.hash != expected)
			throw 'Native type descriptor hash mismatch for "${descriptor.name}"';
		validateAnnotationValues(descriptor.annotationValues);
		validateNodes(descriptor.fields);
		validateNodes(descriptor.arguments);
	}

	static function validateNodes(nodes:Array<NativeTypeDescriptorField>):Void {
		for (node in nodes) {
			validateAnnotationValues(node.annotationValues);
			validateDefaultValue(node);
			validateNodes(node.fields);
			validateNodes(node.arguments);
		}
	}

	static function validateDefaultValue(node:NativeTypeDescriptorField):Void {
		var descriptorDefault = node.defaultValue;
		if (descriptorDefault == null)
			return;
		var valid = switch descriptorDefault.value {
			case IntValue(value): descriptorDefault.type == "Int" && defaultIntValueAccepted(node, value);
			case FloatValue(value): descriptorDefault.type == "Float" && defaultTypeAccepted(node, "Float") && validFloatDefault(node, value);
			case StringValue(_): descriptorDefault.type == "String" && defaultTypeAccepted(node, "String");
			case BoolValue(_): descriptorDefault.type == "Bool" && defaultTypeAccepted(node, "Bool");
			case NullValue: descriptorDefault.type == "Null" && nullableDefaultType(node);
		};
		if (!valid)
			throw 'Native type descriptor field "${node.name}" default does not match its semantic type';
	}

	static function validFloatDefault(node:NativeTypeDescriptorField, value:Float):Bool {
		if (!Math.isFinite(value))
			return false;
		if (!containsFloat32(node))
			return true;
		var rounded = NativeTypeDescriptor.float32DefaultValue(value);
		return rounded != null && rounded == value;
	}

	static function containsFloat32(node:NativeTypeDescriptorField):Bool {
		if (node.type == "native-scalar:f32")
			return true;
		for (argument in node.arguments)
			if ((argument.name == "representation" || (StringTools.startsWith(node.type, "Null<") && argument.name == "element"))
				&& containsFloat32(argument))
				return true;
		return false;
	}

	static function defaultIntValueAccepted(node:NativeTypeDescriptorField, value:Int):Bool {
		if (node.type == "Int")
			return true;
		var range = NativeTypeDescriptor.narrowIntegerDefaultRange(node.type);
		if (range != null)
			return value >= range.min && value <= range.max;
		for (argument in node.arguments)
			if (argument.name == "representation" || (StringTools.startsWith(node.type, "Null<") && argument.name == "element"))
				if (defaultIntValueAccepted(argument, value))
					return true;
		return false;
	}

	static function defaultTypeAccepted(node:NativeTypeDescriptorField, valueType:String):Bool {
		if (node.type == valueType || (valueType == "Float" && node.type == "native-scalar:f32"))
			return true;
		for (argument in node.arguments)
			if (argument.name == "representation" || (StringTools.startsWith(node.type, "Null<") && argument.name == "element"))
				if (defaultTypeAccepted(argument, valueType))
					return true;
		return false;
	}

	static function nullableDefaultType(node:NativeTypeDescriptorField):Bool {
		if (StringTools.startsWith(node.type, "Null<"))
			return true;
		for (argument in node.arguments)
			if (argument.name == "representation" && nullableDefaultType(argument))
				return true;
		return false;
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
			writeDefault(output, node.defaultValue);
			writeStrings(output, node.annotations);
			writeAnnotationValues(output, node.annotationValues);
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
				defaultValue: readDefault(input, limit),
				annotations: readStrings(input, limit),
				annotationValues: readAnnotationValues(input, limit),
				fields: readNodes(input, limit, depth + 1),
				arguments: readNodes(input, limit, depth + 1),
				recursive: readBool(input)
			});
		return result;
	}

	static function writeAnnotationValues(output:BytesOutput, values:Array<NativeTypeAnnotationData>):Void {
		writeCount(output, values.length);
		for (annotation in values) {
			writeString(output, annotation.name);
			writeCount(output, annotation.arguments.length);
			for (argument in annotation.arguments) {
				writeString(output, argument.name);
				writeString(output, argument.type);
				switch argument.value {
					case IntValue(value):
						output.writeByte(0);
						output.writeInt32(value);
					case FloatValue(value):
						output.writeByte(1);
						output.writeDouble(value);
					case StringValue(value):
						output.writeByte(2);
						writeString(output, value);
					case BoolValue(value):
						output.writeByte(3);
						writeBool(output, value);
					case NullValue:
						output.writeByte(4);
				}
			}
		}
	}

	static function readAnnotationValues(input:BytesInput, limit:Int):Array<NativeTypeAnnotationData> {
		var result:Array<NativeTypeAnnotationData> = [];
		for (_ in 0...readCount(input)) {
			var name = readString(input, limit),
				arguments:Array<NativeTypeAnnotationArgument> = [];
			for (_ in 0...readCount(input)) {
				var argumentName = readString(input, limit),
					type = readString(input, limit),
					value:NativeTypeAnnotationValue = switch input.readByte() {
						case 0: IntValue(input.readInt32());
						case 1: FloatValue(input.readDouble());
						case 2: StringValue(readString(input, limit));
						case 3: BoolValue(readBool(input));
						case 4: NullValue;
						case _: throw "Invalid annotation constant tag in native type descriptor artifact";
					};
				arguments.push({name: argumentName, type: type, value: value});
			}
			result.push({name: name, arguments: arguments});
		}
		validateAnnotationValues(result);
		return result;
	}

	static function validateAnnotationValues(values:Array<NativeTypeAnnotationData>):Void {
		for (annotation in values) {
			if (annotation.name.length == 0)
				throw "Native type annotation name must be nonempty";
			var names:Map<String, Bool> = [];
			for (argument in annotation.arguments) {
				if (argument.name.length == 0 || argument.type.length == 0)
					throw "Native type annotation argument name and type must be nonempty";
				if (names.exists(argument.name))
					throw 'Duplicate native type annotation argument "${argument.name}"';
				names.set(argument.name, true);
				switch argument.value {
					case FloatValue(value) if (!Math.isFinite(value)):
						throw 'Native type annotation "${annotation.name}" has a non-finite floating-point constant';
					case _:
				}
			}
		}
	}

	static function descriptorJson(descriptor:NativeTypeDescriptorData, replacements:Array<{marker:String, number:String}>):Dynamic
		return {
			version: descriptor.version,
			name: descriptor.name,
			type: descriptor.type,
			sourceKind: descriptor.sourceKind,
			interfaces: descriptor.interfaces,
			flat: descriptor.flat,
			portable: descriptor.portable,
			size: descriptor.size,
			alignment: descriptor.alignment,
			annotations: descriptor.annotations,
			annotationValues: annotationValuesJson(descriptor.annotationValues),
			fields: [for (field in descriptor.fields) nodeJson(field, replacements)],
			arguments: [for (argument in descriptor.arguments) nodeJson(argument, replacements)],
			hash: descriptor.hash
		};

	static function nodeJson(node:NativeTypeDescriptorField, replacements:Array<{marker:String, number:String}>):Dynamic
		return {
			name: node.name,
			type: node.type,
			flat: node.flat,
			portable: node.portable,
			size: node.size,
			alignment: node.alignment,
			offset: node.offset,
			defaultValue: defaultJson(node, node.defaultValue, replacements),
			annotations: node.annotations,
			annotationValues: annotationValuesJson(node.annotationValues),
			fields: [for (field in node.fields) nodeJson(field, replacements)],
			arguments: [for (argument in node.arguments) nodeJson(argument, replacements)],
			recursive: node.recursive
		};

	static function annotationValuesJson(values:Array<NativeTypeAnnotationData>):Array<Dynamic>
		return [
			for (annotation in values)
				{
					name: annotation.name,
					arguments: [
						for (argument in annotation.arguments)
							{
								name: argument.name,
								type: argument.type,
								value: annotationConstantJson(argument.value)
							}
					]
				}
		];

	static function annotationConstantJson(value:NativeTypeAnnotationValue):Dynamic
		return switch value {
			case IntValue(value): value;
			case FloatValue(value): value;
			case StringValue(value): value;
			case BoolValue(value): value;
			case NullValue: null;
		};

	static function defaultJson(node:NativeTypeDescriptorField, value:Null<NativeTypeDescriptorDefault>,
			replacements:Array<{marker:String, number:String}>):Dynamic {
		if (value == null)
			return null;
		return switch value.value {
			case FloatValue(number) if (containsFloat32(node)):
				var marker = '__HAXEON_F32_DEFAULT_${replacements.length}__';
				replacements.push({marker: marker, number: exactFloat32Decimal(number)});
				{type: value.type, value: marker};
			case _:
				{type: value.type, value: annotationConstantJson(value.value)};
		};
	}

	static function exactFloat32Decimal(value:Float):String {
		var bitsValue = NativeTypeDescriptor.float32DefaultBits(value);
		if (bitsValue == null)
			throw "Non-finite Float32 descriptor defaults cannot be serialized";
		var bits:Int = cast bitsValue,
			exponent = (bits >>> 23) & 0xff,
			fraction = bits & 0x7fffff;
		if (exponent == 0xff)
			throw "Non-finite Float32 descriptor defaults cannot be serialized";
		var significand = exponent == 0 ? fraction : 0x800000 | fraction;
		if (significand == 0)
			return "0";
		var power = exponent == 0 ? -149 : exponent - 150,
			digits = Std.string(significand);
		if (power >= 0) {
			for (_ in 0...power)
				digits = multiplyDecimalDigits(digits, 2);
			return ((bits >>> 31) == 0 ? "" : "-") + digits;
		}
		var decimalPlaces = -power;
		for (_ in 0...decimalPlaces)
			digits = multiplyDecimalDigits(digits, 5);
		var decimal = digits.length <= decimalPlaces ? "0." + StringTools.lpad("", "0",
			decimalPlaces - digits.length) + digits : digits.substr(0, digits.length - decimalPlaces)
			+ "."
			+ digits.substr(digits.length - decimalPlaces);
		while (StringTools.endsWith(decimal, "0"))
			decimal = decimal.substr(0, decimal.length - 1);
		if (StringTools.endsWith(decimal, "."))
			decimal = decimal.substr(0, decimal.length - 1);
		return ((bits >>> 31) == 0 ? "" : "-") + decimal;
	}

	static function multiplyDecimalDigits(value:String, factor:Int):String {
		var digits:Array<Int> = [], carry = 0;
		for (index in 0...value.length) {
			var digit = value.charCodeAt(value.length - index - 1) - "0".code,
				product = digit * factor + carry;
			digits.push(product % 10);
			carry = Std.int(product / 10);
		}
		while (carry > 0) {
			digits.push(carry % 10);
			carry = Std.int(carry / 10);
		}
		var result = new StringBuf();
		for (index in 0...digits.length)
			result.add(Std.string(digits[digits.length - index - 1]));
		return result.toString();
	}

	static function writeDefault(output:BytesOutput, value:Null<NativeTypeDescriptorDefault>):Void {
		writeBool(output, value != null);
		if (value == null)
			return;
		writeString(output, value.type);
		switch value.value {
			case IntValue(number):
				output.writeByte(0);
				output.writeInt32(number);
			case FloatValue(number):
				output.writeByte(1);
				output.writeDouble(number);
			case StringValue(text):
				output.writeByte(2);
				writeString(output, text);
			case BoolValue(flag):
				output.writeByte(3);
				writeBool(output, flag);
			case NullValue:
				output.writeByte(4);
		}
	}

	static function readDefault(input:BytesInput, limit:Int):Null<NativeTypeDescriptorDefault> {
		if (!readBool(input))
			return null;
		var type = readString(input, limit),
			value:NativeTypeAnnotationValue = switch input.readByte() {
				case 0: IntValue(input.readInt32());
				case 1: FloatValue(input.readDouble());
				case 2: StringValue(readString(input, limit));
				case 3: BoolValue(readBool(input));
				case 4: NullValue;
				case _: throw "Invalid default constant tag in native type descriptor artifact";
			};
		return {type: type, value: value};
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
