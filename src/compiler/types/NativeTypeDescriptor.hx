package compiler.types;

import haxe.crypto.Sha256;
import haxe.io.Bytes;

/** Typed constant captured from one checked source metadata annotation argument. */
enum NativeTypeAnnotationValue {
	IntValue(value:Int);
	FloatValue(value:Float);
	StringValue(value:String);
	BoolValue(value:Bool);
	NullValue;
}

typedef NativeTypeAnnotationArgument = {
	final name:String;
	final type:String;
	final value:NativeTypeAnnotationValue;
}

typedef NativeTypeAnnotationData = {
	final name:String;
	final arguments:Array<NativeTypeAnnotationArgument>;
}

/** A supported constant used to initialize one ordinary source field. */
typedef NativeTypeDescriptorDefault = {
	final type:String;
	final value:NativeTypeAnnotationValue;
}

/** One source field or nested type in a compile-time descriptor tree. */
typedef NativeTypeDescriptorField = {
	final name:String;
	final type:String;
	final flat:Bool;
	final portable:Bool;
	final size:Null<Int>;
	final alignment:Null<Int>;
	final offset:Null<Int>;

	/** Null means no initializer; explicit null is `{type: "Null", value: null}`. */
	final defaultValue:Null<NativeTypeDescriptorDefault>;

	final annotations:Array<String>;
	final annotationValues:Array<NativeTypeAnnotationData>;
	final fields:Array<NativeTypeDescriptorField>;
	final arguments:Array<NativeTypeDescriptorField>;
	final recursive:Bool;
}

/** Complete descriptor emitted by typeInfo<T>(). */
typedef NativeTypeDescriptorData = {
	final version:Int;
	final name:String;
	final type:String;

	/** Original source declaration category, independent of the compiler's nominal `class:` type spelling. */
	final sourceKind:String;

	/** Canonical, sorted effective interface conformance facts for the root declaration. */
	final interfaces:Array<String>;

	final flat:Bool;
	final portable:Bool;
	final size:Null<Int>;
	final alignment:Null<Int>;
	final annotations:Array<String>;
	final annotationValues:Array<NativeTypeAnnotationData>;
	final fields:Array<NativeTypeDescriptorField>;
	final arguments:Array<NativeTypeDescriptorField>;
	final hash:String;
}

/** Stable, recursively length-prefixed content hashing for compiler-emitted type descriptors. */
class NativeTypeDescriptor {
	public static inline final VERSION = 5;

	public static function validSourceKind(value:String):Bool
		return value == "struct" || value == "class" || value == "native-value";

	/** SemanticSignature spelling for a canonical, fully substituted interface identity. */
	public static function validInterfaceIdentity(value:String):Bool {
		if (value == null || !StringTools.startsWith(value, "interface:"))
			return false;
		var open = value.indexOf("<"), length = value.length;
		if (open <= "interface:".length || length <= open + 1 || !StringTools.endsWith(value, ">"))
			return false;
		var name = value.substring("interface:".length, open);
		if (name.length == 0 || StringTools.startsWith(name, ".") || StringTools.endsWith(name, ".") || name.indexOf("..") >= 0)
			return false;
		var depth = 0;
		for (index in open...length) {
			var code = value.charCodeAt(index);
			if (code <= 32 || code == 127)
				return false;
			switch code {
				case 60:
					depth++;
				case 62:
					depth--;
					if (depth < 0 || (depth == 0 && index != length - 1))
						return false;
				case _:
			}
		}
		return depth == 0;
	}

	public static function canonicalInterfaces(values:Array<String>):Bool {
		if (values == null)
			return false;
		var previous:Null<String> = null;
		for (value in values) {
			if (!validInterfaceIdentity(value) || (previous != null && Reflect.compare(previous, value) >= 0))
				return false;
			previous = value;
		}
		return true;
	}

	/** Convert a finite Haxe Float to the value representable by the native Float32 scalar. */
	public static function float32DefaultValue(value:Float):Null<Float> {
		var bitsValue = float32DefaultBits(value);
		if (bitsValue == null)
			return null;
		var bits:Int = cast bitsValue,
			sign = ((bits >>> 31) == 0) ? 1.0 : -1.0,
			exponent = (bits >>> 23) & 0xff,
			fraction = bits & 0x7fffff;
		return exponent == 0 ? sign * fraction * Math.pow(2.0, -149.0) : sign * (1.0 + fraction / 8388608.0) * Math.pow(2.0, exponent - 127.0);
	}

	/** Return the IEEE-754 binary32 bits for a finite value, or null on overflow. */
	public static function float32DefaultBits(value:Float):Null<Int> {
		if (!Math.isFinite(value))
			return null;
		if (value == 0)
			return 0;
		var negative = value < 0,
			sign = negative ? 0x80000000 : 0,
			absolute = negative ? -value : value;
		// Values above this midpoint round to infinity in IEEE-754 binary32.
		if (absolute >= 3.4028235677973366e38)
			return null;
		if (absolute > 3.4028234663852886e38)
			return sign | 0x7f7fffff;
		var exponent = Math.floor(Math.log(absolute) / 0.6931471805599453);
		if (exponent < -126) {
			var subnormal = roundBinary32(absolute * Math.pow(2.0, 149.0));
			return sign | subnormal;
		}
		var power = Math.pow(2.0, exponent);
		while (absolute < power) {
			exponent--;
			power *= 0.5;
		}
		while (absolute >= power * 2.0) {
			exponent++;
			power *= 2.0;
		}
		var fraction = roundBinary32((absolute / power - 1.0) * 8388608.0);
		if (fraction == 8388608) {
			exponent++;
			fraction = 0;
		}
		if (exponent > 127)
			return null;
		return sign | ((exponent + 127) << 23) | fraction;
	}

	static function roundBinary32(value:Float):Int {
		var floorValue = Math.floor(value),
			integer = Std.int(floorValue),
			remainder = value - floorValue;
		if (remainder > 0.5 || (remainder == 0.5 && integer % 2 != 0))
			return integer + 1;
		return integer;
	}

	/** Haxe Int bounds supported for descriptor defaults on fixed-width native scalars. */
	public static function narrowIntegerDefaultRange(type:String):Null<{min:Int, max:Int}>
		return switch type {
			case "native-scalar:i8": {min: -128, max: 127};
			case "native-scalar:u8": {min: 0, max: 255};
			case "native-scalar:i16": {min: -32768, max: 32767};
			case "native-scalar:u16": {min: 0, max: 65535};
			case _: null;
		};

	/** Int32 and UInt32 defaults use the exact signed Int carrier bit pattern. */
	public static function integerDefaultFits(type:String, value:Int):Bool
		return switch type {
			case "native-scalar:i32" | "native-scalar:u32": true;
			case _: var range = narrowIntegerDefaultRange(type); range != null && value >= range.min && value <= range.max;
		};

	public static function contentHash(identity:String, name:String, type:String, sourceKind:String, interfaces:Array<String>, flat:Bool, portable:Bool,
			size:Null<Int>, alignment:Null<Int>, annotations:Array<String>, annotationValues:Array<NativeTypeAnnotationData>,
			fields:Array<NativeTypeDescriptorField>, arguments:Array<NativeTypeDescriptorField>):String {
		var canonical = new StringBuf();
		append(canonical, identity);
		append(canonical, Std.string(VERSION));
		append(canonical, name);
		append(canonical, type);
		append(canonical, sourceKind);
		appendStrings(canonical, interfaces);
		append(canonical, flat ? "1" : "0");
		append(canonical, portable ? "1" : "0");
		appendNullableInt(canonical, size);
		appendNullableInt(canonical, alignment);
		appendStrings(canonical, annotations);
		appendAnnotationValues(canonical, annotationValues);
		appendNodes(canonical, fields);
		appendNodes(canonical, arguments);
		var digest = Sha256.make(Bytes.ofString(canonical.toString())),
			result = new StringBuf();
		for (index in 0...digest.length)
			result.add(StringTools.hex(digest.get(index), 2));
		return result.toString().toLowerCase();
	}

	static function appendNodes(buffer:StringBuf, nodes:Array<NativeTypeDescriptorField>):Void {
		append(buffer, Std.string(nodes.length));
		for (node in nodes) {
			append(buffer, node.name);
			append(buffer, node.type);
			append(buffer, node.flat ? "1" : "0");
			append(buffer, node.portable ? "1" : "0");
			appendNullableInt(buffer, node.size);
			appendNullableInt(buffer, node.alignment);
			appendNullableInt(buffer, node.offset);
			appendDefault(buffer, node, node.defaultValue);
			appendStrings(buffer, node.annotations);
			appendAnnotationValues(buffer, node.annotationValues);
			appendNodes(buffer, node.fields);
			appendNodes(buffer, node.arguments);
			append(buffer, node.recursive ? "1" : "0");
		}
	}

	static function appendDefault(buffer:StringBuf, node:NativeTypeDescriptorField, value:Null<NativeTypeDescriptorDefault>):Void {
		if (value == null) {
			append(buffer, "0");
			return;
		}
		append(buffer, "1");
		append(buffer, value.type);
		switch value.value {
			case IntValue(number):
				append(buffer, "i" + Std.string(number));
			case FloatValue(number):
				if (containsFloat32(node)) {
					var bits = float32DefaultBits(number);
					if (bits == null)
						append(buffer, "f" + Std.string(number));
					else {
						append(buffer, "f32i" + Std.string(bits));
					}
				} else
					append(buffer, "f" + Std.string(number));
			case StringValue(text):
				append(buffer, "s" + text);
			case BoolValue(flag):
				append(buffer, flag ? "b1" : "b0");
			case NullValue:
				append(buffer, "n");
		}
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

	static function appendStrings(buffer:StringBuf, values:Array<String>):Void {
		append(buffer, Std.string(values.length));
		for (value in values)
			append(buffer, value);
	}

	static function appendAnnotationValues(buffer:StringBuf, values:Array<NativeTypeAnnotationData>):Void {
		append(buffer, Std.string(values.length));
		for (annotation in values) {
			append(buffer, annotation.name);
			append(buffer, Std.string(annotation.arguments.length));
			for (argument in annotation.arguments) {
				append(buffer, argument.name);
				append(buffer, argument.type);
				switch argument.value {
					case IntValue(value):
						append(buffer, "i" + Std.string(value));
					case FloatValue(value):
						append(buffer, "f" + Std.string(value));
					case StringValue(value):
						append(buffer, "s" + value);
					case BoolValue(value):
						append(buffer, value ? "b1" : "b0");
					case NullValue:
						append(buffer, "n");
				}
			}
		}
	}

	static function appendNullableInt(buffer:StringBuf, value:Null<Int>):Void
		append(buffer, value == null ? "-" : Std.string(value));

	static function append(buffer:StringBuf, value:String):Void {
		buffer.add(value.length);
		buffer.add(":");
		buffer.add(value);
	}
}
