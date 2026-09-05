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
			case "haxe.Exception": [TString];
			default: null;
		};
}
