package compiler.runtime;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Host types whose implementation is supplied by the HashLink/Haxe platform. */
class PlatformAbi {
	static final types:Map<String, Bool> = [
		"haxe.io.BytesInput" => true,
		"haxe.io.BytesOutput" => true,
		"haxe.io.Encoding" => true,
		"haxe.io.Eof" => true,
		"haxe.Json" => true,
		"sys.io.File" => true,
		"Type.ValueType" => true
	];

	public static function isType(name:String):Bool
		return types.exists(name);

	/** Whether a platform-owned type may carry a compile-time native ABI tag. */
	public static function acceptsNativeTag(name:String):Bool
		return name == "hl.Abstract";

	public static function constructorArguments(name:String):Null<Array<CompilerType>>
		return switch name {
			case "haxe.io.BytesInput", "BytesInput": [CompilerType.TBytes];
			case "haxe.io.BytesOutput", "BytesOutput": noArguments();
			default: null;
		};

	public static function valueType(name:String):CompilerType
		return switch name {
			case "haxe.io.BytesInput", "BytesInput": CompilerType.TNativeAbstract("realtime_bytes_input");
			case "haxe.io.BytesOutput", "BytesOutput": CompilerType.TNativeAbstract("realtime_bytes_output");
			default: CompilerType.TInstance(NominalKind.Class, name, []);
		};

	public static function constructorNative(name:String):Null<String>
		return switch name {
			case "haxe.io.BytesInput", "BytesInput": "__bytes_input_new";
			case "haxe.io.BytesOutput", "BytesOutput": "__bytes_output_new";
			default: null;
		};

	public static function field(type:CompilerType, name:String):Null<{type:CompilerType, get:String, set:Null<String>}>
		return switch type {
			case CompilerType.TBytes: name == "length" ? {type: CompilerType.TInt, get: "__bytes_length", set: null} : null;
			case CompilerType.TNativeAbstract(kind): nativeAbstractField(kind, name);
			default: null;
		};

	public static function method(type:CompilerType, name:String):Null<{arguments:Array<CompilerType>, result:CompilerType, nativeName:String}>
		return switch type {
			case CompilerType.TBytes: bytesMethod(name);
			case CompilerType.TNativeAbstract(kind): nativeAbstractMethod(kind, name);
			default: null;
		};

	static function nativeAbstractField(kind:String, name:String):Null<{type:CompilerType, get:String, set:Null<String>}>
		return switch kind {
			case "realtime_bytes_input":
				switch name {
					case "position": {type: CompilerType.TInt, get: "__bytes_input_position", set: null};
					case "bigEndian": {type: CompilerType.TBool, get: "__bytes_input_big_endian", set: "__bytes_input_set_big_endian"};
					default: null;
				}
			case "realtime_bytes_output":
				name == "bigEndian" ? {type: CompilerType.TBool, get: "__bytes_output_big_endian", set: "__bytes_output_set_big_endian"} : null;
			default: null;
		};

	static function bytesMethod(name:String):Null<{arguments:Array<CompilerType>, result:CompilerType, nativeName:String}>
		return switch name {
			case "getData": {
				arguments: noArguments(),
				result: CompilerType.TAbstract("hl.Bytes", [], CompilerType.THlBytes),
				nativeName: "__bytes_get_data"
			};
			case "get": {arguments: [CompilerType.TInt], result: CompilerType.TInt, nativeName: "__bytes_get"};
			case "set": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TVoid, nativeName: "__bytes_set"};
			case "setInt32": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TVoid, nativeName: "__bytes_set_i32"};
			case "sub": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TBytes, nativeName: "__bytes_sub"};
			case "getString": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TString, nativeName: "__bytes_get_string"};
			case "compare": {arguments: [CompilerType.TBytes], result: CompilerType.TInt, nativeName: "__bytes_compare"};
			case "toString": {arguments: noArguments(), result: CompilerType.TString, nativeName: "__bytes_to_string"};
			default: null;
		};

	static function nativeAbstractMethod(kind:String, name:String):Null<{arguments:Array<CompilerType>, result:CompilerType, nativeName:String}>
		return switch kind {
			case "realtime_bytes_input": bytesInputMethod(name);
			case "realtime_bytes_output": bytesOutputMethod(name);
			default: null;
		};

	static function bytesInputMethod(name:String):Null<{arguments:Array<CompilerType>, result:CompilerType, nativeName:String}>
		return switch name {
			case "readByte": {arguments: noArguments(), result: CompilerType.TInt, nativeName: "__bytes_input_read_byte"};
			case "readInt32": {arguments: noArguments(), result: CompilerType.TInt, nativeName: "__bytes_input_read_i32"};
			case "readDouble": {arguments: noArguments(), result: CompilerType.TFloat, nativeName: "__bytes_input_read_f64"};
			case "readString": {arguments: [CompilerType.TInt], result: CompilerType.TString, nativeName: "__bytes_input_read_string"};
			case "read": {arguments: [CompilerType.TInt], result: CompilerType.TBytes, nativeName: "__bytes_input_read"};
			default: null;
		};

	static function bytesOutputMethod(name:String):Null<{arguments:Array<CompilerType>, result:CompilerType, nativeName:String}>
		return switch name {
			case "writeByte": {arguments: [CompilerType.TInt], result: CompilerType.TVoid, nativeName: "__bytes_output_write_byte"};
			case "writeInt32": {arguments: [CompilerType.TInt], result: CompilerType.TVoid, nativeName: "__bytes_output_write_i32"};
			case "writeDouble": {arguments: [CompilerType.TFloat], result: CompilerType.TVoid, nativeName: "__bytes_output_write_f64"};
			case "writeString": {arguments: [CompilerType.TString], result: CompilerType.TVoid, nativeName: "__bytes_output_write_string"};
			case "write", "writeBytes": {arguments: [CompilerType.TBytes], result: CompilerType.TVoid, nativeName: "__bytes_output_write"};
			case "getBytes": {arguments: noArguments(), result: CompilerType.TBytes, nativeName: "__bytes_output_get_bytes"};
			default: null;
		};

	static function noArguments():Array<CompilerType>
		return [];
}
