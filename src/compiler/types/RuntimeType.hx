package compiler.types;

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
			case TInt: "i32";
			case TFloat: "f64";
			case TBool: "bool";
			case TString: "bytes";
			case value if (isRuntimeReference(value)): "ref";
			default: null;
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
		return switch [key, value] {
			case [TString, TInt]: "map_string_i32";
			case [TString, TBool]: "map_string_bool";
			case [TString, TFloat]: "map_string_f64";
			case [TString, TString]: "map_string_bytes";
			case [TString, value] if (isRuntimeReference(value)): "map_string_ref";
			case [TInt, TInt]: "map_int_i32";
			case [TInt, TBool]: "map_int_bool";
			case [TInt, TFloat]: "map_int_f64";
			case [TInt, TString]: "map_int_bytes";
			case [TInt, value] if (isRuntimeReference(value)): "map_int_ref";
			default: null;
		};

	public static function mapKeyType(name:String):Null<CompilerType>
		return StringTools.startsWith(name, "map_int_") ? TInt : TString;

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
			case "map_string_i32": TInt;
			case "map_string_bool": TBool;
			case "map_string_f64": TFloat;
			case "map_string_bytes": TString;
			case "map_int_i32": TInt;
			case "map_int_bool": TBool;
			case "map_int_f64": TFloat;
			case "map_int_bytes": TString;
			default: null;
		};

	static function isRuntimeReference(type:CompilerType):Bool
		return switch type {
			case TBytes, THlBytes, TDynamic, TNativeAbstract(_), TClass(_), TInterface(_), TEnum(_), TAnonymous(_,
				_), TArray(_), TMap(_, _), TFunction(_, _): true;
			case TNullable(element): isRuntimeReference(element);
			default: false;
		};
}
