package compiler.types;

import compiler.types.Type.CompilerType;

/** Host types whose implementation is supplied by the HashLink/Haxe platform. */
class PlatformAbi {
	static final types:Map<String, Bool> = [
		"haxe.io.Bytes" => true,
		"hl.Bytes" => true,
		"haxe.io.BytesInput" => true,
		"haxe.io.BytesOutput" => true,
		"haxe.io.Encoding" => true,
		"haxe.io.Eof" => true,
		"haxe.Exception" => true,
		"haxe.Json" => true,
		"sys.FileSystem" => true,
		"sys.io.File" => true,
		"Date" => true,
		"Type.ValueType" => true
	];

	public static function isType(name:String):Bool
		return types.exists(name);

	public static function constructorArguments(name:String):Null<Array<CompilerType>>
		return switch name {
			case "haxe.io.BytesInput", "BytesInput": [TBytes];
			case "haxe.io.BytesOutput", "BytesOutput": [];
			case "haxe.Exception": [TString];
			default: null;
		};

	public static function valueType(name:String):CompilerType
		return switch name {
			case "haxe.io.BytesInput", "BytesInput": TNativeAbstract("realtime_bytes_input");
			case "haxe.io.BytesOutput", "BytesOutput": TNativeAbstract("realtime_bytes_output");
			default: TClass(name);
		};

	public static function constructorNative(name:String):Null<String>
		return switch name {
			case "haxe.io.BytesInput", "BytesInput": "__bytes_input_new";
			case "haxe.io.BytesOutput", "BytesOutput": "__bytes_output_new";
			default: null;
		};

	public static function field(type:CompilerType, name:String):Null<{type:CompilerType, get:String, set:Null<String>}>
		return switch [type, name] {
			case [TBytes, "length"]: {type: TInt, get: "__bytes_length", set: null};
			case [TNativeAbstract("realtime_bytes_input"), "position"]: {type: TInt, get: "__bytes_input_position", set: null};
			case [TNativeAbstract("realtime_bytes_input"), "bigEndian"]: {type: TBool, get: "__bytes_input_big_endian", set: "__bytes_input_set_big_endian"};
			case [TNativeAbstract("realtime_bytes_output"), "bigEndian"]: {type: TBool, get: "__bytes_output_big_endian", set: "__bytes_output_set_big_endian"};
			default: null;
		};

	public static function method(type:CompilerType, name:String):Null<{arguments:Array<CompilerType>, result:CompilerType, nativeName:String}>
		return switch [type, name] {
			case [TBytes, "get"]: {arguments: [TInt], result: TInt, nativeName: "__bytes_get"};
			case [TBytes, "set"]: {arguments: [TInt, TInt], result: TVoid, nativeName: "__bytes_set"};
			case [TBytes, "setInt32"]: {arguments: [TInt, TInt], result: TVoid, nativeName: "__bytes_set_i32"};
			case [TBytes, "sub"]: {arguments: [TInt, TInt], result: TBytes, nativeName: "__bytes_sub"};
			case [TBytes, "compare"]: {arguments: [TBytes], result: TInt, nativeName: "__bytes_compare"};
			case [TBytes, "toString"]: {arguments: [], result: TString, nativeName: "__bytes_to_string"};
			case [TNativeAbstract("realtime_bytes_input"), "readByte"]: {arguments: [], result: TInt, nativeName: "__bytes_input_read_byte"};
			case [TNativeAbstract("realtime_bytes_input"), "readInt32"]: {arguments: [], result: TInt, nativeName: "__bytes_input_read_i32"};
			case [TNativeAbstract("realtime_bytes_input"), "readDouble"]: {arguments: [], result: TFloat, nativeName: "__bytes_input_read_f64"};
			case [TNativeAbstract("realtime_bytes_input"), "readString"]: {arguments: [TInt], result: TString, nativeName: "__bytes_input_read_string"};
			case [TNativeAbstract("realtime_bytes_input"), "read"]: {arguments: [TInt], result: TBytes, nativeName: "__bytes_input_read"};
			case [TNativeAbstract("realtime_bytes_output"), "writeByte"]: {arguments: [TInt], result: TVoid, nativeName: "__bytes_output_write_byte"};
			case [TNativeAbstract("realtime_bytes_output"), "writeInt32"]: {arguments: [TInt], result: TVoid, nativeName: "__bytes_output_write_i32"};
			case [TNativeAbstract("realtime_bytes_output"), "writeDouble"]: {arguments: [TFloat], result: TVoid, nativeName: "__bytes_output_write_f64"};
			case [TNativeAbstract("realtime_bytes_output"), "writeString"]: {arguments: [TString], result: TVoid, nativeName: "__bytes_output_write_string"};
			case [TNativeAbstract("realtime_bytes_output"), "write"], [TNativeAbstract("realtime_bytes_output"), "writeBytes"]: {
					arguments: [TBytes],
					result: TVoid,
					nativeName: "__bytes_output_write"
				};
			case [TNativeAbstract("realtime_bytes_output"), "getBytes"]: {arguments: [], result: TBytes, nativeName: "__bytes_output_get_bytes"};
			case [TNativeAbstract("realtime_date"), "getTime"]: {arguments: [], result: TFloat, nativeName: "__date_get_time"};
			default: null;
		};
}
