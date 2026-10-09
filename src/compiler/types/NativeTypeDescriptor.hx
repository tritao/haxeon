package compiler.types;

import haxe.crypto.Sha256;

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
	public static inline final VERSION = 4;

	/** Haxe Int bounds supported for descriptor defaults on fixed-width native scalars. */
	public static function narrowIntegerDefaultRange(type:String):Null<{min:Int, max:Int}>
		return switch type {
			case "native-scalar:i8": {min: -128, max: 127};
			case "native-scalar:u8": {min: 0, max: 255};
			case "native-scalar:i16": {min: -32768, max: 32767};
			case "native-scalar:u16": {min: 0, max: 65535};
			case _: null;
		};

	public static function contentHash(identity:String, name:String, type:String, flat:Bool, portable:Bool, size:Null<Int>, alignment:Null<Int>,
			annotations:Array<String>, annotationValues:Array<NativeTypeAnnotationData>, fields:Array<NativeTypeDescriptorField>,
			arguments:Array<NativeTypeDescriptorField>):String {
		var canonical = new StringBuf();
		append(canonical, identity);
		append(canonical, Std.string(VERSION));
		append(canonical, name);
		append(canonical, type);
		append(canonical, flat ? "1" : "0");
		append(canonical, portable ? "1" : "0");
		appendNullableInt(canonical, size);
		appendNullableInt(canonical, alignment);
		appendStrings(canonical, annotations);
		appendAnnotationValues(canonical, annotationValues);
		appendNodes(canonical, fields);
		appendNodes(canonical, arguments);
		return Sha256.encode(canonical.toString());
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
			appendDefault(buffer, node.defaultValue);
			appendStrings(buffer, node.annotations);
			appendAnnotationValues(buffer, node.annotationValues);
			appendNodes(buffer, node.fields);
			appendNodes(buffer, node.arguments);
			append(buffer, node.recursive ? "1" : "0");
		}
	}

	static function appendDefault(buffer:StringBuf, value:Null<NativeTypeDescriptorDefault>):Void {
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
				append(buffer, "f" + Std.string(number));
			case StringValue(text):
				append(buffer, "s" + text);
			case BoolValue(flag):
				append(buffer, flag ? "b1" : "b0");
			case NullValue:
				append(buffer, "n");
		}
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
