package haxeon.wire;

import haxe.crypto.Sha256;
import haxe.io.Bytes;

/** A source-declared scalar default exposed by a validated descriptor. */
typedef MessagePackSchemaDefaultValue = {
	final type:String;
	final value:Dynamic;
}

/**
	Validated view of a compiler-emitted `.descriptors.json` artifact.

	Descriptors are checked, including their content hashes, before consumers
	use their field names, semantic type identities, or source defaults.
 */
class MessagePackSchema {
	public static inline final FORMAT_VERSION:Int = 3;
	static inline final DESCRIPTOR_VERSION:Int = 4;
	static inline final MAX_BYTES:Int = 16 * 1024 * 1024;
	static inline final MAX_ITEMS:Int = 0x100000;
	static inline final MAX_DEPTH:Int = 128;

	final descriptors:Map<String, Dynamic>;

	function new(descriptors:Map<String, Dynamic>) {
		this.descriptors = descriptors;
	}

	/** Parse and validate a complete compiler-emitted descriptor JSON sidecar. */
	public static function fromJson(json:String):MessagePackSchema {
		if (json == null || Bytes.ofString(json).length > MAX_BYTES)
			throw new MessagePackError("Writer descriptor artifact is null or exceeds configured limit");
		try {
			var artifact:Dynamic = haxe.Json.parse(json),
				formatVersion:Dynamic = Reflect.field(artifact, "formatVersion"),
				descriptorsValue:Dynamic = Reflect.field(artifact, "descriptors");
			if (formatVersion != FORMAT_VERSION || !Std.isOfType(descriptorsValue, Array))
				throw new MessagePackError("Unsupported writer descriptor artifact format or missing descriptors");
			var descriptors:Array<Dynamic> = cast descriptorsValue;
			if (descriptors.length > MAX_ITEMS)
				throw new MessagePackError("Writer descriptor artifact contains too many descriptors");
			var identities:Map<String, Bool> = [],
				byHashType:Map<String, Dynamic> = [];
			for (descriptor in descriptors) {
				validateDescriptor(descriptor);
				var name = fieldString(descriptor, "name"),
					identity = name.length + ":" + name + fieldString(descriptor, "type");
				if (identities.exists(identity))
					throw new MessagePackError("Writer descriptor artifact contains a duplicate descriptor identity");
				identities.set(identity, true);
				var key = descriptorKey(fieldString(descriptor, "hash"), fieldString(descriptor, "type"));
				if (byHashType.exists(key))
					throw new MessagePackError("Writer descriptor artifact contains a duplicate hash and type");
				byHashType.set(key, descriptor);
			}
			return new MessagePackSchema(byHashType);
		} catch (error:Dynamic) {
			if (Std.isOfType(error, MessagePackError))
				throw error;
			throw new MessagePackError('Invalid writer descriptor artifact: ${Std.string(error)}');
		}
	}

	/** Verify the envelope's hash identifies the expected record in this artifact. */
	public function requireDescriptor(hash:String, type:String):Void {
		if (!descriptors.exists(descriptorKey(hash, type)))
			throw new MessagePackError('Writer descriptor "$type" with hash "$hash" is unavailable');
	}

	/**
		Return the declared default for a root or recursively nested descriptor field.
		Null means the field has no source initializer; an explicit nullable null
		is `{type: "Null", value: null}`.
	 */
	public function fieldDefaultValue(hash:String, type:String, fieldPath:Array<String>):Null<MessagePackSchemaDefaultValue> {
		var descriptor = descriptors.get(descriptorKey(hash, type));
		if (descriptor == null)
			throw new MessagePackError('Writer descriptor "$type" with hash "$hash" is unavailable');
		if (fieldPath == null || fieldPath.length == 0)
			throw new MessagePackError("Writer field default lookup requires a nonempty field path");
		var fields = fieldArray(descriptor, "fields"), node:Dynamic = null;
		for (index in 0...fieldPath.length) {
			var segment = fieldPath[index];
			node = null;
			for (field in fields)
				if (fieldString(field, "name") == segment) {
					node = field;
					break;
				}
			if (node == null)
				throw new MessagePackError('Field "${fieldPath.slice(0, index + 1).join(".")}" is absent from writer descriptor "$type"');
			if (index + 1 < fieldPath.length)
				fields = fieldArray(node, "fields");
		}
		var value:Dynamic = Reflect.field(node, "defaultValue");
		return value == null ? null : {type: fieldString(value, "type"), value: Reflect.field(value, "value")};
	}

	static function descriptorKey(hash:String, type:String):String
		return hash.length + ":" + hash + type;

	static function validateDescriptor(value:Dynamic):Void {
		requireObject(value, "descriptor");
		if (fieldInt(value, "version") != DESCRIPTOR_VERSION
			|| fieldString(value, "name").length == 0
			|| fieldString(value, "type").length == 0)
			throw new MessagePackError("Unsupported or incomplete writer descriptor");
		var flat = fieldBool(value, "flat");
		fieldBool(value, "portable");
		validateLayout(flat, fieldNullableInt(value, "size"), fieldNullableInt(value, "alignment"), null);
		var annotations = fieldArray(value, "annotations");
		checkItems(annotations.length);
		for (annotation in annotations)
			if (!Std.isOfType(annotation, String))
				throw new MessagePackError("Writer descriptor annotation must be a string");
		validateAnnotationValues(fieldArray(value, "annotationValues"));
		validateNodes(fieldArray(value, "fields"), 0, true);
		validateNodes(fieldArray(value, "arguments"), 0, true);
		var hash = fieldString(value, "hash");
		if (!~/^[0-9a-f]{64}$/.match(hash) || hash != descriptorHash(value))
			throw new MessagePackError('Writer descriptor content hash mismatch for "${fieldString(value, "name")}"');
	}

	static function validateNodes(nodes:Array<Dynamic>, depth:Int, uniqueNames:Bool):Void {
		checkDepth(depth);
		checkItems(nodes.length);
		var names:Map<String, Bool> = [];
		for (node in nodes) {
			requireObject(node, "descriptor node");
			var name = fieldString(node, "name");
			if (name.length == 0 || fieldString(node, "type").length == 0)
				throw new MessagePackError("Writer descriptor node name and type must be nonempty");
			if (uniqueNames && names.exists(name))
				throw new MessagePackError('Writer descriptor contains duplicate field "$name"');
			names.set(name, true);
			var flat = fieldBool(node, "flat");
			fieldBool(node, "portable");
			validateLayout(flat, fieldNullableInt(node, "size"), fieldNullableInt(node, "alignment"), fieldNullableInt(node, "offset"));
			var annotations = fieldArray(node, "annotations");
			checkItems(annotations.length);
			for (annotation in annotations)
				if (!Std.isOfType(annotation, String))
					throw new MessagePackError("Writer descriptor annotation must be a string");
			validateAnnotationValues(fieldArray(node, "annotationValues"));
			validateDefaultValue(node);
			validateNodes(fieldArray(node, "fields"), depth + 1, true);
			validateNodes(fieldArray(node, "arguments"), depth + 1, true);
			fieldBool(node, "recursive");
		}
		validateRenameAliases(nodes);
	}

	static function validateDefaultValue(node:Dynamic):Void {
		if (!Reflect.hasField(node, "defaultValue"))
			throw new MessagePackError("Writer descriptor node is missing its default value contract");
		var value:Dynamic = Reflect.field(node, "defaultValue");
		if (value == null)
			return;
		requireObject(value, "field default");
		if (!Reflect.hasField(value, "value"))
			throw new MessagePackError("Writer descriptor default must include a value");
		var type = fieldString(value, "type"),
			constant:Dynamic = Reflect.field(value, "value");
		if (type == "Float"
			&& containsFloat32(node)
			&& (Std.isOfType(constant, Float) || Std.isOfType(constant, Int))
			&& float32DefaultBits(cast constant) == null)
			throw new MessagePackError('Writer descriptor Float32 default is not finite at "${fieldString(node, "name")}"');
		var valid = switch type {
			case "Int": Std.isOfType(constant, Int) && integerDefaultTypeAccepted(node, cast constant);
			case "Float": (Std.isOfType(constant, Int) || Std.isOfType(constant, Float)) && Math.isFinite(cast constant) && defaultTypeAccepted(node, "Float");
			case "String": Std.isOfType(constant, String) && defaultTypeAccepted(node, "String");
			case "Bool": Std.isOfType(constant, Bool) && defaultTypeAccepted(node, "Bool");
			case "Null": constant == null && nullableDefaultType(node);
			case _:
				false;
		};
		if (!valid)
			throw new MessagePackError('Writer descriptor default does not match field type "${fieldString(node, "type")}"');
	}

	static function integerDefaultTypeAccepted(node:Dynamic, value:Int):Bool {
		var fieldType = fieldString(node, "type");
		if (fieldType == "Int")
			return true;
		switch fieldType {
			case "native-scalar:i8":
				return value >= -128 && value <= 127;
			case "native-scalar:u8":
				return value >= 0 && value <= 255;
			case "native-scalar:i16":
				return value >= -32768 && value <= 32767;
			case "native-scalar:u16":
				return value >= 0 && value <= 65535;
			case _:
		}
		for (argument in fieldArray(node, "arguments"))
			if (fieldString(argument, "name") == "representation"
				|| (StringTools.startsWith(fieldType, "Null<") && fieldString(argument, "name") == "element"))
				if (integerDefaultTypeAccepted(argument, value))
					return true;
		return false;
	}

	static function containsFloat32(node:Dynamic):Bool {
		var fieldType = fieldString(node, "type");
		if (fieldType == "native-scalar:f32")
			return true;
		for (argument in fieldArray(node, "arguments"))
			if ((fieldString(argument, "name") == "representation"
				|| (StringTools.startsWith(fieldType, "Null<") && fieldString(argument, "name") == "element"))
				&& containsFloat32(argument))
				return true;
		return false;
	}

	static function float32DefaultBits(value:Float):Null<Int> {
		if (!Math.isFinite(value))
			return null;
		if (value == 0)
			return 0;
		var negative = value < 0,
			sign = negative ? 0x80000000 : 0,
			absolute = negative ? -value : value;
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

	static function defaultTypeAccepted(node:Dynamic, valueType:String):Bool {
		var fieldType = fieldString(node, "type");
		if (fieldType == valueType || (valueType == "Float" && fieldType == "native-scalar:f32"))
			return true;
		for (argument in fieldArray(node, "arguments"))
			if (fieldString(argument, "name") == "representation"
				|| (StringTools.startsWith(fieldType, "Null<") && fieldString(argument, "name") == "element"))
				if (defaultTypeAccepted(argument, valueType))
					return true;
		return false;
	}

	static function nullableDefaultType(node:Dynamic):Bool {
		var fieldType = fieldString(node, "type");
		if (StringTools.startsWith(fieldType, "Null<"))
			return true;
		for (argument in fieldArray(node, "arguments"))
			if (fieldString(argument, "name") == "representation" && nullableDefaultType(argument))
				return true;
		return false;
	}

	static function validateLayout(flat:Bool, size:Dynamic, alignment:Dynamic, offset:Dynamic):Void {
		if ((size != null && size < 0) || (alignment != null && alignment <= 0) || (offset != null && offset < 0))
			throw new MessagePackError("Writer descriptor contains invalid layout values");
		if (flat && size != null && alignment == null || flat && size == null && alignment != null)
			throw new MessagePackError("Flat writer descriptor must report both size and alignment or neither");
	}

	static function validateRenameAliases(nodes:Array<Dynamic>):Void {
		var names:Map<String, String> = [];
		for (node in nodes) {
			var name = fieldString(node, "name");
			names.set(name, name);
		}
		for (node in nodes) {
			var name = fieldString(node, "name");
			for (annotation in fieldArray(node, "annotationValues"))
				if (fieldString(annotation, "name") == "renamedFrom") {
					var arguments = fieldArray(annotation, "arguments");
					if (arguments.length != 1 || fieldString(arguments[0], "type") != "String")
						throw new MessagePackError('Invalid @:renamedFrom metadata on writer field "$name"');
					var aliasValue:Dynamic = Reflect.field(arguments[0], "value");
					if (!Std.isOfType(aliasValue, String))
						throw new MessagePackError('Invalid @:renamedFrom name on writer field "$name"');
					var alias:String = cast aliasValue;
					if (alias.length == 0 || alias == name || names.exists(alias))
						throw new MessagePackError('Rename collision for writer field alias "$alias" on "$name"');
					names.set(alias, name);
				}
		}
	}

	static function validateAnnotationValues(values:Array<Dynamic>):Void {
		checkItems(values.length);
		for (annotation in values) {
			requireObject(annotation, "annotation value");
			if (fieldString(annotation, "name").length == 0)
				throw new MessagePackError("Writer annotation name must be nonempty");
			var arguments = fieldArray(annotation, "arguments"),
				names:Map<String, Bool> = [];
			checkItems(arguments.length);
			for (argument in arguments) {
				requireObject(argument, "annotation argument");
				var name = fieldString(argument, "name"),
					type = fieldString(argument, "type"),
					value:Dynamic = Reflect.field(argument, "value");
				if (name.length == 0 || type.length == 0 || names.exists(name))
					throw new MessagePackError("Writer annotation argument is incomplete or duplicated");
				names.set(name, true);
				if (value != null && !Std.isOfType(value, String) && !Std.isOfType(value, Bool) && !Std.isOfType(value, Int) && !Std.isOfType(value, Float))
					throw new MessagePackError("Writer annotation value is not a supported scalar constant");
				if (Std.isOfType(value, Float) && !Math.isFinite(cast value))
					throw new MessagePackError("Writer annotation value is non-finite");
				if (!annotationValueMatches(type, value))
					throw new MessagePackError('Writer annotation value does not match declared type "$type"');
			}
		}
	}

	static function annotationValueMatches(type:String, value:Dynamic):Bool {
		if (value == null)
			return StringTools.startsWith(type, "Null<");
		return switch type {
			case "Int":
				Std.isOfType(value, Int);
			case "Float": Std.isOfType(value, Int) || Std.isOfType(value, Float);
			case "String":
				Std.isOfType(value, String);
			case "Bool":
				Std.isOfType(value, Bool);
			default:
				false;
		};
	}

	static function descriptorHash(descriptor:Dynamic):String {
		var canonical = new StringBuf();
		append(canonical, fieldString(descriptor, "type"));
		append(canonical, Std.string(DESCRIPTOR_VERSION));
		append(canonical, fieldString(descriptor, "name"));
		append(canonical, fieldString(descriptor, "type"));
		append(canonical, fieldBool(descriptor, "flat") ? "1" : "0");
		append(canonical, fieldBool(descriptor, "portable") ? "1" : "0");
		appendNullableInt(canonical, fieldNullableInt(descriptor, "size"));
		appendNullableInt(canonical, fieldNullableInt(descriptor, "alignment"));
		appendStrings(canonical, fieldArray(descriptor, "annotations"));
		appendAnnotationValues(canonical, fieldArray(descriptor, "annotationValues"));
		appendNodes(canonical, fieldArray(descriptor, "fields"));
		appendNodes(canonical, fieldArray(descriptor, "arguments"));
		return Sha256.encode(canonical.toString());
	}

	static function appendNodes(buffer:StringBuf, nodes:Array<Dynamic>):Void {
		append(buffer, Std.string(nodes.length));
		for (node in nodes) {
			append(buffer, fieldString(node, "name"));
			append(buffer, fieldString(node, "type"));
			append(buffer, fieldBool(node, "flat") ? "1" : "0");
			append(buffer, fieldBool(node, "portable") ? "1" : "0");
			appendNullableInt(buffer, fieldNullableInt(node, "size"));
			appendNullableInt(buffer, fieldNullableInt(node, "alignment"));
			appendNullableInt(buffer, fieldNullableInt(node, "offset"));
			appendDefault(buffer, node, Reflect.field(node, "defaultValue"));
			appendStrings(buffer, fieldArray(node, "annotations"));
			appendAnnotationValues(buffer, fieldArray(node, "annotationValues"));
			appendNodes(buffer, fieldArray(node, "fields"));
			appendNodes(buffer, fieldArray(node, "arguments"));
			append(buffer, fieldBool(node, "recursive") ? "1" : "0");
		}
	}

	static function appendDefault(buffer:StringBuf, node:Dynamic, value:Dynamic):Void {
		if (value == null) {
			append(buffer, "0");
			return;
		}
		append(buffer, "1");
		var type = fieldString(value, "type"),
			constant:Dynamic = Reflect.field(value, "value");
		append(buffer, type);
		if (constant == null)
			append(buffer, "n");
		else if (type == "Int" && Std.isOfType(constant, Int))
			append(buffer, "i" + Std.string(constant));
		else if (type == "Float" && (Std.isOfType(constant, Float) || Std.isOfType(constant, Int))) {
			if (containsFloat32(node)) {
				var bits = float32DefaultBits(cast constant);
				append(buffer, bits == null ? "f" + Std.string(constant) : "f32i" + Std.string(bits));
			} else
				append(buffer, "f" + Std.string(constant));
		} else if (type == "String" && Std.isOfType(constant, String))
			append(buffer, "s" + Std.string(constant));
		else if (type == "Bool" && Std.isOfType(constant, Bool))
			append(buffer, Std.string(constant) == "true" ? "b1" : "b0");
		else
			throw new MessagePackError("Writer descriptor default does not match its value type");
	}

	static function appendStrings(buffer:StringBuf, values:Array<Dynamic>):Void {
		append(buffer, Std.string(values.length));
		for (value in values)
			append(buffer, cast value);
	}

	static function appendAnnotationValues(buffer:StringBuf, values:Array<Dynamic>):Void {
		append(buffer, Std.string(values.length));
		for (annotation in values) {
			append(buffer, fieldString(annotation, "name"));
			var arguments = fieldArray(annotation, "arguments");
			append(buffer, Std.string(arguments.length));
			for (argument in arguments) {
				append(buffer, fieldString(argument, "name"));
				var type = fieldString(argument, "type"),
					value:Dynamic = Reflect.field(argument, "value");
				append(buffer, type);
				if (value == null)
					append(buffer, "n");
				else if (type == "Int" && Std.isOfType(value, Int))
					append(buffer, "i" + Std.string(value));
				else if (type == "Float" && (Std.isOfType(value, Float) || Std.isOfType(value, Int)))
					append(buffer, "f" + Std.string(value));
				else if (Std.isOfType(value, String))
					append(buffer, "s" + Std.string(value));
				else if (Std.isOfType(value, Bool))
					append(buffer, Std.string(value) == "true" ? "b1" : "b0");
				else
					throw new MessagePackError("Writer annotation value does not match its declared type");
			}
		}
	}

	static function appendNullableInt(buffer:StringBuf, value:Dynamic):Void
		append(buffer, value == null ? "-" : Std.string(value));

	static function append(buffer:StringBuf, value:String):Void {
		buffer.add(value.length);
		buffer.add(":");
		buffer.add(value);
	}

	static function requireObject(value:Dynamic, label:String):Void
		if (value == null || Std.isOfType(value, Array) || !Reflect.isObject(value))
			throw new MessagePackError('Invalid writer $label object');

	static function fieldString(value:Dynamic, name:String):String {
		var result:Dynamic = Reflect.field(value, name);
		if (!Std.isOfType(result, String))
			throw new MessagePackError('Writer descriptor field "$name" must be a string');
		return cast result;
	}

	static function fieldBool(value:Dynamic, name:String):Bool {
		var result:Dynamic = Reflect.field(value, name);
		if (!Std.isOfType(result, Bool))
			throw new MessagePackError('Writer descriptor field "$name" must be a boolean');
		return cast result;
	}

	static function fieldInt(value:Dynamic, name:String):Int {
		var result:Dynamic = Reflect.field(value, name);
		if (!Std.isOfType(result, Int))
			throw new MessagePackError('Writer descriptor field "$name" must be an integer');
		return cast result;
	}

	static function fieldNullableInt(value:Dynamic, name:String):Dynamic {
		var result:Dynamic = Reflect.field(value, name);
		if (result != null && !Std.isOfType(result, Int))
			throw new MessagePackError('Writer descriptor field "$name" must be an integer or null');
		return result;
	}

	static function fieldArray(value:Dynamic, name:String):Array<Dynamic> {
		var result:Dynamic = Reflect.field(value, name);
		if (!Std.isOfType(result, Array))
			throw new MessagePackError('Writer descriptor field "$name" must be an array');
		return cast result;
	}

	static function checkItems(count:Int):Void
		if (count > MAX_ITEMS)
			throw new MessagePackError("Writer descriptor item count exceeds configured limit");

	static function checkDepth(depth:Int):Void
		if (depth > MAX_DEPTH)
			throw new MessagePackError("Writer descriptor nesting exceeds configured limit");
}
