package compiler.ffi;

import haxe.Json;

/**
 * Haxe-facing naming policy layered on top of a generated HXI ABI model.
 *
 * This deliberately contains presentation names only. Native symbols,
 * layouts, and pointer contracts remain owned by HXI.
 */
class HxiProjectionProfile {
	public final interfaceName:Null<String>;
	public final typePrefix:Null<String>;
	public final functionPrefix:Null<String>;
	public final functionCase:String;
	public final fieldCase:String;
	public final constantPrefix:Null<String>;
	public final constantCase:String;
	public final enumValuePrefixes:Array<String>;
	public final typeNames:Map<String, String>;
	public final enumNames:Map<String, String>;
	public final enumValueNames:Map<String, Map<String, String>>;
	public final functionNames:Map<String, String>;
	public final fieldNames:Map<String, String>;
	public final constantNames:Map<String, String>;

	public function new(?interfaceName:Null<String>, ?typePrefix:Null<String>, ?enumValuePrefixes:Array<String>,
			?typeNames:Map<String, String>, ?enumNames:Map<String, String>,
			?enumValueNames:Map<String, Map<String, String>>, ?functionNames:Map<String, String>,
			?fieldNames:Map<String, String>, ?constantNames:Map<String, String>, ?functionPrefix:Null<String>,
			functionCase:String = "preserve", fieldCase:String = "preserve", ?constantPrefix:Null<String>,
			constantCase:String = "preserve") {
		this.interfaceName = interfaceName;
		this.typePrefix = typePrefix;
		this.functionPrefix = functionPrefix;
		this.functionCase = validateCase(functionCase);
		this.fieldCase = validateCase(fieldCase);
		this.constantPrefix = constantPrefix;
		this.constantCase = validateCase(constantCase);
		this.enumValuePrefixes = enumValuePrefixes == null ? [] : enumValuePrefixes;
		this.typeNames = typeNames == null ? [] : typeNames;
		this.enumNames = enumNames == null ? [] : enumNames;
		this.enumValueNames = enumValueNames == null ? [] : enumValueNames;
		this.functionNames = functionNames == null ? [] : functionNames;
		this.fieldNames = fieldNames == null ? [] : fieldNames;
		this.constantNames = constantNames == null ? [] : constantNames;
	}

	public static function empty():HxiProjectionProfile
		return new HxiProjectionProfile();

	/** Parses the stable, Haxe-specific projection manifest format. */
	public static function parse(path:String, source:String):HxiProjectionProfile {
		var value:Dynamic;
		try {
			value = Json.parse(source);
		} catch (error:Dynamic) {
			throw 'Invalid Haxe projection profile "$path": ${Std.string(error)}';
		}

		if (value == null || !Reflect.isObject(value) || Std.isOfType(value, Array))
			throw 'Invalid Haxe projection profile "$path": expected a JSON object';

		var interfaceName = requiredString(value, "interface", path),
			typePrefix = optionalString(value, "typePrefix", path),
			functionPrefix = optionalString(value, "functionPrefix", path),
			functionCase = optionalCase(value, "functionCase", path),
			fieldCase = optionalCase(value, "fieldCase", path),
			constantPrefix = optionalString(value, "constantPrefix", path),
			constantCase = optionalCase(value, "constantCase", path),
			enumValuePrefixes = stringArray(value, "enumValuePrefixes", path),
			typeNames = stringMap(value, "typeNames", path),
			enumNames = stringMap(value, "enumNames", path),
			enumValueNames = nestedStringMap(value, "enumValueNames", path),
			functionNames = stringMap(value, "functionNames", path),
			fieldNames = nestedStringMap(value, "fieldNames", path),
			constantNames = stringMap(value, "constantNames", path);
		return new HxiProjectionProfile(interfaceName, typePrefix, enumValuePrefixes, typeNames, enumNames, enumValueNames,
			functionNames, flattenFieldNames(fieldNames), constantNames, functionPrefix, functionCase, fieldCase, constantPrefix, constantCase);
	}

	static function optionalCase(value:Dynamic, field:String, path:String):String {
		var result = optionalString(value, field, path);
		return result == null ? "preserve" : result;
	}

	static function validateCase(value:String):String {
		if (value != "preserve" && value != "camel")
			throw 'Invalid Haxe projection case "$value"; expected "preserve" or "camel"';
		return value;
	}

	static function flattenFieldNames(value:Map<String, Map<String, String>>):Map<String, String> {
		var result:Map<String, String> = [];
		for (typeName => fields in value)
			for (fieldName => projected in fields)
				result.set(typeName + "." + fieldName, projected);
		return result;
	}

	static function requiredString(value:Dynamic, field:String, path:String):String {
		var result = optionalString(value, field, path);
		if (result == null || result.length == 0)
			throw 'Invalid Haxe projection profile "$path": "$field" is required';
		return result;
	}

	static function optionalString(value:Dynamic, field:String, path:String):Null<String> {
		if (!Reflect.hasField(value, field))
			return null;
		var result = Reflect.field(value, field);
		if (result == null)
			return null;
		if (!Std.isOfType(result, String))
			throw 'Invalid Haxe projection profile "$path": "$field" must be a string';
		return result;
	}

	static function stringArray(value:Dynamic, field:String, path:String):Array<String> {
		if (!Reflect.hasField(value, field))
			return [];
		var raw = Reflect.field(value, field);
		if (!Std.isOfType(raw, Array))
			throw 'Invalid Haxe projection profile "$path": "$field" must be an array';
		var result:Array<String> = [];
		for (item in (cast raw:Array<Dynamic>)) {
			if (!Std.isOfType(item, String))
				throw 'Invalid Haxe projection profile "$path": "$field" must contain only strings';
			result.push(item);
		}
		return result;
	}

	static function stringMap(value:Dynamic, field:String, path:String):Map<String, String> {
		if (!Reflect.hasField(value, field))
			return [];
		var raw = Reflect.field(value, field);
		if (raw == null || !Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw 'Invalid Haxe projection profile "$path": "$field" must be an object';
		var result:Map<String, String> = [];
		for (key in Reflect.fields(raw)) {
			var item = Reflect.field(raw, key);
			if (!Std.isOfType(item, String))
				throw 'Invalid Haxe projection profile "$path": "$field.$key" must be a string';
			result.set(key, item);
		}
		return result;
	}

	static function nestedStringMap(value:Dynamic, field:String, path:String):Map<String, Map<String, String>> {
		if (!Reflect.hasField(value, field))
			return [];
		var raw = Reflect.field(value, field);
		if (raw == null || !Reflect.isObject(raw) || Std.isOfType(raw, Array))
			throw 'Invalid Haxe projection profile "$path": "$field" must be an object';
		var result:Map<String, Map<String, String>> = [];
		for (key in Reflect.fields(raw)) {
			var item = Reflect.field(raw, key), wrapper:Dynamic = {};
			Reflect.setField(wrapper, "value", item);
			var parsed = stringMap(wrapper, "value", path);
			result.set(key, parsed);
		}
		return result;
	}
}
