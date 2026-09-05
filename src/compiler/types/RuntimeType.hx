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
	public static function mapName(key:CompilerType, value:CompilerType):Null<String>
		return switch [key, value] {
			case [TString, TInt]: "map_string_i32";
			case [TString, TBool]: "map_string_bool";
			case [TString, TFloat]: "map_string_f64";
			case [TString, TString]: "map_string_bytes";
			default: null;
		};

	public static function mapNative(key:CompilerType, value:CompilerType, operation:String):String {
		var name = mapName(key, value);
		if (name == null)
			throw 'Unsupported compiler map ABI for ${key} -> ${value}';
		return '__${name}_$operation';
	}

	public static function mapValueType(name:String):Null<CompilerType>
		return switch name {
			case "map_string_i32": TInt;
			case "map_string_bool": TBool;
			case "map_string_f64": TFloat;
			case "map_string_bytes": TString;
			default: null;
		};
}
