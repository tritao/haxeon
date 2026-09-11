package compiler.runtime;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Host types whose implementation is supplied by the HashLink/Haxe platform. */
class PlatformAbi {
	static final types:Map<String, Bool> = [
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
			default: null;
		};

	public static function valueType(name:String):CompilerType
		return switch name {
			default: CompilerType.TInstance(NominalKind.Class, name, []);
		};

	public static function constructorNative(name:String):Null<String>
		return switch name {
			default: null;
		};

	public static function field(type:CompilerType, name:String):Null<{type:CompilerType, get:String, set:Null<String>}>
		return switch type {
			case CompilerType.TString:
				name == "bytes" ? {
					type: CompilerType.TAbstract("hl.Bytes", [], CompilerType.THlBytes),
					get: "__string_bytes",
					set: null
				} : null;
			case CompilerType.TBytes: name == "length" ? {type: CompilerType.TInt, get: "__bytes_length", set: null} : null;
			case CompilerType.TAbstract(_, _, underlying): field(underlying, name);
			case CompilerType.TNativeAbstract(kind): nativeAbstractField(kind, name);
			default: null;
		};

	public static function method(type:CompilerType, name:String):Null<{arguments:Array<CompilerType>, result:CompilerType, nativeName:String}>
		return switch type {
			case CompilerType.TBytes: bytesMethod(name);
			case CompilerType.THlBytes:
				name == "ucs2Length" ? {arguments: [CompilerType.TInt], result: CompilerType.TInt, nativeName: "__hl_bytes_ucs2_length"} : null;
			case CompilerType.TAbstract(_, _, underlying): method(underlying, name);
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
			case "getInt32": {arguments: [CompilerType.TInt], result: CompilerType.TInt, nativeName: "__bytes_get_i32"};
			case "set": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TVoid, nativeName: "__bytes_set"};
			case "setInt32": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TVoid, nativeName: "__bytes_set_i32"};
			case "setFloat": {arguments: [CompilerType.TInt, CompilerType.TFloat], result: CompilerType.TVoid, nativeName: "__bytes_set_float"};
			case "sub": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TBytes, nativeName: "__bytes_sub"};
			case "getString": {arguments: [CompilerType.TInt, CompilerType.TInt], result: CompilerType.TString, nativeName: "__bytes_get_string"};
			case "compare": {arguments: [CompilerType.TBytes], result: CompilerType.TInt, nativeName: "__bytes_compare"};
			case "toString": {arguments: noArguments(), result: CompilerType.TString, nativeName: "__bytes_to_string"};
			default: null;
		};

	static function noArguments():Array<CompilerType>
		return [];
}
