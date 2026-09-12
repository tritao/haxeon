package compiler.runtime;

import compiler.types.Type.CompilerType;

/**
 * Names shared by the compiler-owned runtime ABI.
 *
 * Keeping these specializations in one place prevents the typer, IR builder,
 * and native registration table from silently drifting apart as collections
 * grow.  The first map ABI deliberately remains closed: every new
 * specialization has to be added here, typed, lowered, and covered by an
 * end-to-end runtime test.
 */
class RuntimeType {
	public static function arrayName(element:CompilerType):Null<String>
		return switch element {
			case TAbstract(_, _, representation): arrayName(representation);
			case TInt: "i32";
			case TFloat: "f64";
			case TBool: "bool";
			case TString: "bytes";
			default: isRuntimeReference(element) ? "ref" : null;
		};

	public static function arrayNative(element:CompilerType, operation:String):String {
		var name = requireArrayName(element);
		return '__array_${operation}_$name';
	}

	public static function requireArrayName(element:CompilerType):String {
		var name = arrayName(element);
		if (name == null)
			throw 'Unsupported compiler array ABI for $element';
		return name;
	}

	public static function mapName(key:CompilerType, value:CompilerType):Null<String>
		return switch key {
			case TAbstract(_, _, representation): mapName(representation, value);
			case TString: mapValueName("map_string_", value);
			case TInt: mapValueName("map_int_", value);
			default: null;
		};

	static function mapValueName(prefix:String, value:CompilerType):Null<String>
		return switch value {
			case TAbstract(_, _, representation): mapValueName(prefix, representation);
			case TNullable(element): nullableMapValueName(prefix, element);
			case TInt: prefix + "i32";
			case TBool: prefix + "bool";
			case TFloat: prefix + "f64";
			case TString: prefix + "bytes";
			default: isRuntimeReference(value) ? prefix + "ref" : null;
		};

	static function nullableMapValueName(prefix:String, element:CompilerType):Null<String>
		return switch element {
			case TAbstract(_, _, representation): nullableMapValueName(prefix, representation);
			case TString: prefix + "bytes";
			case TInt, TBool, TFloat: prefix + "ref";
			default: isRuntimeReference(element) ? prefix + "ref" : null;
		};

	public static function mapKeyType(name:String):Null<CompilerType>
		return StringTools.startsWith(name, "map_int_") ? CompilerType.TInt : CompilerType.TString;

	public static function mapNative(key:CompilerType, value:CompilerType, operation:String):String {
		var name = requireMapName(key, value);
		return '__${name}_$operation';
	}

	public static function requireMapName(key:CompilerType, value:CompilerType):String {
		var name = mapName(key, value);
		if (name == null)
			throw 'Unsupported compiler map ABI for ${key} -> ${value}';
		return name;
	}

	public static function mapValueType(name:String):Null<CompilerType>
		return switch name {
			case "map_string_i32": CompilerType.TInt;
			case "map_string_bool": CompilerType.TBool;
			case "map_string_f64": CompilerType.TFloat;
			case "map_string_bytes": CompilerType.TString;
			case "map_int_i32": CompilerType.TInt;
			case "map_int_bool": CompilerType.TBool;
			case "map_int_f64": CompilerType.TFloat;
			case "map_int_bytes": CompilerType.TString;
			default: null;
		};

	static function isRuntimeReference(type:CompilerType):Bool
		return switch type {
			case TAbstract(_, _, representation): isRuntimeReference(representation);
			case TBytes, THlBytes, TDynamic, TNativeAbstract(_), TInstance(_, _,
				_), TAnonymous(_, _), TArray(_), TIterator(_), TMap(_, _), TFunction(_, _): true;
			case TNullable(element): isRuntimeReference(element);
			default: false;
		};
}
